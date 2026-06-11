#!/usr/bin/env bash
# setup-observability.sh — Despliega stack de observabilidad via Helm en K3s
#
# Stack desplegado (namespace: observability):
#   Prometheus     — métricas (kube-prometheus-stack)
#   Grafana        — dashboards (incluido en kube-prometheus-stack)
#   Loki           — logs centralizados (Promtail como DaemonSet)
#   Tempo          — trazas distribuidas (OpenTelemetry compatible)
#   AlertManager   — alertas (incluido en kube-prometheus-stack)
#
# Uso: ./setup-observability.sh [OPCIONES]
#
# Opciones:
#   --vm-ip    IP       IP del VPS                    (requerido)
#   --project  NAME     Nombre del proyecto           (requerido)
#   --env      ENV      local | prod                  (default: local)
#   --ssh-user USER     Usuario SSH                   (default: ubuntu)
#   --ssh-key  FILE     Clave SSH privada             (default: ~/.ssh/id_ed25519)
#   --no-tempo          Omite Tempo (trazas)
#   --no-loki           Omite Loki (logs)
#
# Ejemplos:
#   ./setup-observability.sh --vm-ip 192.168.122.50 --project myapp --env local

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
INSTALL_TEMPO=true
INSTALL_LOKI=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)     VM_IP="$2";    shift 2 ;;
    --project)   PROJECT="$2";  shift 2 ;;
    --env)       ENV="$2";      shift 2 ;;
    --ssh-user)  SSH_USER="$2"; shift 2 ;;
    --ssh-key)   SSH_KEY="$2";  shift 2 ;;
    --no-tempo)  INSTALL_TEMPO=false; shift ;;
    --no-loki)   INSTALL_LOKI=false;  shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]   && die "--vm-ip es requerido"
[[ -z "$PROJECT" ]] && die "--project es requerido"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
ssh_run() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

# ─── Repos Helm de observabilidad ────────────────────────────────────────────
add_obs_repos() {
  header "Agregando repos Helm de observabilidad"
  ssh_run bash -s <<'REMOTE'
set -euo pipefail
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana               https://grafana.github.io/helm-charts
helm repo update
echo "[OK] Repos observabilidad agregados"
REMOTE
}

# ─── kube-prometheus-stack (Prometheus + Grafana + AlertManager) ─────────────
install_prometheus_stack() {
  header "Instalando kube-prometheus-stack (Prometheus + Grafana + AlertManager)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=9090 \
  --set grafana.enabled=true \
  --set grafana.adminPassword=changeme_grafana_admin \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=3001 \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=2Gi \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set defaultRules.create=true \
  --wait --timeout 10m

echo "[OK] kube-prometheus-stack listo"
echo "  Prometheus: http://${VM_IP}:9090"
echo "  Grafana:    http://${VM_IP}:3001  (admin / changeme_grafana_admin)"
REMOTE
}

# ─── Loki + Promtail ─────────────────────────────────────────────────────────
install_loki() {
  [[ "$INSTALL_LOKI" == true ]] || return 0
  header "Instalando Loki + Promtail (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

# Loki (modo standalone para VPS single-node)
helm upgrade --install loki grafana/loki \
  --namespace observability \
  --set deploymentMode=SingleBinary \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.size=5Gi \
  --set singleBinary.resources.requests.memory=128Mi \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set backend.replicas=0 \
  --wait --timeout 5m

# Promtail (DaemonSet — recolecta logs de todos los pods)
helm upgrade --install promtail grafana/promtail \
  --namespace observability \
  --set config.lokiAddress=http://loki:3100/loki/api/v1/push \
  --wait --timeout 3m

echo "[OK] Loki + Promtail listos"
REMOTE

  # Configurar datasource Loki en Grafana
  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

kubectl apply -n observability -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-loki
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki:3100
        access: proxy
        isDefault: false
EOF

echo "[OK] Datasource Loki configurado en Grafana"
REMOTE
}

# ─── Tempo (trazas distribuidas) ──────────────────────────────────────────────
install_tempo() {
  [[ "$INSTALL_TEMPO" == true ]] || return 0
  header "Instalando Grafana Tempo (Helm)"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

helm upgrade --install tempo grafana/tempo \
  --namespace observability \
  --set tempo.storage.trace.backend=local \
  --set tempo.storage.trace.local.path=/var/tempo/traces \
  --set tempo.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
  --set tempo.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set resources.requests.memory=128Mi \
  --wait --timeout 5m

# Datasource Tempo en Grafana
kubectl apply -n observability -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-tempo
  labels:
    grafana_datasource: "1"
data:
  tempo-datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        url: http://tempo:3100
        access: proxy
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
          serviceMap:
            datasourceUid: prometheus
EOF

echo "[OK] Tempo listo"
echo "  OTLP gRPC: tempo.observability.svc.cluster.local:4317"
echo "  OTLP HTTP: tempo.observability.svc.cluster.local:4318"
REMOTE
}

# ─── Dashboards base para microservicios Spring Boot ─────────────────────────
install_dashboards() {
  header "Instalando dashboards Grafana para Spring Boot + Kafka"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

# Dashboard JVM / Spring Boot Actuator (ID Grafana: 4701)
kubectl apply -n observability -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-spring-boot
  labels:
    grafana_dashboard: "1"
data:
  spring-boot.json: |
    {"__inputs":[{"name":"DS_PROMETHEUS","type":"datasource","pluginId":"prometheus"}],
     "title":"Spring Boot / JVM","uid":"spring-boot","schemaVersion":36,
     "panels":[],"description":"JVM metrics via Spring Boot Actuator / Micrometer.
     Import dashboard ID 4701 from grafana.com for full version."}
EOF

echo "[OK] Dashboard Spring Boot registrado (importar ID 4701 de grafana.com para versión completa)"
REMOTE
}

# ─── ServiceMonitor para aplicaciones del proyecto ───────────────────────────
create_service_monitor() {
  header "Creando ServiceMonitor para namespace 'apps'"

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: apps-services
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - apps
  selector:
    matchLabels:
      monitoring: "true"
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
EOF

echo "[OK] ServiceMonitor creado — agregar label 'monitoring: true' a los Services de tus microservicios"
REMOTE
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "setup-observability — env=$ENV  proyecto=$PROJECT"

  add_obs_repos
  install_prometheus_stack
  install_loki
  install_tempo
  install_dashboards
  create_service_monitor

  header "Stack de observabilidad listo"
  echo ""
  echo -e "  ${BOLD}Grafana:${RESET}     http://$VM_IP:3001  (admin / changeme_grafana_admin)"
  echo -e "  ${BOLD}Prometheus:${RESET}  http://$VM_IP:9090"
  echo ""
  echo -e "  ${BOLD}Datasources configurados:${RESET}"
  echo -e "    Prometheus  — métricas"
  [[ "$INSTALL_LOKI" == true ]]  && echo -e "    Loki        — logs (Promtail DaemonSet)"
  [[ "$INSTALL_TEMPO" == true ]] && echo -e "    Tempo       — trazas OTLP (gRPC :4317 / HTTP :4318)"
  echo ""
  echo -e "  ${BOLD}Configuración en microservicios:${RESET}"
  echo -e "    application.yml: management.endpoints.web.exposure.include=prometheus,health"
  echo -e "    Agregar label al Service K8s: monitoring: true"
  echo -e "    OTEL exporter: OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability:4317"
  echo ""
  warn "Cambiar contraseña Grafana default antes de producción"
}

main
