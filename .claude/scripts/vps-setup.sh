#!/usr/bin/env bash
# vps-setup.sh — Instala K3s y despliega servicios base via Helm en el VPS
#
# Servicios desplegados en K3s (todos via Helm):
#   Infraestructura:  Traefik (ingress), cert-manager
#   Identidad:        Keycloak
#   Secretos:         HashiCorp Vault
#   Base de datos:    PostgreSQL 16, MongoDB 7 (StatefulSets con PVC)
#   Registry:         Gitea (con Package Registry OCI habilitado)
#   Mensajería:       Apache Kafka (Strimzi operator)
#   Soporte:          Narayana LRA coordinator, WireMock (para tests)
#
# Uso: ./vps-setup.sh [OPCIONES]
#
# Opciones:
#   --vm-ip    IP       IP del VPS                          (requerido)
#   --env      ENV      local | prod                        (default: local)
#   --project  NAME     Nombre del proyecto                 (requerido)
#   --ssh-user USER     Usuario SSH                         (default: ubuntu)
#   --ssh-key  FILE     Clave SSH privada                   (default: ~/.ssh/id_ed25519)
#   --k3s-ver  VER      Versión K3s                        (default: v1.31.4+k3s1)
#   --no-lra             Omite Narayana LRA
#   --no-wiremock        Omite WireMock
#
# Ejemplos:
#   ./vps-setup.sh --vm-ip 192.168.122.50 --env local --project myapp
#   ./vps-setup.sh --vm-ip 10.0.0.5 --env prod --project myapp

set -euo pipefail

# ─── colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
VM_IP=""
ENV="local"
PROJECT=""
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
K3S_VER="v1.31.4+k3s1"
INSTALL_LRA=true
INSTALL_WIREMOCK=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)      VM_IP="$2";      shift 2 ;;
    --env)        ENV="$2";        shift 2 ;;
    --project)    PROJECT="$2";    shift 2 ;;
    --ssh-user)   SSH_USER="$2";   shift 2 ;;
    --ssh-key)    SSH_KEY="$2";    shift 2 ;;
    --k3s-ver)    K3S_VER="$2";    shift 2 ;;
    --no-lra)     INSTALL_LRA=false;      shift ;;
    --no-wiremock) INSTALL_WIREMOCK=false; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]   && die "--vm-ip es requerido"
[[ -z "$PROJECT" ]] && die "--project es requerido"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"

ssh_run() {
  # shellcheck disable=SC2029
  ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"
}

ssh_sudo() {
  ssh_run "sudo bash -s" <<< "$1"
}

scp_file() {
  scp $SSH_OPTS "$1" "${SSH_USER}@${VM_IP}:$2"
}

wait_ssh() {
  info "Esperando SSH en $VM_IP..."
  local tries=0
  until ssh $SSH_OPTS -o ConnectTimeout=5 "${SSH_USER}@${VM_IP}" true 2>/dev/null; do
    tries=$((tries+1))
    [[ $tries -ge 30 ]] && die "No se pudo conectar al VPS después de 60s"
    sleep 2
  done
  ok "SSH disponible"
}

# ─── FASE 1: K3s ─────────────────────────────────────────────────────────────
install_k3s() {
  header "Instalando K3s $K3S_VER"

  ssh_run bash -s <<REMOTE
set -euo pipefail

if command -v k3s &>/dev/null; then
  echo "[SKIP] K3s ya instalado: \$(k3s --version | head -1)"
  exit 0
fi

echo "[INFO] Instalando K3s ${K3S_VER}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VER}" sh -s - \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --node-name ${PROJECT}-node

echo "[INFO] Esperando que K3s esté listo..."
timeout 120 bash -c 'until kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 3; done'
kubectl get nodes

# Copiar kubeconfig para el usuario sin sudo
mkdir -p \$HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
sed -i "s/127.0.0.1/${VM_IP}/g" \$HOME/.kube/config

echo "[OK] K3s listo"
REMOTE

  # Descargar kubeconfig localmente
  mkdir -p "$HOME/.kube"
  scp $SSH_OPTS "${SSH_USER}@${VM_IP}:.kube/config" "$HOME/.kube/config-${PROJECT}-${ENV}"
  ok "Kubeconfig guardado: ~/.kube/config-${PROJECT}-${ENV}"
  ok "Exportar:  export KUBECONFIG=~/.kube/config-${PROJECT}-${ENV}"
}

# ─── FASE 2: Helm repos ───────────────────────────────────────────────────────
setup_helm_repos() {
  header "Configurando repositorios Helm"

  ssh_run bash -s <<'REMOTE'
set -euo pipefail

if ! command -v helm &>/dev/null; then
  echo "[INFO] Instalando Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

helm repo add traefik        https://helm.traefik.io/traefik
helm repo add jetstack       https://charts.jetstack.io
helm repo add bitnami        https://charts.bitnami.com/bitnami
helm repo add codecentric    https://codecentric.github.io/helm-charts
helm repo add hashicorp      https://helm.releases.hashicorp.com
helm repo add strimzi        https://strimzi.io/charts/
helm repo add gitea-charts   https://dl.gitea.com/charts/
helm repo update
echo "[OK] Repos Helm configurados"
REMOTE
}

# ─── FASE 3: Namespaces ───────────────────────────────────────────────────────
create_namespaces() {
  header "Creando namespaces"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

for NS in infra identity secrets data messaging cicd observability apps; do
  kubectl get namespace \$NS &>/dev/null \
    || kubectl create namespace \$NS
  echo "[OK] namespace: \$NS"
done
REMOTE
}

# ─── FASE 4: Traefik (ingress) ────────────────────────────────────────────────
install_traefik() {
  header "Instalando Traefik (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install traefik traefik/traefik \
  --namespace infra \
  --set deployment.replicas=1 \
  --set ports.web.exposedPort=80 \
  --set ports.websecure.exposedPort=443 \
  --set ports.traefik.expose.default=true \
  --set service.type=NodePort \
  --wait --timeout 3m

echo "[OK] Traefik listo"
REMOTE
}

# ─── FASE 5: cert-manager ─────────────────────────────────────────────────────
install_cert_manager() {
  header "Instalando cert-manager (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace infra \
  --set installCRDs=true \
  --wait --timeout 3m

echo "[OK] cert-manager listo"
REMOTE
}

# ─── FASE 6: PostgreSQL ───────────────────────────────────────────────────────
install_postgresql() {
  header "Instalando PostgreSQL 16 (Helm/Bitnami)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install postgresql bitnami/postgresql \
  --namespace data \
  --set image.tag=16 \
  --set auth.postgresPassword=changeme_pg_admin \
  --set primary.persistence.size=10Gi \
  --set primary.resources.requests.memory=256Mi \
  --set primary.resources.requests.cpu=100m \
  --wait --timeout 5m

echo "[OK] PostgreSQL listo"
echo "  Conexión: postgresql.data.svc.cluster.local:5432"
echo "  Admin:    postgres / changeme_pg_admin  (cambiar via Vault)"
REMOTE
}

# ─── FASE 7: MongoDB ──────────────────────────────────────────────────────────
install_mongodb() {
  header "Instalando MongoDB 7 (Helm/Bitnami)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install mongodb bitnami/mongodb \
  --namespace data \
  --set image.tag=7.0 \
  --set auth.rootPassword=changeme_mongo_admin \
  --set persistence.size=10Gi \
  --set resources.requests.memory=256Mi \
  --set resources.requests.cpu=100m \
  --wait --timeout 5m

echo "[OK] MongoDB listo"
echo "  Conexión: mongodb.data.svc.cluster.local:27017"
echo "  Admin:    root / changeme_mongo_admin  (cambiar via Vault)"
REMOTE
}

# ─── FASE 8: Kafka (Strimzi) ──────────────────────────────────────────────────
install_kafka() {
  header "Instalando Kafka via Strimzi (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

# Instalar Strimzi operator
helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
  --namespace messaging \
  --wait --timeout 5m

# Cluster Kafka mínimo KRaft (sin ZooKeeper)
kubectl apply -n messaging -f - <<'EOF'
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: combined
  labels:
    strimzi.io/cluster: kafka
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: persistent-claim
    size: 10Gi
    deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.8.0
    metadataVersion: "3.8"
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF

echo "[INFO] Esperando Kafka listo..."
kubectl wait kafka/kafka -n messaging \
  --for=condition=Ready --timeout=5m

echo "[OK] Kafka listo"
echo "  Bootstrap: kafka-kafka-bootstrap.messaging.svc.cluster.local:9092"
REMOTE
}

# ─── FASE 9: Keycloak ─────────────────────────────────────────────────────────
install_keycloak() {
  header "Instalando Keycloak (Helm/Bitnami)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install keycloak bitnami/keycloak \
  --namespace identity \
  --set auth.adminUser=admin \
  --set auth.adminPassword=changeme_kc_admin \
  --set postgresql.enabled=false \
  --set externalDatabase.host=postgresql.data.svc.cluster.local \
  --set externalDatabase.port=5432 \
  --set externalDatabase.user=postgres \
  --set externalDatabase.password=changeme_pg_admin \
  --set externalDatabase.database=keycloak \
  --set service.type=NodePort \
  --set service.nodePorts.http=8082 \
  --set replicaCount=1 \
  --set resources.requests.memory=512Mi \
  --set resources.requests.cpu=250m \
  --wait --timeout 10m

echo "[OK] Keycloak listo — http://${VM_IP}:8082"
REMOTE
}

# ─── FASE 10: HashiCorp Vault ────────────────────────────────────────────────
install_vault() {
  header "Instalando HashiCorp Vault (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install vault hashicorp/vault \
  --namespace secrets \
  --set server.dev.enabled=false \
  --set server.standalone.enabled=true \
  --set server.standalone.config='
ui = true
listener "tcp" {
  tls_disable = 1
  address = "[::]:8200"
  cluster_address = "[::]:8201"
}
storage "file" {
  path = "/vault/data"
}
' \
  --set server.dataStorage.enabled=true \
  --set server.dataStorage.size=2Gi \
  --set server.service.type=NodePort \
  --set server.service.nodePort=8200 \
  --set ui.enabled=true \
  --wait --timeout 5m

echo "[INFO] Inicializando Vault..."
sleep 10
kubectl exec -n secrets vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 \
  -format=json > /tmp/vault-init.json 2>/dev/null || true

if [[ -f /tmp/vault-init.json ]]; then
  echo "[OK] Vault inicializado — guardar /tmp/vault-init.json en lugar seguro"
  echo "  Unseal key y Root token en /tmp/vault-init.json"
fi

echo "[OK] Vault listo — http://${VM_IP}:8200"
REMOTE

  if ssh_run "test -f /tmp/vault-init.json" 2>/dev/null; then
    scp $SSH_OPTS "${SSH_USER}@${VM_IP}:/tmp/vault-init.json" "./vault-init-${PROJECT}-${ENV}.json"
    ok "vault-init guardado localmente: ./vault-init-${PROJECT}-${ENV}.json (mantener seguro)"
  fi
}

# ─── FASE 11: Gitea ───────────────────────────────────────────────────────────
install_gitea() {
  header "Instalando Gitea (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install gitea gitea-charts/gitea \
  --namespace cicd \
  --set gitea.admin.username=gitea_admin \
  --set gitea.admin.password=changeme_gitea_admin \
  --set gitea.admin.email=admin@${PROJECT}.local \
  --set postgresql.enabled=false \
  --set gitea.config.database.DB_TYPE=postgres \
  --set gitea.config.database.HOST=postgresql.data.svc.cluster.local:5432 \
  --set gitea.config.database.NAME=gitea \
  --set gitea.config.database.USER=postgres \
  --set gitea.config.database.PASSWD=changeme_pg_admin \
  --set gitea.config.server.DOMAIN=${VM_IP} \
  --set gitea.config.server.ROOT_URL=http://${VM_IP}:3000 \
  --set gitea.config.packages.ENABLED=true \
  --set service.http.type=NodePort \
  --set service.http.nodePort=3000 \
  --set persistence.size=5Gi \
  --wait --timeout 5m

echo "[OK] Gitea listo — http://${VM_IP}:3000"
REMOTE
}

# ─── FASE 12: Narayana LRA (saga coordinator) ────────────────────────────────
install_lra() {
  [[ "$INSTALL_LRA" == true ]] || return 0
  header "Instalando Narayana LRA Coordinator"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

kubectl apply -n infra -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lra-coordinator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lra-coordinator
  template:
    metadata:
      labels:
        app: lra-coordinator
    spec:
      containers:
        - name: lra-coordinator
          image: quay.io/jbosstm/lra-coordinator:latest
          ports:
            - containerPort: 8080
          env:
            - name: QUARKUS_HTTP_PORT
              value: "8080"
---
apiVersion: v1
kind: Service
metadata:
  name: lra-coordinator
spec:
  type: NodePort
  selector:
    app: lra-coordinator
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 50000
EOF

echo "[OK] Narayana LRA Coordinator listo — http://${VM_IP}:50000"
REMOTE
}

# ─── FASE 13: WireMock (pruebas de integración) ───────────────────────────────
install_wiremock() {
  [[ "$INSTALL_WIREMOCK" == true ]] || return 0
  header "Instalando WireMock"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

kubectl apply -n infra -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wiremock
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wiremock
  template:
    metadata:
      labels:
        app: wiremock
    spec:
      containers:
        - name: wiremock
          image: wiremock/wiremock:3x
          args: ["--port=9999", "--verbose"]
          ports:
            - containerPort: 9999
---
apiVersion: v1
kind: Service
metadata:
  name: wiremock
spec:
  type: NodePort
  selector:
    app: wiremock
  ports:
    - port: 9999
      targetPort: 9999
      nodePort: 9999
EOF

echo "[OK] WireMock listo — http://${VM_IP}:9999"
REMOTE
}

# ─── verificación final ───────────────────────────────────────────────────────
verify_cluster() {
  header "Verificación del cluster"

  ssh_run bash -s <<'REMOTE'
export KUBECONFIG=$HOME/.kube/config
echo "=== Nodos ==="
kubectl get nodes -o wide
echo ""
echo "=== Pods por namespace ==="
kubectl get pods -A --sort-by='.metadata.namespace'
REMOTE
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "vps-setup — env=$ENV  ip=$VM_IP  proyecto=$PROJECT"

  wait_ssh
  install_k3s
  setup_helm_repos
  create_namespaces
  install_traefik
  install_cert_manager
  install_postgresql
  install_mongodb
  install_kafka
  install_keycloak
  install_vault
  install_gitea
  install_lra
  install_wiremock
  verify_cluster

  header "Setup completo"
  ok "K3s + Helm stack desplegado en $VM_IP"
  echo ""
  echo -e "  ${BOLD}Servicios:${RESET}"
  echo -e "    Gitea:       http://$VM_IP:3000   (gitea_admin / changeme_gitea_admin)"
  echo -e "    Keycloak:    http://$VM_IP:8082   (admin / changeme_kc_admin)"
  echo -e "    Vault:       http://$VM_IP:8200   (ver vault-init-${PROJECT}-${ENV}.json)"
  echo -e "    LRA:         http://$VM_IP:50000"
  echo -e "    WireMock:    http://$VM_IP:9999"
  echo ""
  warn "Cambiar todas las contraseñas default antes de usar en producción"
  warn "Unseal Vault con el token de ./vault-init-${PROJECT}-${ENV}.json"
}

main
