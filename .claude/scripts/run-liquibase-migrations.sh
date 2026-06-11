#!/usr/bin/env bash
# run-liquibase-migrations.sh — Aplica migraciones Liquibase standalone para un microservicio
#
# Flujo:
#   1. Clona el repo <project>-migrations desde Gitea del VPS
#   2. Construye imagen Liquibase con el changelog del servicio
#   3. Ejecuta como Job K8s (o docker run en modo local) contra la BD del servicio
#
# Convención de rutas en el repo de migraciones:
#   <service-slug>/
#     changelog.yaml           — master changelog (incluye los archivos numerados)
#     00001_initial_schema.yaml
#     00002_*.yaml
#     ...
#
# Uso: ./run-liquibase-migrations.sh [OPCIONES]
#
# Opciones:
#   --vm-ip       IP       IP del VPS                              (requerido)
#   --project     NAME     Nombre del proyecto                     (requerido)
#   --service     NAME     Microservicio a migrar                  (requerido)
#   --pg-prefix   PREFIX   Prefijo BD PostgreSQL                   (requerido)
#   --env         ENV      local | prod                            (default: local)
#   --gitea-user  USER     Usuario Gitea                           (default: gitea_admin)
#   --gitea-pass  PASS     Password Gitea                          (default: changeme_gitea_admin)
#   --ssh-user    USER     Usuario SSH VPS                         (default: ubuntu)
#   --ssh-key     FILE     Clave SSH privada                       (default: ~/.ssh/id_ed25519)
#   --pg-pass     PASS     Password admin PostgreSQL               (default: changeme_pg_admin)
#   --tag         TAG      Tag changelog a ejecutar (default: empty = todos)
#   --rollback    COUNT    Rollback N changesets en vez de update
#   --dry-run              Muestra comandos sin ejecutar
#   --gitea-clone          Clonar desde Gitea (default). Si se omite usa directorio local.
#
# Ejemplos:
#   # Migrar un servicio desde Gitea:
#   ./run-liquibase-migrations.sh --vm-ip 192.168.122.50 --project myapp \
#     --service clientes-service --pg-prefix myapp --gitea-clone
#
#   # Rollback 1 changeset:
#   ./run-liquibase-migrations.sh --vm-ip 192.168.122.50 --project myapp \
#     --service clientes-service --pg-prefix myapp --rollback 1

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
SERVICE=""
PG_PREFIX=""
ENV="local"
GITEA_USER="gitea_admin"
GITEA_PASS="changeme_gitea_admin"
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
PG_PASS="changeme_pg_admin"
CHANGELOG_TAG=""
ROLLBACK_COUNT=""
DRY_RUN=false
GITEA_CLONE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)      VM_IP="$2";       shift 2 ;;
    --project)    PROJECT="$2";     shift 2 ;;
    --service)    SERVICE="$2";     shift 2 ;;
    --pg-prefix)  PG_PREFIX="$2";   shift 2 ;;
    --env)        ENV="$2";         shift 2 ;;
    --gitea-user) GITEA_USER="$2";  shift 2 ;;
    --gitea-pass) GITEA_PASS="$2";  shift 2 ;;
    --ssh-user)   SSH_USER="$2";    shift 2 ;;
    --ssh-key)    SSH_KEY="$2";     shift 2 ;;
    --pg-pass)    PG_PASS="$2";     shift 2 ;;
    --tag)        CHANGELOG_TAG="$2"; shift 2 ;;
    --rollback)   ROLLBACK_COUNT="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true;     shift ;;
    --gitea-clone) GITEA_CLONE=true; shift ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]     && die "--vm-ip es requerido"
[[ -z "$PROJECT" ]]   && die "--project es requerido"
[[ -z "$SERVICE" ]]   && die "--service es requerido"
[[ -z "$PG_PREFIX" ]] && die "--pg-prefix es requerido"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
ssh_run() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

slugify() { echo "$1" | tr '-' '_' | tr '[:upper:]' '[:lower:]'; }

SERVICE_SLUG=$(slugify "$SERVICE")
DB_NAME="${PG_PREFIX}_${SERVICE_SLUG}"
MIGRATIONS_REPO="${PROJECT}-migrations"
GITEA_URL="http://${VM_IP}:3000"

# ─── clonar repo de migraciones desde Gitea ──────────────────────────────────
clone_migrations_repo() {
  header "Clonando repo de migraciones: $MIGRATIONS_REPO"

  ssh_run bash -s <<REMOTE
set -euo pipefail
TMP_DIR=\$(mktemp -d)
echo "\$TMP_DIR"
CLONE_URL="http://${GITEA_USER}:${GITEA_PASS}@${VM_IP}:3000/${PROJECT}/${MIGRATIONS_REPO}.git"

if [[ -d "/tmp/${MIGRATIONS_REPO}" ]]; then
  echo "[INFO] Actualizando repo existente..."
  git -C "/tmp/${MIGRATIONS_REPO}" pull --rebase
else
  echo "[INFO] Clonando..."
  git clone "\$CLONE_URL" "/tmp/${MIGRATIONS_REPO}"
fi

CHANGELOG="/tmp/${MIGRATIONS_REPO}/${SERVICE_SLUG}/changelog.yaml"
if [[ ! -f "\$CHANGELOG" ]]; then
  echo "[WARN] Changelog no encontrado: \$CHANGELOG"
  echo "[INFO] Creando estructura inicial..."
  mkdir -p "/tmp/${MIGRATIONS_REPO}/${SERVICE_SLUG}"
  cat > "\$CHANGELOG" <<'EOF'
databaseChangeLog:
  - include:
      file: 00001_initial_schema.yaml
      relativeToChangelogFile: true
EOF
  touch "/tmp/${MIGRATIONS_REPO}/${SERVICE_SLUG}/00001_initial_schema.yaml"
  cat > "/tmp/${MIGRATIONS_REPO}/${SERVICE_SLUG}/00001_initial_schema.yaml" <<'EOF'
databaseChangeLog:
  - changeSet:
      id: 00001-init
      author: sdlc-framework
      comment: "Estructura inicial — completar con DDL del SDD"
      changes: []
EOF
  git -C "/tmp/${MIGRATIONS_REPO}" config user.email "ci@sdlc.local"
  git -C "/tmp/${MIGRATIONS_REPO}" config user.name  "SDLC CI"
  git -C "/tmp/${MIGRATIONS_REPO}" add .
  git -C "/tmp/${MIGRATIONS_REPO}" commit -m "ci: init changelog ${SERVICE_SLUG}" || true
  git -C "/tmp/${MIGRATIONS_REPO}" push || true
fi

echo "[OK] Repo listo: /tmp/${MIGRATIONS_REPO}"
REMOTE
}

# ─── ejecutar Liquibase como Job K8s ─────────────────────────────────────────
run_liquibase_job() {
  header "Ejecutando Liquibase: $SERVICE → $DB_NAME"

  local lb_command="update"
  local extra_args=""

  if [[ -n "$ROLLBACK_COUNT" ]]; then
    lb_command="rollbackCount"
    extra_args="$ROLLBACK_COUNT"
  elif [[ -n "$CHANGELOG_TAG" ]]; then
    lb_command="updateToTag"
    extra_args="$CHANGELOG_TAG"
  fi

  local changelog_path="/migrations/${SERVICE_SLUG}/changelog.yaml"
  local pg_host="postgresql.data.svc.cluster.local"
  local jdbc_url="jdbc:postgresql://${pg_host}:5432/${DB_NAME}"

  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET}  Liquibase $lb_command → $DB_NAME"
    return
  fi

  ssh_run bash -s <<REMOTE
set -euo pipefail
export KUBECONFIG=\$HOME/.kube/config

JOB_NAME="liquibase-${SERVICE_SLUG}-\$(date +%s)"

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: \${JOB_NAME}
  namespace: data
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: migrations
          hostPath:
            path: /tmp/${MIGRATIONS_REPO}
            type: Directory
      containers:
        - name: liquibase
          image: liquibase/liquibase:4.27
          args:
            - "--url=${jdbc_url}"
            - "--username=${DB_NAME}_user"
            - "--password=changeme_${SERVICE_SLUG}"
            - "--changeLogFile=${changelog_path}"
            - "--logLevel=info"
            - "${lb_command}"
            - "${extra_args}"
          volumeMounts:
            - name: migrations
              mountPath: /migrations
EOF

echo "[INFO] Job creado: \${JOB_NAME} — esperando..."
kubectl wait job/\${JOB_NAME} -n data \
  --for=condition=complete --timeout=5m 2>/dev/null || {
    kubectl logs -n data -l "job-name=\${JOB_NAME}" --tail=50
    echo "[ERROR] Job de migraciones falló"
    exit 1
  }

kubectl logs -n data -l "job-name=\${JOB_NAME}" --tail=20
echo "[OK] Migraciones aplicadas: ${DB_NAME}"
REMOTE
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "run-liquibase-migrations — service=$SERVICE  db=$DB_NAME  env=$ENV"
  [[ "$DRY_RUN" == true ]] && warn "Modo DRY-RUN activo"

  [[ "$GITEA_CLONE" == true ]] && clone_migrations_repo
  run_liquibase_job

  ok "Migraciones completadas para $SERVICE ($DB_NAME)"
}

main
