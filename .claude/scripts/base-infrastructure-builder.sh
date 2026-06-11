#!/usr/bin/env bash
# base-infrastructure-builder.sh — Aprovisiona la infraestructura base del proyecto
#
# Orquesta en orden:
#   1. Terraform init/apply — aprovisionamiento del VPS (OCI) o validación local
#   2. vps-setup.sh         — K3s + servicios base via Helm
#   3. init-databases.sh    — creación de bases de datos por servicio
#   4. setup-cicd-pipeline.sh — Jenkins + Gitea + ArgoCD
#   5. setup-observability.sh — Prometheus + Grafana + Loki + Tempo
#
# Uso: ./base-infrastructure-builder.sh [OPCIONES]
#
# Opciones:
#   --env         ENV        Entorno: local | prod             (default: local)
#   --vm-ip       IP         IP del VPS (requerido para prod o local ya provisionado)
#   --project     NAME       Nombre del proyecto               (requerido)
#   --pg-prefix   PREFIX     Prefijo para bases PostgreSQL     (requerido)
#   --mongo-prefix PREFIX    Prefijo para bases MongoDB        (requerido)
#   --tf-dir      DIR        Directorio Terraform              (default: infra/terraform)
#   --skip-tf                Omite Terraform (VPS ya existe)
#   --skip-helm              Omite vps-setup (K3s ya configurado)
#   --skip-db                Omite init-databases
#   --skip-cicd              Omite setup-cicd-pipeline
#   --skip-obs               Omite setup-observability
#   --dry-run                Muestra pasos sin ejecutar
#
# Ejemplos:
#   # Entorno local (VM QEMU ya corriendo):
#   ./base-infrastructure-builder.sh --env local --vm-ip 192.168.122.50 \
#     --project myapp --pg-prefix myapp --mongo-prefix myapp --skip-tf
#
#   # Entorno producción (OCI):
#   ./base-infrastructure-builder.sh --env prod --project myapp \
#     --pg-prefix myapp --mongo-prefix myapp --tf-dir infra/terraform/prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { err "$*"; exit 1; }

# ─── defaults ────────────────────────────────────────────────────────────────
ENV="local"
VM_IP=""
PROJECT=""
PG_PREFIX=""
MONGO_PREFIX=""
TF_DIR="infra/terraform"
SKIP_TF=false
SKIP_HELM=false
SKIP_DB=false
SKIP_CICD=false
SKIP_OBS=false
DRY_RUN=false

# ─── parsear argumentos ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)          ENV="$2";          shift 2 ;;
    --vm-ip)        VM_IP="$2";        shift 2 ;;
    --project)      PROJECT="$2";      shift 2 ;;
    --pg-prefix)    PG_PREFIX="$2";    shift 2 ;;
    --mongo-prefix) MONGO_PREFIX="$2"; shift 2 ;;
    --tf-dir)       TF_DIR="$2";       shift 2 ;;
    --skip-tf)      SKIP_TF=true;      shift   ;;
    --skip-helm)    SKIP_HELM=true;    shift   ;;
    --skip-db)      SKIP_DB=true;      shift   ;;
    --skip-cicd)    SKIP_CICD=true;    shift   ;;
    --skip-obs)     SKIP_OBS=true;     shift   ;;
    --dry-run)      DRY_RUN=true;      shift   ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$PROJECT" ]]     && die "--project es requerido"
[[ -z "$PG_PREFIX" ]]   && die "--pg-prefix es requerido"
[[ -z "$MONGO_PREFIX" ]] && die "--mongo-prefix es requerido"

# ─── helpers ─────────────────────────────────────────────────────────────────
run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
  else
    "$@"
  fi
}

require_script() {
  local script="$SCRIPT_DIR/$1"
  [[ -f "$script" ]] || die "Script no encontrado: $script"
  [[ -x "$script" ]] || chmod +x "$script"
}

# ─── FASE 1: Terraform ────────────────────────────────────────────────────────
phase_terraform() {
  header "FASE 1 — Terraform: aprovisionamiento VPS"

  if [[ "$SKIP_TF" == true ]]; then
    info "Saltando Terraform (--skip-tf)"
    return
  fi

  [[ -d "$TF_DIR" ]] || die "Directorio Terraform no encontrado: $TF_DIR"

  command -v terraform &>/dev/null || die "terraform no instalado. Ver: https://developer.hashicorp.com/terraform/install"

  info "Inicializando Terraform en $TF_DIR..."
  run terraform -chdir="$TF_DIR" init -input=false

  info "Validando configuración..."
  run terraform -chdir="$TF_DIR" validate

  info "Planificando..."
  run terraform -chdir="$TF_DIR" plan -out=tfplan -input=false \
    -var="env=$ENV" \
    -var="project=$PROJECT"

  info "Aplicando..."
  run terraform -chdir="$TF_DIR" apply -auto-approve tfplan

  # Extraer IP del output de Terraform si no fue pasada
  if [[ -z "$VM_IP" ]]; then
    VM_IP=$(terraform -chdir="$TF_DIR" output -raw vps_public_ip 2>/dev/null || true)
    [[ -n "$VM_IP" ]] && ok "IP del VPS extraída de Terraform: $VM_IP" \
      || warn "No se pudo extraer la IP. Pasa --vm-ip manualmente."
  fi
}

# ─── FASE 2: Helm / K3s ───────────────────────────────────────────────────────
phase_helm() {
  header "FASE 2 — vps-setup: K3s + servicios Helm"

  if [[ "$SKIP_HELM" == true ]]; then
    info "Saltando vps-setup (--skip-helm)"
    return
  fi

  [[ -n "$VM_IP" ]] || die "Se requiere --vm-ip para vps-setup"
  require_script "vps-setup.sh"

  run "$SCRIPT_DIR/vps-setup.sh" \
    --vm-ip "$VM_IP" \
    --env "$ENV" \
    --project "$PROJECT"
}

# ─── FASE 3: Bases de datos ───────────────────────────────────────────────────
phase_databases() {
  header "FASE 3 — init-databases: crear BDs por servicio"

  if [[ "$SKIP_DB" == true ]]; then
    info "Saltando init-databases (--skip-db)"
    return
  fi

  [[ -n "$VM_IP" ]] || die "Se requiere --vm-ip para init-databases"
  require_script "init-databases.sh"

  run "$SCRIPT_DIR/init-databases.sh" \
    --vm-ip "$VM_IP" \
    --pg-prefix "$PG_PREFIX" \
    --mongo-prefix "$MONGO_PREFIX" \
    --project "$PROJECT"
}

# ─── FASE 4: CI/CD ────────────────────────────────────────────────────────────
phase_cicd() {
  header "FASE 4 — setup-cicd-pipeline: Jenkins + Gitea + ArgoCD"

  if [[ "$SKIP_CICD" == true ]]; then
    info "Saltando setup-cicd-pipeline (--skip-cicd)"
    return
  fi

  [[ -n "$VM_IP" ]] || die "Se requiere --vm-ip para setup-cicd-pipeline"
  require_script "setup-cicd-pipeline.sh"

  run "$SCRIPT_DIR/setup-cicd-pipeline.sh" \
    --vm-ip "$VM_IP" \
    --project "$PROJECT" \
    --env "$ENV"
}

# ─── FASE 5: Observabilidad ───────────────────────────────────────────────────
phase_observability() {
  header "FASE 5 — setup-observability: Prometheus + Grafana + Loki + Tempo"

  if [[ "$SKIP_OBS" == true ]]; then
    info "Saltando setup-observability (--skip-obs)"
    return
  fi

  [[ -n "$VM_IP" ]] || die "Se requiere --vm-ip para setup-observability"
  require_script "setup-observability.sh"

  run "$SCRIPT_DIR/setup-observability.sh" \
    --vm-ip "$VM_IP" \
    --project "$PROJECT" \
    --env "$ENV"
}

# ─── resumen final ────────────────────────────────────────────────────────────
print_summary() {
  header "Infraestructura base lista"
  echo ""
  echo -e "  ${BOLD}Proyecto:${RESET}   $PROJECT"
  echo -e "  ${BOLD}Entorno:${RESET}    $ENV"
  [[ -n "$VM_IP" ]] && echo -e "  ${BOLD}VPS IP:${RESET}     $VM_IP"
  echo ""
  echo -e "  ${BOLD}Servicios disponibles (HTTP via Traefik):${RESET}"
  echo -e "    Gitea:      http://${VM_IP:-VPS_IP}:3000"
  echo -e "    Jenkins:    http://${VM_IP:-VPS_IP}:8080"
  echo -e "    ArgoCD:     http://${VM_IP:-VPS_IP}:8081"
  echo -e "    Keycloak:   http://${VM_IP:-VPS_IP}:8082"
  echo -e "    Vault:      http://${VM_IP:-VPS_IP}:8200"
  echo -e "    Grafana:    http://${VM_IP:-VPS_IP}:3001"
  echo -e "    Prometheus: http://${VM_IP:-VPS_IP}:9090"
  echo ""
  echo -e "  ${BOLD}Próximos pasos:${RESET}"
  echo -e "    1. Crear repos en Gitea:  http://${VM_IP:-VPS_IP}:3000"
  echo -e "    2. Ejecutar migraciones:  ./run-liquibase-migrations.sh --vm-ip ${VM_IP:-VPS_IP}"
  echo -e "    3. Configurar pipelines:  Jenkins → Nueva tarea multibranch"
  echo ""
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "base-infrastructure-builder — env=$ENV  proyecto=$PROJECT"
  [[ "$DRY_RUN" == true ]] && warn "Modo DRY-RUN activo — no se ejecutará nada"

  phase_terraform
  phase_helm
  phase_databases
  phase_cicd
  phase_observability
  print_summary
}

main
