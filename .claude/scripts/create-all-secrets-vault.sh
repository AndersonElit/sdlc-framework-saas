#!/usr/bin/env bash
# create-all-secrets-vault.sh — Crea/actualiza secrets de todos los microservicios en HashiCorp Vault
#
# Auto-descubre servicios en backend/, detecta tipo de BD (PostgreSQL/MongoDB),
# uso de Kafka, presence de integration-service (Camel), y escribe los secrets
# en Vault KV v2 en la ruta: secret/<proyecto>/<env>/<servicio>
#
# PREREQUISITOS:
#   - Vault iniciado y unsealed (vault-init.json presente o Vault ya configurado)
#   - K3s corriendo con Vault pod en namespace "secrets"
#   - kubectl configurado (kubeconfig en --kubeconfig o KUBECONFIG_PATH)
#   - Proyecto con estructura backend/<servicio>/driven-adapters/
#
# Uso:
#   ./create-all-secrets-vault.sh -P <proyecto> --vm-ip <IP> [OPCIONES]
#
# Opciones:
#   -P, --project   NAME     Slug del proyecto              (requerido)
#   --vm-ip         IP       IP del VPS                     (requerido)
#   --env           ENV      local | prod                   (default: local)
#   --pg-prefix     PREFIX   Prefijo BDs PostgreSQL         (requerido)
#   --mongo-prefix  PREFIX   Prefijo BDs MongoDB            (requerido)
#   --backend-dir   DIR      Raíz de microservicios         (default: backend)
#   --kubeconfig    FILE     Kubeconfig K3s                 (default: ~/.kube/config-<proj>-<env>)
#   --vault-token   TOKEN    Root token de Vault            (auto: lee vault-init.json)
#   --dry-run                Muestra secrets sin crearlos
#
# Ejemplos:
#   ./create-all-secrets-vault.sh -P myapp --vm-ip 192.168.122.50 \
#     --pg-prefix myapp --mongo-prefix myapp
#
#   ./create-all-secrets-vault.sh -P myapp --vm-ip 192.168.122.50 \
#     --pg-prefix myapp --mongo-prefix myapp --env prod --dry-run

set -euo pipefail

log()    { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err(){ echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

PROJECT=""
VM_IP=""
ENV="local"
PG_PREFIX=""
MONGO_PREFIX=""
BACKEND_DIR="backend"
KUBECONFIG_PATH=""
VAULT_TOKEN=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)    PROJECT="$2";       shift 2 ;;
    --vm-ip)         VM_IP="$2";         shift 2 ;;
    --env)           ENV="$2";           shift 2 ;;
    --pg-prefix)     PG_PREFIX="$2";     shift 2 ;;
    --mongo-prefix)  MONGO_PREFIX="$2";  shift 2 ;;
    --backend-dir)   BACKEND_DIR="$2";   shift 2 ;;
    --kubeconfig)    KUBECONFIG_PATH="$2"; shift 2 ;;
    --vault-token)   VAULT_TOKEN="$2";   shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift   ;;
    *) log_err "Opción desconocida: $1"; exit 1 ;;
  esac
done

[[ -z "$PROJECT" ]]     && { log_err "-P/--project es requerido"; exit 1; }
[[ -z "$VM_IP" ]]       && { log_err "--vm-ip es requerido"; exit 1; }
[[ -z "$PG_PREFIX" ]]   && { log_err "--pg-prefix es requerido"; exit 1; }
[[ -z "$MONGO_PREFIX" ]] && { log_err "--mongo-prefix es requerido"; exit 1; }

[[ -z "$KUBECONFIG_PATH" ]] && KUBECONFIG_PATH="$HOME/.kube/config-${PROJECT}-${ENV}"

KUBECTL="kubectl --kubeconfig=$KUBECONFIG_PATH"

slugify() { echo "$1" | tr '-' '_' | tr '[:upper:]' '[:lower:]'; }

# ─── Leer Vault root token ────────────────────────────────────────────────────
resolve_vault_token() {
  if [[ -n "$VAULT_TOKEN" ]]; then return; fi

  if [[ -f "vault-init.json" ]]; then
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('vault-init.json'))['root_token'])" 2>/dev/null \
      || jq -r '.root_token' vault-init.json 2>/dev/null || true)
  fi

  [[ -z "$VAULT_TOKEN" ]] && {
    log_err "No se pudo obtener Vault token. Pasa --vault-token o asegúrate de que vault-init.json existe."
    exit 1
  }
  log_ok "Vault token resuelto desde vault-init.json"
}

# ─── Detectores de estructura del microservicio ───────────────────────────────
detect_db_type() {
  local svc_dir="$1"
  local db_type="none"
  [[ -d "$svc_dir/driven-adapters/postgres" || \
     -d "$svc_dir/driven-adapters/r2dbc-postgres" || \
     -d "$svc_dir/driven-adapters/jpa-repository" ]] && db_type="postgres"
  [[ -d "$svc_dir/driven-adapters/mongo" || \
     -d "$svc_dir/driven-adapters/mongodb" || \
     -d "$svc_dir/driven-adapters/reactive-mongo" ]] && db_type="mongo"
  echo "$db_type"
}

detect_kafka() {
  local svc_dir="$1"
  [[ -d "$svc_dir/driven-adapters/kafka-producer" || \
     -d "$svc_dir/driven-adapters/async-event-bus" || \
     -d "$svc_dir/driven-adapters/outbox" || \
     -d "$svc_dir/entry-points/kafka-consumer" || \
     -d "$svc_dir/entry-points/async-event-handler" ]] && echo "true" || echo "false"
}

detect_integration_service() {
  local svc_dir="$1"
  [[ -d "$svc_dir/driven-adapters/camel-rest-consumer" || \
     -d "$svc_dir/driven-adapters/saga-camel" || \
     $(basename "$svc_dir") == "integration-service" ]] && echo "true" || echo "false"
}

detect_external_systems() {
  local svc_dir="$1"
  # Extrae nombres de sistemas externos de propiedades Camel
  grep -rh "external\.\(.*\)\.base-url\|camelContext.*from(" \
    "$svc_dir" 2>/dev/null \
    | grep -oP 'external\.\K[a-z0-9-]+(?=\.base-url)' \
    | sort -u | tr '\n' ',' | sed 's/,$//' || true
}

# ─── Escribir secret en Vault ─────────────────────────────────────────────────
vault_put() {
  local path="$1"; shift
  local kvpairs=("$@")

  if [[ "$DRY_RUN" == true ]]; then
    log "  [DRY-RUN] vault kv put secret/${PROJECT}/${ENV}/${path} ${kvpairs[*]}"
    return
  fi

  local args_str=""
  for kv in "${kvpairs[@]}"; do
    args_str="$args_str $kv"
  done

  $KUBECTL exec -n secrets vault-0 -- \
    sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault kv put secret/${PROJECT}/${ENV}/${path} ${args_str}" \
    2>/dev/null && log_ok "secret/${PROJECT}/${ENV}/${path}" \
    || log_err "Falló: secret/${PROJECT}/${ENV}/${path}"
}

# ─── Descubrir servicios ──────────────────────────────────────────────────────
discover_services() {
  [[ -d "$BACKEND_DIR" ]] || { log_err "Directorio backend no encontrado: $BACKEND_DIR"; exit 1; }
  find "$BACKEND_DIR" -mindepth 1 -maxdepth 1 -type d -name '*-service' | sort
}

# ─── Construir secret por servicio ───────────────────────────────────────────
create_service_secret() {
  local svc_dir="$1"
  local svc_name
  svc_name=$(basename "$svc_dir")
  local svc_slug
  svc_slug=$(slugify "$svc_name")

  local db_type
  db_type=$(detect_db_type "$svc_dir")
  local use_kafka
  use_kafka=$(detect_kafka "$svc_dir")
  local is_integration
  is_integration=$(detect_integration_service "$svc_dir")

  log "Procesando $svc_name (db=$db_type kafka=$use_kafka integration=$is_integration)..."

  local kvpairs=()

  # ── Credenciales de base de datos ──
  case "$db_type" in
    postgres)
      local pg_db="${PG_PREFIX}_${svc_slug}"
      kvpairs+=(
        "DB_URL=jdbc:postgresql://postgresql.data.svc.cluster.local:5432/${pg_db}"
        "DB_REACTIVE_URL=r2dbc:postgresql://postgresql.data.svc.cluster.local:5432/${pg_db}"
        "DB_USERNAME=${pg_db}_user"
        "DB_PASSWORD=changeme_${svc_slug}"
        "DB_NAME=${pg_db}"
      )
      ;;
    mongo)
      local mg_db="${MONGO_PREFIX}_${svc_slug}"
      kvpairs+=(
        "MONGO_URI=mongodb://${svc_slug}_user:changeme_${svc_slug}@mongodb.data.svc.cluster.local:27017/${mg_db}?authSource=${mg_db}"
        "MONGO_DB=${mg_db}"
        "MONGO_USERNAME=${svc_slug}_user"
        "MONGO_PASSWORD=changeme_${svc_slug}"
      )
      ;;
  esac

  # ── Kafka ──
  if [[ "$use_kafka" == "true" ]]; then
    kvpairs+=(
      "KAFKA_BOOTSTRAP_SERVERS=kafka-kafka-bootstrap.messaging.svc.cluster.local:9092"
      "KAFKA_GROUP_ID=${PROJECT}-${svc_slug}"
    )
  fi

  # ── Keycloak (todos los servicios necesitan validar tokens) ──
  kvpairs+=(
    "KEYCLOAK_URL=http://keycloak.identity.svc.cluster.local:8080"
    "KEYCLOAK_REALM=${PROJECT}"
    "KEYCLOAK_CLIENT_ID=${svc_name}"
    "KEYCLOAK_CLIENT_SECRET=changeme_${svc_slug}_client"
    "KEYCLOAK_JWKS_URI=http://keycloak.identity.svc.cluster.local:8080/realms/${PROJECT}/protocol/openid-connect/certs"
    "KEYCLOAK_TOKEN_URI=http://keycloak.identity.svc.cluster.local:8080/realms/${PROJECT}/protocol/openid-connect/token"
  )

  # ── Vault propio (para servicios que leen otros secrets) ──
  kvpairs+=(
    "VAULT_ADDR=http://vault.secrets.svc.cluster.local:8200"
    "VAULT_BASE_PATH=secret/${PROJECT}/${ENV}"
  )

  # ── Integration service: sistemas externos ──
  if [[ "$is_integration" == "true" ]]; then
    local external_systems
    external_systems=$(detect_external_systems "$svc_dir")
    kvpairs+=("EXTERNAL_SYSTEMS=${external_systems}")
    kvpairs+=("LRA_COORDINATOR_URL=http://lra-coordinator.infra.svc.cluster.local:8080/lra-coordinator")
  fi

  vault_put "$svc_name" "${kvpairs[@]}"
}

# ─── Secrets del subsistema de reportería ────────────────────────────────────
create_reporting_secrets() {
  log "Creando secrets de reportería..."

  local kvpairs=(
    "REPORTING_DB_URL=jdbc:postgresql://postgresql.data.svc.cluster.local:5432/${PG_PREFIX}_reporting"
    "REPORTING_DB_USERNAME=${PG_PREFIX}_reporting_user"
    "REPORTING_DB_PASSWORD=changeme_reporting"
    "READ_MODEL_DB_URL=jdbc:postgresql://postgresql.data.svc.cluster.local:5432/${PG_PREFIX}_readmodel"
    "READ_MODEL_DB_USERNAME=${PG_PREFIX}_readmodel_user"
    "READ_MODEL_DB_PASSWORD=changeme_readmodel"
    "KAFKA_BOOTSTRAP_SERVERS=kafka-kafka-bootstrap.messaging.svc.cluster.local:9092"
    "STORAGE_ENDPOINT=http://minio.infra.svc.cluster.local:9000"
    "STORAGE_BUCKET=${PROJECT}-reports"
    "STORAGE_ACCESS_KEY=minioadmin"
    "STORAGE_SECRET_KEY=changeme_minio"
    "REPORT_ETL_SCHEDULE=0 2 * * *"
  )

  vault_put "reporting-service" "${kvpairs[@]}"
}

# ─── Secrets de Keycloak admin (para realm/client provisioning) ───────────────
create_keycloak_admin_secrets() {
  log "Creando secrets de administración Keycloak..."
  vault_put "keycloak-admin" \
    "KEYCLOAK_ADMIN_URL=http://keycloak.identity.svc.cluster.local:8080" \
    "KEYCLOAK_ADMIN_USER=admin" \
    "KEYCLOAK_ADMIN_PASSWORD=changeme_kc_admin" \
    "KEYCLOAK_REALM=${PROJECT}"
}

# ─── Resumen ─────────────────────────────────────────────────────────────────
print_summary() {
  log ""
  log "══ Secrets en Vault ═══════════════════════════════════"
  log "  Path base:  secret/${PROJECT}/${ENV}/"
  log "  Vault UI:   http://${VM_IP}:8200"
  log ""
  log "  Para listar: vault kv list secret/${PROJECT}/${ENV}"
  log "  Para leer:   vault kv get secret/${PROJECT}/${ENV}/<servicio>"
  log ""
  [[ "$DRY_RUN" == true ]] && log "  (DRY-RUN: ningún secret fue creado)"
  log "════════════════════════════════════════════════════════"
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  log "create-all-secrets-vault — proyecto=$PROJECT env=$ENV"
  [[ "$DRY_RUN" == true ]] && log "Modo DRY-RUN activo"

  resolve_vault_token

  local ok=0 fail=0
  while IFS= read -r svc_dir; do
    if create_service_secret "$svc_dir"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done < <(discover_services)

  create_reporting_secrets
  create_keycloak_admin_secrets

  log ""
  log_ok "Secrets creados: $ok servicios  |  Fallidos: $fail"
  print_summary
}

main
