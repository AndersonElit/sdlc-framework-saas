#!/usr/bin/env bash
# init-dev-environment.sh — Verifica y muestra el estado del ambiente de desarrollo
#
# Ejecutar DESPUÉS de base-infrastructure-builder.sh.
# Verifica K3s, todos los pods Helm, Vault unsealed, bases de datos,
# Kafka, Gitea, Jenkins, ArgoCD y Keycloak. Imprime tabla de endpoints.
#
# Uso:
#   ./init-dev-environment.sh -P <proyecto> --vm-ip <IP> [OPCIONES]
#
# Opciones:
#   -P, --project   NAME     Slug del proyecto              (requerido)
#   --vm-ip         IP       IP del VPS                     (requerido)
#   --env           ENV      local | prod                   (default: local)
#   --kubeconfig    FILE     Kubeconfig K3s                 (auto: ~/.kube/config-<proj>-<env>)
#   --tf-root       DIR      Raíz Terraform generada        (default: ./terraform)
#   --ssh-user      USER     Usuario SSH VPS                (default: ubuntu)
#   --ssh-key       FILE     Clave SSH privada              (default: ~/.ssh/id_ed25519)
#   --apply                  Ejecutar terraform apply si hay drift
#   --skip-tf                Omite verificación Terraform
#
# Ejemplos:
#   ./init-dev-environment.sh -P myapp --vm-ip 192.168.122.50
#   ./init-dev-environment.sh -P myapp --vm-ip 192.168.122.50 --apply

set -euo pipefail

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok()  { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err() { echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }
log_warn(){ echo "[$(date '+%H:%M:%S')] WARN $*"; }

PROJECT=""
VM_IP=""
ENV="local"
KUBECONFIG_PATH=""
TF_ROOT="${PROJECT_ROOT:-$(pwd)}/terraform"
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
DO_APPLY=false
SKIP_TF=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)   PROJECT="$2";        shift 2 ;;
    --vm-ip)        VM_IP="$2";          shift 2 ;;
    --env)          ENV="$2";            shift 2 ;;
    --kubeconfig)   KUBECONFIG_PATH="$2"; shift 2 ;;
    --tf-root)      TF_ROOT="$2";        shift 2 ;;
    --ssh-user)     SSH_USER="$2";       shift 2 ;;
    --ssh-key)      SSH_KEY="$2";        shift 2 ;;
    --apply)        DO_APPLY=true;       shift   ;;
    --skip-tf)      SKIP_TF=true;        shift   ;;
    *) log_err "Opción desconocida: $1"; exit 1 ;;
  esac
done

[[ -z "$PROJECT" ]] && { log_err "-P/--project es requerido"; exit 1; }
[[ -z "$VM_IP" ]]   && { log_err "--vm-ip es requerido"; exit 1; }

[[ -z "$KUBECONFIG_PATH" ]] && KUBECONFIG_PATH="$HOME/.kube/config-${PROJECT}-${ENV}"

KUBECTL="kubectl --kubeconfig=$KUBECONFIG_PATH"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY"
ssh_vps() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

OK=0; WARN=0; FAIL=0
check_ok()   { log_ok  "$1"; OK=$((OK+1)); }
check_warn() { log_warn "$1"; WARN=$((WARN+1)); }
check_fail() { log_err  "$1"; FAIL=$((FAIL+1)); }

# ─── Paso 1: Prerequisitos locales ───────────────────────────────────────────
check_prerequisites() {
  log "── Prerequisitos locales"
  for cmd in kubectl terraform curl; do
    command -v "$cmd" &>/dev/null \
      && check_ok "$cmd: $(command -v $cmd)" \
      || check_fail "$cmd no encontrado"
  done
  [[ -f "$KUBECONFIG_PATH" ]] \
    && check_ok "kubeconfig: $KUBECONFIG_PATH" \
    || check_fail "kubeconfig no encontrado: $KUBECONFIG_PATH"
}

# ─── Paso 2: Conectividad SSH y K3s ──────────────────────────────────────────
check_k3s() {
  log "── K3s en VPS ($VM_IP)"
  ssh_vps "echo OK" &>/dev/null \
    && check_ok "SSH al VPS" \
    || { check_fail "SSH al VPS — no accesible"; return; }

  $KUBECTL get nodes &>/dev/null \
    && check_ok "K3s API server accesible" \
    || { check_fail "K3s no responde"; return; }

  local ready_nodes
  ready_nodes=$($KUBECTL get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || echo 0)
  [[ "$ready_nodes" -ge 1 ]] \
    && check_ok "Nodos K3s Ready: $ready_nodes" \
    || check_fail "Sin nodos Ready en K3s"
}

# ─── Paso 3: Pods Helm por namespace ─────────────────────────────────────────
check_pods() {
  log "── Pods K3s (namespaces gestionados por Terraform)"
  local namespaces=("infra" "data" "messaging" "identity" "secrets" "cicd" "observability")
  for ns in "${namespaces[@]}"; do
    local total running
    total=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | wc -l || echo 0)
    running=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -cE 'Running|Completed' || echo 0)
    if [[ "$total" -eq 0 ]]; then
      check_warn "namespace $ns: sin pods (¿Terraform apply pendiente?)"
    elif [[ "$running" -eq "$total" ]]; then
      check_ok "namespace $ns: $running/$total pods Running"
    else
      check_warn "namespace $ns: $running/$total pods Running"
    fi
  done
}

# ─── Paso 4: Terraform state ──────────────────────────────────────────────────
check_terraform() {
  [[ "$SKIP_TF" == true ]] && { log "── Terraform (omitido)"; return; }
  log "── Terraform state"

  [[ -d "$TF_ROOT" ]] || { check_warn "terraform/ no generado aún — ejecutar base-infrastructure-builder.sh"; return; }

  local managed
  managed=$(terraform -chdir="$TF_ROOT" state list 2>/dev/null | wc -l || echo 0)
  check_ok "Recursos Terraform gestionados: $managed"

  if [[ "$DO_APPLY" == true ]]; then
    log "  Ejecutando terraform apply..."
    terraform -chdir="$TF_ROOT" apply -auto-approve \
      -var-file="environments/${ENV}.tfvars" \
      -var-file="auto.tfvars" \
      && check_ok "terraform apply completado" \
      || check_fail "terraform apply falló"
  fi
}

# ─── Paso 5: Vault ────────────────────────────────────────────────────────────
check_vault() {
  log "── HashiCorp Vault"
  local vault_url="http://${VM_IP}:8200"

  local status
  status=$(curl -sf "${vault_url}/v1/sys/health" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('sealed' if d.get('sealed') else 'unsealed')" 2>/dev/null \
    || echo "unreachable")

  case "$status" in
    unsealed) check_ok "Vault: unsealed ($vault_url)" ;;
    sealed)   check_warn "Vault: SEALED — ejecutar create-all-secrets-vault.sh después de unseal" ;;
    *)        check_fail "Vault: no accesible en $vault_url" ;;
  esac
}

# ─── Paso 6: Bases de datos ───────────────────────────────────────────────────
check_databases() {
  log "── Bases de datos"
  # PostgreSQL vía K3s pod
  $KUBECTL exec -n data deployment/postgresql -- \
    psql -U postgres -c '\l' &>/dev/null \
    && check_ok "PostgreSQL: accesible" \
    || check_warn "PostgreSQL: no responde (pod puede estar iniciando)"

  # MongoDB
  $KUBECTL exec -n data deployment/mongodb -- \
    mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null \
    && check_ok "MongoDB: accesible" \
    || check_warn "MongoDB: no responde (pod puede estar iniciando)"
}

# ─── Paso 7: Kafka ────────────────────────────────────────────────────────────
check_kafka() {
  log "── Kafka (Strimzi)"
  local kafka_ready
  kafka_ready=$($KUBECTL get kafka/kafka -n messaging -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  [[ "$kafka_ready" == "True" ]] \
    && check_ok "Kafka cluster: Ready" \
    || check_warn "Kafka cluster: $kafka_ready (puede estar iniciando)"
}

# ─── Paso 8: Endpoints HTTP ───────────────────────────────────────────────────
check_endpoints() {
  log "── Endpoints HTTP"
  declare -A endpoints=(
    ["Gitea"]="http://${VM_IP}:3000/api/v1/version"
    ["Jenkins"]="http://${VM_IP}:8080/login"
    ["ArgoCD"]="http://${VM_IP}:8081/healthz"
    ["Keycloak"]="http://${VM_IP}:8082/health/ready"
    ["Vault"]="http://${VM_IP}:8200/v1/sys/health"
    ["Grafana"]="http://${VM_IP}:3001/api/health"
    ["Prometheus"]="http://${VM_IP}:9090/-/healthy"
  )

  for name in "${!endpoints[@]}"; do
    local url="${endpoints[$name]}"
    local http_code
    http_code=$(curl -so /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|204|301|302|307|308)$ ]]; then
      check_ok "$name: HTTP $http_code"
    elif [[ "$http_code" == "000" ]]; then
      check_warn "$name: no accesible"
    else
      check_warn "$name: HTTP $http_code"
    fi
  done
}

# ─── Paso 9: ArgoCD Applications ─────────────────────────────────────────────
check_argocd() {
  log "── ArgoCD Applications"
  local apps
  apps=$($KUBECTL get applications -n cicd --no-headers 2>/dev/null | wc -l || echo 0)
  if [[ "$apps" -eq 0 ]]; then
    check_warn "ArgoCD: sin Applications (ejecutar setup-cicd-pipeline.sh después de crear repos)"
  else
    local synced
    synced=$($KUBECTL get applications -n cicd --no-headers 2>/dev/null \
      | grep -c 'Synced' || echo 0)
    check_ok "ArgoCD: $synced/$apps Applications Synced"
  fi
}

# ─── Tabla de endpoints ───────────────────────────────────────────────────────
print_endpoints() {
  log ""
  log "══ Endpoints del ambiente $ENV ═══════════════════════════"
  printf "  %-20s %-45s\n" "Servicio" "URL"
  printf "  %-20s %-45s\n" "--------" "---"
  printf "  %-20s %-45s\n" "Gitea"       "http://$VM_IP:3000   (gitea_admin)"
  printf "  %-20s %-45s\n" "Jenkins"     "http://$VM_IP:8080   (admin)"
  printf "  %-20s %-45s\n" "ArgoCD"      "http://$VM_IP:8081   (admin)"
  printf "  %-20s %-45s\n" "Keycloak"    "http://$VM_IP:8082   (admin)"
  printf "  %-20s %-45s\n" "Vault"       "http://$VM_IP:8200   (ver vault-init.json)"
  printf "  %-20s %-45s\n" "Grafana"     "http://$VM_IP:3001   (admin)"
  printf "  %-20s %-45s\n" "Prometheus"  "http://$VM_IP:9090"
  printf "  %-20s %-45s\n" "LRA Coord."  "http://$VM_IP:50000"
  printf "  %-20s %-45s\n" "WireMock"    "http://$VM_IP:9999"
  log ""
  log "  Kafka bootstrap: kafka-kafka-bootstrap.messaging.svc.cluster.local:9092"
  log "  OTEL gRPC:       tempo.observability.svc.cluster.local:4317"
  log ""
}

# ─── Checklist final ──────────────────────────────────────────────────────────
print_checklist() {
  log "══ Resumen ════════════════════════════════════════════"
  log "  OK:      $OK"
  log "  WARN:    $WARN"
  log "  FAIL:    $FAIL"
  log ""
  if [[ "$FAIL" -gt 0 ]]; then
    log "  Estado: DEGRADADO — revisar errores arriba"
    log ""
    log "  Soluciones comunes:"
    log "    Infra no desplegada: .claude/scripts/base-infrastructure-builder.sh --vm-ip $VM_IP --project $PROJECT ..."
    log "    Vault sellado:       ver vault-init.json + unseal manual"
    log "    Pods iniciando:      kubectl get pods -A --kubeconfig=$KUBECONFIG_PATH"
  elif [[ "$WARN" -gt 0 ]]; then
    log "  Estado: PARCIAL — algunos servicios pueden estar iniciando"
  else
    log "  Estado: LISTO"
    log ""
    log "  Próximos pasos:"
    log "    1. Secrets:    .claude/scripts/create-all-secrets-vault.sh -P $PROJECT --vm-ip $VM_IP ..."
    log "    2. Bases:      .claude/scripts/init-databases.sh --vm-ip $VM_IP --project $PROJECT ..."
    log "    3. CI/CD:      .claude/scripts/setup-cicd-pipeline.sh -P $PROJECT --vm-ip $VM_IP ..."
    log "    4. Migraciones:.claude/scripts/run-liquibase-migrations.sh --vm-ip $VM_IP ..."
  fi
  log "══════════════════════════════════════════════════════"
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  log "init-dev-environment — proyecto=$PROJECT env=$ENV VPS=$VM_IP"
  check_prerequisites
  check_k3s
  check_pods
  check_terraform
  check_vault
  check_databases
  check_kafka
  check_endpoints
  check_argocd
  print_endpoints
  print_checklist
}

main
