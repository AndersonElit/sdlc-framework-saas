#!/usr/bin/env bash
# init-databases.sh — Crea bases de datos por microservicio (Database-per-Service)
#
# Conecta al pod PostgreSQL y MongoDB en K3s y crea las BDs
# siguiendo la convención: <prefijo>_<servicio_slug>
#
# Los servicios se leen de:
#   1. Argumento --services "svc1,svc2,..."
#   2. Archivo --services-file services.txt (un servicio por línea)
#   3. Auto-descubrimiento: lee el schema.sql de diseño y extrae comentarios BC-XX
#
# Uso: ./init-databases.sh [OPCIONES]
#
# Opciones:
#   --vm-ip         IP         IP del VPS                         (requerido)
#   --pg-prefix     PREFIX     Prefijo bases PostgreSQL           (requerido)
#   --mongo-prefix  PREFIX     Prefijo bases MongoDB              (requerido)
#   --project       NAME       Nombre del proyecto                (requerido)
#   --services      LIST       Servicios separados por coma       (ej: clientes,pedidos)
#   --services-file FILE       Archivo con un servicio por línea
#   --schema-sql    FILE       DDL de diseño para auto-descubrir servicios
#   --ssh-user      USER       Usuario SSH                        (default: ubuntu)
#   --ssh-key       FILE       Clave SSH privada                  (default: ~/.ssh/id_ed25519)
#   --pg-pass       PASS       Password admin PostgreSQL          (default: changeme_pg_admin)
#   --mongo-pass    PASS       Password admin MongoDB             (default: changeme_mongo_admin)
#   --dry-run                  Muestra comandos sin ejecutar
#
# Ejemplos:
#   ./init-databases.sh --vm-ip 192.168.122.50 --pg-prefix myapp --mongo-prefix myapp \
#     --project myapp --services "clientes-service,pedidos-service,pagos-service"
#
#   ./init-databases.sh --vm-ip 192.168.122.50 --pg-prefix myapp --mongo-prefix myapp \
#     --project myapp --schema-sql docs/design/database/SDD-myapp-schema.sql

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

VM_IP=""
PG_PREFIX=""
MONGO_PREFIX=""
PROJECT=""
SERVICES=""
SERVICES_FILE=""
SCHEMA_SQL=""
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
PG_PASS="changeme_pg_admin"
MONGO_PASS="changeme_mongo_admin"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)         VM_IP="$2";         shift 2 ;;
    --pg-prefix)     PG_PREFIX="$2";     shift 2 ;;
    --mongo-prefix)  MONGO_PREFIX="$2";  shift 2 ;;
    --project)       PROJECT="$2";       shift 2 ;;
    --services)      SERVICES="$2";      shift 2 ;;
    --services-file) SERVICES_FILE="$2"; shift 2 ;;
    --schema-sql)    SCHEMA_SQL="$2";    shift 2 ;;
    --ssh-user)      SSH_USER="$2";      shift 2 ;;
    --ssh-key)       SSH_KEY="$2";       shift 2 ;;
    --pg-pass)       PG_PASS="$2";       shift 2 ;;
    --mongo-pass)    MONGO_PASS="$2";    shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift   ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]      && die "--vm-ip es requerido"
[[ -z "$PG_PREFIX" ]]  && die "--pg-prefix es requerido"
[[ -z "$MONGO_PREFIX" ]] && die "--mongo-prefix es requerido"
[[ -z "$PROJECT" ]]    && die "--project es requerido"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
ssh_run() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

# ─── slug: transforma "my-service" → "my_service" ────────────────────────────
slugify() {
  echo "$1" | tr '-' '_' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g'
}

# ─── resolver lista de servicios ──────────────────────────────────────────────
resolve_services() {
  local -a svc_list=()

  if [[ -n "$SERVICES" ]]; then
    IFS=',' read -ra svc_list <<< "$SERVICES"

  elif [[ -n "$SERVICES_FILE" ]]; then
    [[ -f "$SERVICES_FILE" ]] || die "Archivo no encontrado: $SERVICES_FILE"
    mapfile -t svc_list < "$SERVICES_FILE"

  elif [[ -n "$SCHEMA_SQL" ]]; then
    [[ -f "$SCHEMA_SQL" ]] || die "Schema SQL no encontrado: $SCHEMA_SQL"
    info "Auto-descubriendo servicios desde $SCHEMA_SQL..."
    while IFS= read -r line; do
      if [[ "$line" =~ ^--[[:space:]]BC-[0-9]+:[[:space:]]*(.+)$ ]]; then
        local svc_raw="${BASH_REMATCH[1]}"
        svc_list+=("$(echo "$svc_raw" | xargs)")
      fi
    done < "$SCHEMA_SQL"
  fi

  if [[ ${#svc_list[@]} -eq 0 ]]; then
    die "No se encontraron servicios. Usa --services, --services-file o --schema-sql"
  fi

  # Siempre incluir BDs de soporte
  svc_list+=("keycloak" "gitea" "reporting")
  printf '%s\n' "${svc_list[@]}" | sort -u
}

# ─── crear BDs PostgreSQL ─────────────────────────────────────────────────────
create_pg_databases() {
  local services=("$@")
  header "Creando bases de datos PostgreSQL (prefijo: ${PG_PREFIX}_)"

  local pg_pod
  pg_pod=$(ssh_run "kubectl get pod -n data -l app.kubernetes.io/name=postgresql \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null")

  [[ -z "$pg_pod" ]] && die "Pod PostgreSQL no encontrado en namespace 'data'"
  info "Pod PostgreSQL: $pg_pod"

  for svc in "${services[@]}"; do
    local slug db_name
    slug=$(slugify "$svc")
    db_name="${PG_PREFIX}_${slug}"

    if [[ "$DRY_RUN" == true ]]; then
      echo -e "${YELLOW}[DRY-RUN]${RESET}  CREATE DATABASE $db_name"
      continue
    fi

    local exists
    exists=$(ssh_run "kubectl exec -n data $pg_pod -- \
      psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='${db_name}'\" \
      2>/dev/null" || true)

    if [[ "$exists" == "1" ]]; then
      warn "BD ya existe: $db_name — omitiendo"
    else
      ssh_run "kubectl exec -n data $pg_pod -- \
        psql -U postgres -c \"CREATE DATABASE \\\"${db_name}\\\"\" \
        -c \"CREATE USER \\\"${db_name}_user\\\" WITH PASSWORD 'changeme_${slug}' \" \
        -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${db_name}\\\" TO \\\"${db_name}_user\\\"\" \
        2>/dev/null"
      ok "PostgreSQL: $db_name  (user: ${db_name}_user)"
    fi
  done
}

# ─── crear BDs MongoDB ────────────────────────────────────────────────────────
create_mongo_databases() {
  local services=("$@")
  header "Creando bases de datos MongoDB (prefijo: ${MONGO_PREFIX}_)"

  # Solo servicios que usan MongoDB (por convención: los que terminan en -events o -log)
  # Por defecto creamos todas; el equipo puede filtrar con --services
  local mongo_pod
  mongo_pod=$(ssh_run "kubectl get pod -n data -l app.kubernetes.io/name=mongodb \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null")

  [[ -z "$mongo_pod" ]] && { warn "Pod MongoDB no encontrado — omitiendo BDs Mongo"; return; }
  info "Pod MongoDB: $mongo_pod"

  for svc in "${services[@]}"; do
    # Omitir servicios de soporte de Mongo (solo tienen PG)
    [[ "$svc" =~ ^(keycloak|gitea|reporting)$ ]] && continue

    local slug db_name
    slug=$(slugify "$svc")
    db_name="${MONGO_PREFIX}_${slug}"

    if [[ "$DRY_RUN" == true ]]; then
      echo -e "${YELLOW}[DRY-RUN]${RESET}  MongoDB: use $db_name + createUser"
      continue
    fi

    ssh_run "kubectl exec -n data $mongo_pod -- \
      mongosh --quiet -u root -p '${MONGO_PASS}' --authenticationDatabase admin \
      --eval \"
        use('${db_name}');
        db.getSiblingDB('${db_name}').createCollection('_init');
        try {
          db.getSiblingDB('${db_name}').createUser({
            user: '${slug}_user',
            pwd: 'changeme_${slug}',
            roles: [{ role: 'readWrite', db: '${db_name}' }]
          });
        } catch(e) { print('user exists: ' + e.message); }
      \" 2>/dev/null"
    ok "MongoDB: $db_name  (user: ${slug}_user)"
  done
}

# ─── resumen ─────────────────────────────────────────────────────────────────
print_summary() {
  local services=("$@")
  header "Resumen de bases de datos"
  echo ""
  printf "  %-40s %-25s %-25s\n" "Servicio" "PostgreSQL BD" "MongoDB BD"
  printf "  %-40s %-25s %-25s\n" "--------" "-------------" "----------"
  for svc in "${services[@]}"; do
    local slug="${PG_PREFIX}_$(slugify "$svc")"
    local mslug="${MONGO_PREFIX}_$(slugify "$svc")"
    printf "  %-40s %-25s %-25s\n" "$svc" "$slug" "$mslug"
  done
  echo ""
  warn "Contraseñas default: changeme_<slug> — rotar via Vault antes de producción"
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "init-databases — proyecto=$PROJECT"
  [[ "$DRY_RUN" == true ]] && warn "Modo DRY-RUN activo"

  mapfile -t SERVICES_LIST < <(resolve_services)
  info "Servicios a provisionar: ${SERVICES_LIST[*]}"

  create_pg_databases   "${SERVICES_LIST[@]}"
  create_mongo_databases "${SERVICES_LIST[@]}"
  print_summary "${SERVICES_LIST[@]}"
}

main
