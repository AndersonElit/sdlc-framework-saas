#!/usr/bin/env bash
# setup-cicd-pipeline.sh — Despliega Jenkins y ArgoCD en K3s, configura integración con Gitea
#
# Despliega via Helm:
#   Jenkins (con plugins preinstalados y agentes Kubernetes)
#   ArgoCD  (con AppProject por proyecto y sync automático)
#
# Uso: ./setup-cicd-pipeline.sh [OPCIONES]
#
# Opciones:
#   --vm-ip    IP       IP del VPS                    (requerido)
#   --project  NAME     Nombre del proyecto           (requerido)
#   --env      ENV      local | prod                  (default: local)
#   --ssh-user USER     Usuario SSH                   (default: ubuntu)
#   --ssh-key  FILE     Clave SSH privada             (default: ~/.ssh/id_ed25519)
#   --gitea-user USER   Admin Gitea                   (default: gitea_admin)
#   --gitea-pass PASS   Password Gitea admin          (default: changeme_gitea_admin)
#
# Ejemplos:
#   ./setup-cicd-pipeline.sh --vm-ip 192.168.122.50 --project myapp --env local

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

VM_IP=""
PROJECT=""
ENV="local"
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
GITEA_USER="gitea_admin"
GITEA_PASS="changeme_gitea_admin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)      VM_IP="$2";      shift 2 ;;
    --project)    PROJECT="$2";    shift 2 ;;
    --env)        ENV="$2";        shift 2 ;;
    --ssh-user)   SSH_USER="$2";   shift 2 ;;
    --ssh-key)    SSH_KEY="$2";    shift 2 ;;
    --gitea-user) GITEA_USER="$2"; shift 2 ;;
    --gitea-pass) GITEA_PASS="$2"; shift 2 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]   && die "--vm-ip es requerido"
[[ -z "$PROJECT" ]] && die "--project es requerido"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
ssh_run() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

# ─── Jenkins ──────────────────────────────────────────────────────────────────
install_jenkins() {
  header "Instalando Jenkins (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

# Crear ServiceAccount para que Jenkins cree pods agentes en K3s
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: cicd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-cluster-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: cicd
EOF

helm upgrade --install jenkins bitnami/jenkins \
  --namespace cicd \
  --set service.type=NodePort \
  --set service.nodePorts.http=8080 \
  --set jenkinsUser=admin \
  --set jenkinsPassword=changeme_jenkins_admin \
  --set persistence.size=5Gi \
  --set resources.requests.memory=512Mi \
  --set resources.requests.cpu=250m \
  --wait --timeout 10m

echo "[OK] Jenkins listo — http://${VM_IP}:8080"
echo "  admin / changeme_jenkins_admin"
REMOTE
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────
install_argocd() {
  header "Instalando ArgoCD (Helm/Bitnami)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install argocd bitnami/argo-cd \
  --namespace cicd \
  --set server.service.type=NodePort \
  --set server.service.nodePorts.http=8081 \
  --set server.extraArgs="{--insecure}" \
  --set repoServer.resources.requests.memory=128Mi \
  --set redis.enabled=true \
  --wait --timeout 10m

# Obtener contraseña inicial de ArgoCD
ARGO_PASS=\$(kubectl -n cicd get secret argocd-secret \
  -o jsonpath="{.data.clearPassword}" 2>/dev/null | base64 --decode || echo "changeme_argocd")

echo "[OK] ArgoCD listo — http://${VM_IP}:8081"
echo "  admin / \$ARGO_PASS"
REMOTE
}

# ─── AppProject ArgoCD para el proyecto ──────────────────────────────────────
configure_argocd_project() {
  header "Configurando AppProject ArgoCD: $PROJECT"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${PROJECT}
  namespace: cicd
spec:
  description: "Project ${PROJECT} — env ${ENV}"
  sourceRepos:
    - 'http://${VM_IP}:3000/${GITEA_USER}/*'
  destinations:
    - namespace: apps
      server: https://kubernetes.default.svc
    - namespace: infra
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF

echo "[OK] AppProject '${PROJECT}' creado en ArgoCD"
REMOTE
}

# ─── Org y repos base en Gitea ────────────────────────────────────────────────
setup_gitea_org() {
  header "Configurando organización Gitea: $PROJECT"

  info "Creando organización '$PROJECT' en Gitea..."
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${VM_IP}:3000/api/v1/orgs" \
    -H "Content-Type: application/json" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -d "{\"username\":\"${PROJECT}\",\"visibility\":\"private\"}" | grep -qE "^(201|422)" \
    || warn "No se pudo crear org (puede que ya exista)"

  # Repo de migraciones Liquibase
  info "Creando repo ${PROJECT}-migrations..."
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${VM_IP}:3000/api/v1/orgs/${PROJECT}/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -d "{\"name\":\"${PROJECT}-migrations\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" \
    | grep -qE "^(201|409)" \
    || warn "No se pudo crear repo ${PROJECT}-migrations"

  # Repo de Helm charts del proyecto
  info "Creando repo ${PROJECT}-helm-charts..."
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${VM_IP}:3000/api/v1/orgs/${PROJECT}/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -d "{\"name\":\"${PROJECT}-helm-charts\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" \
    | grep -qE "^(201|409)" \
    || warn "No se pudo crear repo ${PROJECT}-helm-charts"

  ok "Repos base creados en http://${VM_IP}:3000/${PROJECT}"
}

# ─── Shared library builder ───────────────────────────────────────────────────
invoke_shared_library() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local lib_script="$script_dir/jenkins-shared-library-builder.sh"

  if [[ -f "$lib_script" ]]; then
    header "Generando Jenkins Shared Library"
    bash "$lib_script" \
      --vm-ip "$VM_IP" \
      --project "$PROJECT" \
      --gitea-user "$GITEA_USER" \
      --gitea-pass "$GITEA_PASS"
  else
    warn "jenkins-shared-library-builder.sh no encontrado — omitiendo"
  fi
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "setup-cicd-pipeline — env=$ENV  proyecto=$PROJECT"

  install_jenkins
  install_argocd
  configure_argocd_project
  setup_gitea_org
  invoke_shared_library

  header "CI/CD listo"
  echo ""
  echo -e "  ${BOLD}Jenkins:${RESET}  http://$VM_IP:8080  (admin / changeme_jenkins_admin)"
  echo -e "  ${BOLD}ArgoCD:${RESET}   http://$VM_IP:8081  (admin / ver log de instalación)"
  echo -e "  ${BOLD}Gitea:${RESET}    http://$VM_IP:3000  (org: $PROJECT)"
  echo ""
  warn "Cambiar contraseñas default antes de usar en producción"
}

main
