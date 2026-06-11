#!/usr/bin/env bash
# base-infrastructure-builder.sh — Punto de entrada único de infraestructura
#
# FLUJO:
#   1. Genera la estructura Terraform en $TF_ROOT (providers, modules, environments)
#   2. Instala K3s en el VPS via SSH y descarga el kubeconfig localmente
#   3. Ejecuta terraform init → plan → apply  (provider Helm gestiona todo el cluster)
#   4. Post-apply: init-databases, org/repos Gitea, Jenkins shared library
#
# PREREQUISITOS LOCALES:
#   terraform >= 1.7  (https://developer.hashicorp.com/terraform/install)
#   kubectl           (https://kubernetes.io/docs/tasks/tools/)
#   ssh access al VPS con la clave en --ssh-key
#
# Uso:
#   ./base-infrastructure-builder.sh --vm-ip <IP> --project <name> \
#     --pg-prefix <prefix> --mongo-prefix <prefix> [OPCIONES]
#
# Opciones:
#   --env            ENV      local | prod                (default: local)
#   --vm-ip          IP       IP del VPS                  (requerido)
#   --project        NAME     Slug del proyecto            (requerido)
#   --pg-prefix      PREFIX   Prefijo BDs PostgreSQL      (requerido)
#   --mongo-prefix   PREFIX   Prefijo BDs MongoDB         (requerido)
#   --services       LIST     Servicios CSV para DBs      (ej: "svc1,svc2")
#   --services-file  FILE     Archivo con servicios       (uno por línea)
#   --schema-sql     FILE     DDL diseño (auto-descubre)
#   --ssh-user       USER     Usuario SSH VPS             (default: ubuntu)
#   --ssh-key        FILE     Clave SSH privada           (default: ~/.ssh/id_ed25519)
#   --k3s-ver        VER      Versión K3s                (default: v1.31.4+k3s1)
#   --tf-root        DIR      Raíz Terraform generada    (default: ./terraform)
#   --no-lra                  Omite Narayana LRA
#   --no-wiremock             Omite WireMock
#   --no-kong                 Omite Kong Gateway (y su integración con Keycloak)
#   --no-minio                Omite MinIO (almacenamiento de objetos S3-compatible)
#   --no-loki                 Omite Loki/Promtail
#   --no-tempo                Omite Grafana Tempo
#   --skip-k3s                K3s ya instalado
#   --skip-terraform          Omite terraform apply
#   --skip-databases          Omite init-databases
#   --skip-gitea              Omite configuración Gitea
#   --skip-jenkins-lib        Omite Jenkins shared library
#   --dry-run                 Muestra pasos sin ejecutar
#
# Ejemplos:
#   ./base-infrastructure-builder.sh \
#     --vm-ip 192.168.122.50 --project myapp \
#     --pg-prefix myapp --mongo-prefix myapp \
#     --services "clientes-service,pedidos-service"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()    { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err(){ echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

# ─── defaults ─────────────────────────────────────────────────────────────────
ENV="local"
VM_IP=""
PROJECT=""
PG_PREFIX=""
MONGO_PREFIX=""
SERVICES=""
SERVICES_FILE=""
SCHEMA_SQL=""
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
K3S_VER="v1.31.4+k3s1"
TF_ROOT="${PROJECT_ROOT:-$(pwd)}/terraform"
INSTALL_LRA=true
INSTALL_WIREMOCK=true
INSTALL_LOKI=true
INSTALL_TEMPO=true
INSTALL_KONG=true
INSTALL_MINIO=true
SKIP_K3S=false
SKIP_TF=false
SKIP_DB=false
SKIP_GITEA=false
SKIP_JENKINS_LIB=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)             ENV="$2";            shift 2 ;;
    --vm-ip)           VM_IP="$2";          shift 2 ;;
    --project)         PROJECT="$2";        shift 2 ;;
    --pg-prefix)       PG_PREFIX="$2";      shift 2 ;;
    --mongo-prefix)    MONGO_PREFIX="$2";   shift 2 ;;
    --services)        SERVICES="$2";       shift 2 ;;
    --services-file)   SERVICES_FILE="$2";  shift 2 ;;
    --schema-sql)      SCHEMA_SQL="$2";     shift 2 ;;
    --ssh-user)        SSH_USER="$2";       shift 2 ;;
    --ssh-key)         SSH_KEY="$2";        shift 2 ;;
    --k3s-ver)         K3S_VER="$2";        shift 2 ;;
    --tf-root)         TF_ROOT="$2";        shift 2 ;;
    --no-lra)          INSTALL_LRA=false;   shift   ;;
    --no-wiremock)     INSTALL_WIREMOCK=false; shift ;;
    --no-kong)         INSTALL_KONG=false;  shift   ;;
    --no-minio)        INSTALL_MINIO=false; shift   ;;
    --no-loki)         INSTALL_LOKI=false;  shift   ;;
    --no-tempo)        INSTALL_TEMPO=false; shift   ;;
    --skip-k3s)        SKIP_K3S=true;       shift   ;;
    --skip-terraform)  SKIP_TF=true;        shift   ;;
    --skip-databases)  SKIP_DB=true;        shift   ;;
    --skip-gitea)      SKIP_GITEA=true;     shift   ;;
    --skip-jenkins-lib) SKIP_JENKINS_LIB=true; shift ;;
    --dry-run)         DRY_RUN=true;        shift   ;;
    *) log_err "Opción desconocida: $1"; exit 1 ;;
  esac
done

[[ -z "$VM_IP" ]]        && { log_err "--vm-ip es requerido"; exit 1; }
[[ -z "$PROJECT" ]]      && { log_err "--project es requerido"; exit 1; }
[[ -z "$PG_PREFIX" ]]    && { log_err "--pg-prefix es requerido"; exit 1; }
[[ -z "$MONGO_PREFIX" ]] && { log_err "--mongo-prefix es requerido"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
KUBECONFIG_PATH="$HOME/.kube/config-${PROJECT}-${ENV}"
ssh_vps() { ssh $SSH_OPTS "${SSH_USER}@${VM_IP}" "$@"; }

run() { [[ "$DRY_RUN" == true ]] && { echo "[DRY-RUN] $*"; return; }; "$@"; }

log "Iniciando base-infrastructure-builder (proyecto: $PROJECT, VPS: $VM_IP, env: $ENV)"

# ─────────────────────────────────────────────────────────────────────────────
# FASE 1 — Generar estructura Terraform
# ─────────────────────────────────────────────────────────────────────────────
generate_terraform() {
  log "Generando estructura Terraform en $TF_ROOT..."

  mkdir -p \
    "$TF_ROOT/modules/namespaces" \
    "$TF_ROOT/modules/helm-infra" \
    "$TF_ROOT/modules/helm-data" \
    "$TF_ROOT/modules/helm-identity" \
    "$TF_ROOT/modules/helm-secrets" \
    "$TF_ROOT/modules/helm-cicd" \
    "$TF_ROOT/modules/helm-observability" \
    "$TF_ROOT/modules/helm-support" \
    "$TF_ROOT/modules/helm-gateway" \
    "$TF_ROOT/environments"

  # ── providers.tf ────────────────────────────────────────────────────────────
  cat > "$TF_ROOT/providers.tf" << 'TFEOF'
terraform {
  required_version = ">= 1.7"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = "default"
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "default"
}
TFEOF

  # ── variables.tf ─────────────────────────────────────────────────────────────
  cat > "$TF_ROOT/variables.tf" << 'TFEOF'
variable "kubeconfig_path"          { type = string }
variable "vm_ip"                    { type = string }
variable "project"                  { type = string }
variable "env"                      { type = string; default = "local" }
variable "pg_admin_password"        { type = string; sensitive = true; default = "changeme_pg_admin" }
variable "mongo_admin_password"     { type = string; sensitive = true; default = "changeme_mongo_admin" }
variable "keycloak_admin_password"  { type = string; sensitive = true; default = "changeme_kc_admin" }
variable "gitea_admin_password"     { type = string; sensitive = true; default = "changeme_gitea_admin" }
variable "jenkins_admin_password"   { type = string; sensitive = true; default = "changeme_jenkins_admin" }
variable "grafana_admin_password"   { type = string; sensitive = true; default = "changeme_grafana_admin" }
variable "install_lra"              { type = bool; default = true }
variable "install_wiremock"         { type = bool; default = true }
variable "install_loki"             { type = bool; default = true }
variable "install_tempo"            { type = bool; default = true }
variable "install_kong"             { type = bool; default = true }
variable "keycloak_realm"           { type = string; default = "" }
variable "minio_root_password"       { type = string; sensitive = true; default = "changeme_minio" }
variable "install_minio"             { type = bool; default = true }
TFEOF

  # ── main.tf ──────────────────────────────────────────────────────────────────
  cat > "$TF_ROOT/main.tf" << 'TFEOF'
module "namespaces" {
  source = "./modules/namespaces"
}

module "helm_infra" {
  source              = "./modules/helm-infra"
  depends_on          = [module.namespaces]
  project             = var.project
  install_minio       = var.install_minio
  minio_root_password = var.minio_root_password
}

module "helm_data" {
  source               = "./modules/helm-data"
  depends_on           = [module.namespaces]
  pg_admin_password    = var.pg_admin_password
  mongo_admin_password = var.mongo_admin_password
  kubeconfig_path      = var.kubeconfig_path
}

module "helm_identity" {
  source                  = "./modules/helm-identity"
  depends_on              = [module.helm_data]
  vm_ip                   = var.vm_ip
  project                 = var.project
  keycloak_admin_password = var.keycloak_admin_password
  pg_admin_password       = var.pg_admin_password
}

module "helm_secrets" {
  source          = "./modules/helm-secrets"
  depends_on      = [module.namespaces]
  kubeconfig_path = var.kubeconfig_path
}

module "helm_cicd" {
  source                 = "./modules/helm-cicd"
  depends_on             = [module.helm_data, module.helm_secrets]
  vm_ip                  = var.vm_ip
  project                = var.project
  kubeconfig_path        = var.kubeconfig_path
  gitea_admin_password   = var.gitea_admin_password
  jenkins_admin_password = var.jenkins_admin_password
  pg_admin_password      = var.pg_admin_password
}

module "helm_observability" {
  source                 = "./modules/helm-observability"
  depends_on             = [module.namespaces]
  grafana_admin_password = var.grafana_admin_password
  install_loki           = var.install_loki
  install_tempo          = var.install_tempo
}

module "helm_support" {
  source           = "./modules/helm-support"
  depends_on       = [module.helm_infra]
  install_lra      = var.install_lra
  install_wiremock = var.install_wiremock
}

# ── API Gateway: Kong (depende de Keycloak para OIDC/JWT) ─────────────────────
module "helm_gateway" {
  source          = "./modules/helm-gateway"
  depends_on      = [module.helm_identity]
  install_kong    = var.install_kong
  vm_ip           = var.vm_ip
  kubeconfig_path = var.kubeconfig_path
  keycloak_realm  = var.keycloak_realm != "" ? var.keycloak_realm : var.project
}
TFEOF

  # ── outputs.tf ───────────────────────────────────────────────────────────────
  cat > "$TF_ROOT/outputs.tf" << 'TFEOF'
output "gitea_url"       { value = "http://${var.vm_ip}:3000" }
output "jenkins_url"     { value = "http://${var.vm_ip}:8080" }
output "argocd_url"      { value = "http://${var.vm_ip}:8081" }
output "keycloak_url"    { value = "http://${var.vm_ip}:8082" }
output "vault_url"       { value = "http://${var.vm_ip}:8200" }
output "grafana_url"     { value = "http://${var.vm_ip}:3001" }
output "prometheus_url"  { value = "http://${var.vm_ip}:9090" }
output "lra_url"         { value = var.install_lra      ? "http://${var.vm_ip}:50000" : "disabled" }
output "wiremock_url"    { value = var.install_wiremock ? "http://${var.vm_ip}:9999"  : "disabled" }
output "kafka_bootstrap" { value = "kafka-kafka-bootstrap.messaging.svc.cluster.local:9092" }
output "otel_grpc"       { value = var.install_tempo ? "tempo.observability.svc.cluster.local:4317" : "disabled" }
output "kong_proxy_url"  { value = var.install_kong ? "http://${var.vm_ip}:8000" : "disabled" }
output "kong_admin_url"    { value = var.install_kong  ? "kong-kong-admin.gateway.svc.cluster.local:8001 (ClusterIP)" : "disabled" }
output "minio_api_url"     { value = var.install_minio ? "http://${var.vm_ip}:9000" : "disabled" }
output "minio_console_url" { value = var.install_minio ? "http://${var.vm_ip}:9001" : "disabled" }
TFEOF

  # ── environments/local.tfvars ─────────────────────────────────────────────
  cat > "$TF_ROOT/environments/local.tfvars" << 'TFEOF'
env              = "local"
install_lra      = true
install_wiremock = true
install_loki     = true
install_tempo    = true
install_kong     = true
pg_admin_password       = "changeme_pg_admin"
mongo_admin_password    = "changeme_mongo_admin"
keycloak_admin_password = "changeme_kc_admin"
gitea_admin_password    = "changeme_gitea_admin"
jenkins_admin_password  = "changeme_jenkins_admin"
grafana_admin_password  = "changeme_grafana_admin"
minio_root_password     = "changeme_minio"
install_minio           = true
TFEOF

  cat > "$TF_ROOT/environments/prod.tfvars" << 'TFEOF'
env              = "prod"
install_lra      = true
install_wiremock = false
install_loki     = true
install_tempo    = true
install_kong     = true
# Contraseñas: pasar via TF_VAR_xxx — no commitear valores reales aquí
TFEOF

  # ── auto.tfvars (con variables del script — NO usar << 'EOF' aquí) ─────────
  cat > "$TF_ROOT/auto.tfvars" << TFEOF
# Auto-generado por base-infrastructure-builder.sh — no editar manualmente
kubeconfig_path  = "${KUBECONFIG_PATH}"
vm_ip            = "${VM_IP}"
project          = "${PROJECT}"
env              = "${ENV}"
install_lra      = ${INSTALL_LRA}
install_wiremock = ${INSTALL_WIREMOCK}
install_loki     = ${INSTALL_LOKI}
install_tempo    = ${INSTALL_TEMPO}
install_kong     = ${INSTALL_KONG}
install_minio    = ${INSTALL_MINIO}
keycloak_realm   = "${PROJECT}"
TFEOF

  # ── modules/namespaces/main.tf ────────────────────────────────────────────
  cat > "$TF_ROOT/modules/namespaces/main.tf" << 'TFEOF'
locals {
  namespaces = ["infra","identity","secrets","data","messaging","cicd","observability","gateway","apps"]
}
resource "kubernetes_namespace" "ns" {
  for_each = toset(local.namespaces)
  metadata {
    name   = each.value
    labels = { "managed-by" = "terraform" }
  }
  lifecycle { ignore_changes = [metadata[0].annotations] }
}
TFEOF

  # ── modules/helm-infra ────────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-infra/variables.tf" << 'TFEOF'
variable "project"             { type = string }
variable "install_minio"       { type = bool;   default = true }
variable "minio_root_password" { type = string; sensitive = true; default = "changeme_minio" }
TFEOF

  cat > "$TF_ROOT/modules/helm-infra/main.tf" << 'TFEOF'
resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://helm.traefik.io/traefik"
  chart      = "traefik"
  version    = "28.3.0"
  namespace  = "infra"
  wait       = true
  timeout    = 180
  set { name = "deployment.replicas";            value = "1" }
  set { name = "ports.web.exposedPort";          value = "80" }
  set { name = "ports.websecure.exposedPort";    value = "443" }
  set { name = "service.type";                   value = "NodePort" }
  set { name = "ports.traefik.expose.default";   value = "true" }
}
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.5"
  namespace  = "infra"
  wait       = true
  timeout    = 180
  set { name = "installCRDs";                    value = "true" }
  set { name = "resources.requests.memory";      value = "64Mi" }
}
resource "helm_release" "minio" {
  count      = var.install_minio ? 1 : 0
  name       = "minio"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "minio"
  version    = "14.7.14"
  namespace  = "infra"
  wait       = true
  timeout    = 300
  set           { name = "auth.rootUser";                value = "minioadmin" }
  set_sensitive { name = "auth.rootPassword";            value = var.minio_root_password }
  set           { name = "mode";                         value = "standalone" }
  set           { name = "persistence.size";             value = "10Gi" }
  set           { name = "service.type";                 value = "NodePort" }
  set           { name = "service.nodePorts.api";        value = "9000" }
  set           { name = "service.nodePorts.console";    value = "9001" }
  set           { name = "resources.requests.memory";    value = "256Mi" }
  set           { name = "resources.requests.cpu";       value = "100m" }
  values = [<<-YAML
    provisioning:
      enabled: true
      buckets:
        - name: "${var.project}-reports"
          region: us-east-1
          versioning: false
  YAML
  ]
}
TFEOF

  # ── modules/helm-data ────────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-data/variables.tf" << 'TFEOF'
variable "pg_admin_password"    { type = string; sensitive = true }
variable "mongo_admin_password" { type = string; sensitive = true }
variable "kubeconfig_path"      { type = string }
TFEOF

  # Kafka CRs como archivo YAML separado (evita heredocs anidados en Terraform)
  cat > "$TF_ROOT/modules/helm-data/kafka-cluster.yaml" << 'YAML'
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: combined
  labels:
    strimzi.io/cluster: kafka
spec:
  replicas: 1
  roles: [controller, broker]
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
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
YAML

  cat > "$TF_ROOT/modules/helm-data/main.tf" << 'TFEOF'
resource "helm_release" "postgresql" {
  name       = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "15.5.17"
  namespace  = "data"
  wait       = true
  timeout    = 300
  set           { name = "image.tag";                         value = "16" }
  set_sensitive { name = "auth.postgresPassword";             value = var.pg_admin_password }
  set           { name = "primary.persistence.size";          value = "10Gi" }
  set           { name = "primary.resources.requests.memory"; value = "256Mi" }
  set           { name = "primary.resources.requests.cpu";    value = "100m" }
}
resource "helm_release" "mongodb" {
  name       = "mongodb"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "mongodb"
  version    = "15.6.18"
  namespace  = "data"
  wait       = true
  timeout    = 300
  set           { name = "image.tag";                    value = "7.0" }
  set_sensitive { name = "auth.rootPassword";            value = var.mongo_admin_password }
  set           { name = "persistence.size";             value = "10Gi" }
  set           { name = "resources.requests.memory";    value = "256Mi" }
  set           { name = "resources.requests.cpu";       value = "100m" }
}
resource "helm_release" "strimzi_operator" {
  name       = "strimzi-kafka-operator"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = "0.40.0"
  namespace  = "messaging"
  wait       = true
  timeout    = 300
}
# Kafka CRs aplicados después de que el operator instale los CRDs
resource "null_resource" "kafka_cluster" {
  depends_on = [helm_release.strimzi_operator]
  provisioner "local-exec" {
    command = "kubectl --kubeconfig='${var.kubeconfig_path}' apply -n messaging -f '${path.module}/kafka-cluster.yaml'"
  }
  triggers = { strimzi_version = helm_release.strimzi_operator.version }
}
TFEOF

  # ── modules/helm-identity ─────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-identity/variables.tf" << 'TFEOF'
variable "vm_ip"                   { type = string }
variable "project"                 { type = string }
variable "keycloak_admin_password" { type = string; sensitive = true }
variable "pg_admin_password"       { type = string; sensitive = true }
TFEOF

  cat > "$TF_ROOT/modules/helm-identity/main.tf" << 'TFEOF'
resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "keycloak"
  version    = "21.4.4"
  namespace  = "identity"
  wait       = true
  timeout    = 600
  set           { name = "auth.adminUser";               value = "admin" }
  set_sensitive { name = "auth.adminPassword";           value = var.keycloak_admin_password }
  set           { name = "postgresql.enabled";           value = "false" }
  set           { name = "externalDatabase.host";        value = "postgresql.data.svc.cluster.local" }
  set           { name = "externalDatabase.port";        value = "5432" }
  set           { name = "externalDatabase.user";        value = "postgres" }
  set_sensitive { name = "externalDatabase.password";    value = var.pg_admin_password }
  set           { name = "externalDatabase.database";    value = "keycloak" }
  set           { name = "service.type";                 value = "NodePort" }
  set           { name = "service.nodePorts.http";       value = "8082" }
  set           { name = "replicaCount";                 value = "1" }
  set           { name = "resources.requests.memory";    value = "512Mi" }
  set           { name = "resources.requests.cpu";       value = "250m" }
}
TFEOF

  # ── modules/helm-secrets ──────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-secrets/variables.tf" << 'TFEOF'
variable "kubeconfig_path" { type = string }
TFEOF

  # Script de post-init de Vault (unseal + KV v2 + política base)
  # Se genera como archivo separado para evitar quoting anidado en el null_resource
  cat > "$TF_ROOT/modules/helm-secrets/vault-post-init.sh" << 'BASH'
#!/usr/bin/env bash
# vault-post-init.sh — Unseal Vault, habilita KV v2, crea política base de servicios
# Ejecutado por Terraform null_resource después de vault_init
set -euo pipefail
KUBECONFIG_PATH="$1"
INIT_FILE="${2:-vault-init.json}"

if [[ ! -f "$INIT_FILE" ]]; then
  echo "[SKIP] $INIT_FILE no encontrado — Vault ya configurado o unseal manual requerido"
  exit 0
fi

UNSEAL_KEY=$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['unseal_keys_b64'][0])" 2>/dev/null \
  || jq -r '.unseal_keys_b64[0]' "$INIT_FILE" 2>/dev/null || true)
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['root_token'])" 2>/dev/null \
  || jq -r '.root_token' "$INIT_FILE" 2>/dev/null || true)

[[ -z "$UNSEAL_KEY" || -z "$ROOT_TOKEN" ]] && { echo "[SKIP] Claves no legibles"; exit 0; }

echo "[INFO] Unsealing Vault..."
kubectl --kubeconfig="$KUBECONFIG_PATH" exec -n secrets vault-0 -- \
  vault operator unseal "$UNSEAL_KEY" 2>/dev/null || echo "[INFO] Ya estaba unsealed"

echo "[INFO] Habilitando KV v2 en secret/..."
kubectl --kubeconfig="$KUBECONFIG_PATH" exec -n secrets vault-0 -- \
  sh -c "VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=secret kv-v2 2>/dev/null \
    || echo '[SKIP] KV v2 ya habilitado'"

echo "[INFO] Creando política services-read..."
printf 'path "secret/data/*/*" { capabilities = ["read"] }\npath "secret/metadata/*/*" { capabilities = ["list","read"] }\n' \
  | kubectl --kubeconfig="$KUBECONFIG_PATH" exec -i -n secrets vault-0 -- \
    sh -c "VAULT_TOKEN=$ROOT_TOKEN vault policy write services-read -"

echo "[INFO] Habilitando auth method kubernetes..."
kubectl --kubeconfig="$KUBECONFIG_PATH" exec -n secrets vault-0 -- \
  sh -c "VAULT_TOKEN=$ROOT_TOKEN vault auth enable kubernetes 2>/dev/null \
    || echo '[SKIP] kubernetes auth ya habilitado'"

echo "[OK] Vault: unsealed + KV v2 secret/ + policy services-read + kubernetes auth"
BASH

  cat > "$TF_ROOT/modules/helm-secrets/main.tf" << 'TFEOF'
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.28.0"
  namespace  = "secrets"
  wait       = true
  timeout    = 300
  values = [<<-YAML
    server:
      dev:
        enabled: false
      standalone:
        enabled: true
        config: |
          ui = true
          listener "tcp" {
            tls_disable     = 1
            address         = "[::]:8200"
            cluster_address = "[::]:8201"
          }
          storage "file" {
            path = "/vault/data"
          }
      dataStorage:
        enabled: true
        size: 2Gi
      service:
        type: NodePort
        nodePort: 8200
    ui:
      enabled: true
  YAML
  ]
}

# Inicializa Vault (genera vault-init.json con unseal key + root token)
resource "null_resource" "vault_init" {
  depends_on = [helm_release.vault]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[INFO] Esperando Vault pod Ready..."
      kubectl --kubeconfig='${var.kubeconfig_path}' wait pod/vault-0 \
        -n secrets --for=condition=Ready --timeout=120s || true
      echo "[INFO] Inicializando Vault (idempotente)..."
      kubectl --kubeconfig='${var.kubeconfig_path}' exec -n secrets vault-0 -- \
        vault operator init -key-shares=1 -key-threshold=1 -format=json \
        > vault-init.json 2>/dev/null \
        && echo "[OK] vault-init.json generado — guardar en lugar seguro" \
        || echo "[SKIP] Vault ya inicializado"
    CMD
  }
  triggers = { vault_version = helm_release.vault.version }
}

# Unseal + habilitar KV v2 + política base de servicios + kubernetes auth
resource "null_resource" "vault_setup" {
  depends_on = [null_resource.vault_init]
  provisioner "local-exec" {
    command = "bash '${path.module}/vault-post-init.sh' '${var.kubeconfig_path}' vault-init.json"
  }
  triggers = { vault_init_id = null_resource.vault_init.id }
}
TFEOF

  # ── modules/helm-cicd ────────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-cicd/variables.tf" << 'TFEOF'
variable "vm_ip"                  { type = string }
variable "project"                { type = string }
variable "kubeconfig_path"        { type = string }
variable "gitea_admin_password"   { type = string; sensitive = true }
variable "jenkins_admin_password" { type = string; sensitive = true }
variable "pg_admin_password"      { type = string; sensitive = true }
TFEOF

  # Plantilla AppProject
  cat > "$TF_ROOT/modules/helm-cicd/argocd-appproject.yaml.tpl" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: __PROJECT__
  namespace: cicd
spec:
  description: "Project __PROJECT__"
  sourceRepos:
    - 'http://__VM_IP__:3000/__PROJECT__/*'
  destinations:
    - namespace: apps
      server: https://kubernetes.default.svc
    - namespace: infra
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
YAML

  # Plantilla ApplicationSet — Git generator sobre helm-charts repo
  # setup-cicd-pipeline.sh agrega entradas en charts/<servicio>/values-<env>.yaml
  cat > "$TF_ROOT/modules/helm-cicd/argocd-applicationset.yaml.tpl" << 'YAML'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: __PROJECT__-services
  namespace: cicd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: 'http://__VM_IP__:3000/__PROJECT__/__PROJECT__-helm-charts.git'
        revision: main
        directories:
          - path: 'charts/*'
  template:
    metadata:
      name: '__PROJECT__-{{.path.basename}}'
    spec:
      project: __PROJECT__
      source:
        repoURL: 'http://__VM_IP__:3000/__PROJECT__/__PROJECT__-helm-charts.git'
        targetRevision: main
        path: '{{.path.path}}'
        helm:
          valueFiles:
            - values-__ENV__.yaml
      destination:
        server: https://kubernetes.default.svc
        namespace: apps
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
YAML

  cat > "$TF_ROOT/modules/helm-cicd/main.tf" << 'TFEOF'
resource "kubernetes_service_account" "jenkins" {
  metadata { name = "jenkins"; namespace = "cicd" }
}
resource "kubernetes_cluster_role_binding" "jenkins" {
  metadata { name = "jenkins-cluster-admin" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.jenkins.metadata[0].name
    namespace = "cicd"
  }
}
resource "helm_release" "gitea" {
  name       = "gitea"
  repository = "https://dl.gitea.com/charts/"
  chart      = "gitea"
  version    = "10.4.0"
  namespace  = "cicd"
  wait       = true
  timeout    = 300
  set           { name = "gitea.admin.username";               value = "gitea_admin" }
  set_sensitive { name = "gitea.admin.password";               value = var.gitea_admin_password }
  set           { name = "gitea.admin.email";                  value = "admin@${var.project}.local" }
  set           { name = "postgresql.enabled";                 value = "false" }
  set           { name = "gitea.config.database.DB_TYPE";      value = "postgres" }
  set           { name = "gitea.config.database.HOST";         value = "postgresql.data.svc.cluster.local:5432" }
  set           { name = "gitea.config.database.NAME";         value = "gitea" }
  set           { name = "gitea.config.database.USER";         value = "postgres" }
  set_sensitive { name = "gitea.config.database.PASSWD";       value = var.pg_admin_password }
  set           { name = "gitea.config.server.DOMAIN";         value = var.vm_ip }
  set           { name = "gitea.config.server.ROOT_URL";       value = "http://${var.vm_ip}:3000" }
  set           { name = "gitea.config.packages.ENABLED";      value = "true" }
  set           { name = "service.http.type";                  value = "NodePort" }
  set           { name = "service.http.nodePort";              value = "3000" }
  set           { name = "persistence.size";                   value = "5Gi" }
}
resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "jenkins"
  version    = "13.4.2"
  namespace  = "cicd"
  wait       = true
  timeout    = 600
  depends_on = [kubernetes_service_account.jenkins]
  set           { name = "service.type";               value = "NodePort" }
  set           { name = "service.nodePorts.http";     value = "8080" }
  set           { name = "jenkinsUser";                value = "admin" }
  set_sensitive { name = "jenkinsPassword";            value = var.jenkins_admin_password }
  set           { name = "persistence.size";           value = "5Gi" }
  set           { name = "resources.requests.memory";  value = "512Mi" }
  set           { name = "resources.requests.cpu";     value = "250m" }
}
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "argo-cd"
  version    = "6.0.5"
  namespace  = "cicd"
  wait       = true
  timeout    = 600
  set { name = "server.service.type";                   value = "NodePort" }
  set { name = "server.service.nodePorts.http";         value = "8081" }
  set { name = "server.extraArgs";                      value = "{--insecure}" }
  set { name = "redis.enabled";                         value = "true" }
  set { name = "repoServer.resources.requests.memory";  value = "128Mi" }
}
# AppProject — sustituye __PROJECT__ y __VM_IP__ via sed
resource "null_resource" "argocd_appproject" {
  depends_on = [helm_release.argocd]
  provisioner "local-exec" {
    command = <<-CMD
      sleep 15
      sed -e 's/__PROJECT__/${var.project}/g' \
          -e 's/__VM_IP__/${var.vm_ip}/g' \
          '${path.module}/argocd-appproject.yaml.tpl' \
      | kubectl --kubeconfig='${var.kubeconfig_path}' apply -f -
    CMD
  }
  triggers = { project = var.project; argocd_v = helm_release.argocd.version }
}
# ApplicationSet — Git generator: auto-descubre servicios desde charts/ en helm-charts repo
resource "null_resource" "argocd_applicationset" {
  depends_on = [null_resource.argocd_appproject]
  provisioner "local-exec" {
    command = <<-CMD
      sed -e 's/__PROJECT__/${var.project}/g' \
          -e 's/__VM_IP__/${var.vm_ip}/g' \
          -e 's/__ENV__/${var.env}/g' \
          '${path.module}/argocd-applicationset.yaml.tpl' \
      | kubectl --kubeconfig='${var.kubeconfig_path}' apply -f -
    CMD
  }
  triggers = { project = var.project; env = var.env; argocd_v = helm_release.argocd.version }
}
TFEOF

  # ── modules/helm-observability ────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-observability/variables.tf" << 'TFEOF'
variable "grafana_admin_password" { type = string; sensitive = true }
variable "install_loki"           { type = bool; default = true }
variable "install_tempo"          { type = bool; default = true }
TFEOF

  cat > "$TF_ROOT/modules/helm-observability/main.tf" << 'TFEOF'
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "58.1.3"
  namespace  = "observability"
  wait       = true
  timeout    = 600
  set           { name = "prometheus.prometheusSpec.retention";        value = "7d" }
  set           { name = "prometheus.service.type";                    value = "NodePort" }
  set           { name = "prometheus.service.nodePort";                value = "9090" }
  set_sensitive { name = "grafana.adminPassword";                      value = var.grafana_admin_password }
  set           { name = "grafana.service.type";                       value = "NodePort" }
  set           { name = "grafana.service.nodePort";                   value = "3001" }
  set           { name = "grafana.persistence.enabled";                value = "true" }
  set           { name = "grafana.persistence.size";                   value = "2Gi" }
  set           { name = "defaultRules.create";                        value = "true" }
}
resource "helm_release" "loki" {
  count      = var.install_loki ? 1 : 0
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.5.2"
  namespace  = "observability"
  wait       = true
  timeout    = 300
  values = [<<-YAML
    deploymentMode: SingleBinary
    loki:
      commonConfig:
        replication_factor: 1
      storage:
        type: filesystem
    singleBinary:
      replicas: 1
      persistence:
        size: 5Gi
    read:
      replicas: 0
    write:
      replicas: 0
    backend:
      replicas: 0
  YAML
  ]
}
resource "helm_release" "promtail" {
  count      = var.install_loki ? 1 : 0
  depends_on = [helm_release.loki]
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.15.5"
  namespace  = "observability"
  wait       = true
  timeout    = 180
  set { name = "config.lokiAddress"; value = "http://loki:3100/loki/api/v1/push" }
}
resource "helm_release" "tempo" {
  count      = var.install_tempo ? 1 : 0
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.9.0"
  namespace  = "observability"
  wait       = true
  timeout    = 300
  values = [<<-YAML
    tempo:
      storage:
        trace:
          backend: local
          local:
            path: /var/tempo/traces
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: "0.0.0.0:4317"
            http:
              endpoint: "0.0.0.0:4318"
    persistence:
      enabled: true
      size: 5Gi
  YAML
  ]
}
TFEOF

  # ── modules/helm-support ──────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-support/variables.tf" << 'TFEOF'
variable "install_lra"      { type = bool; default = true }
variable "install_wiremock" { type = bool; default = true }
TFEOF

  cat > "$TF_ROOT/modules/helm-support/main.tf" << 'TFEOF'
resource "kubernetes_deployment" "lra_coordinator" {
  count = var.install_lra ? 1 : 0
  metadata {
    name      = "lra-coordinator"
    namespace = "infra"
    labels    = { app = "lra-coordinator" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "lra-coordinator" } }
    template {
      metadata { labels = { app = "lra-coordinator" } }
      spec {
        container {
          name  = "lra-coordinator"
          image = "quay.io/jbosstm/lra-coordinator:latest"
          port  { container_port = 8080 }
          env   { name = "QUARKUS_HTTP_PORT"; value = "8080" }
          resources { requests = { memory = "128Mi"; cpu = "100m" } }
        }
      }
    }
  }
}
resource "kubernetes_service" "lra_coordinator" {
  count      = var.install_lra ? 1 : 0
  depends_on = [kubernetes_deployment.lra_coordinator]
  metadata { name = "lra-coordinator"; namespace = "infra" }
  spec {
    type     = "NodePort"
    selector = { app = "lra-coordinator" }
    port { port = 8080; target_port = 8080; node_port = 50000 }
  }
}
resource "kubernetes_deployment" "wiremock" {
  count = var.install_wiremock ? 1 : 0
  metadata {
    name      = "wiremock"
    namespace = "infra"
    labels    = { app = "wiremock" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "wiremock" } }
    template {
      metadata { labels = { app = "wiremock" } }
      spec {
        container {
          name  = "wiremock"
          image = "wiremock/wiremock:3x"
          args  = ["--port=9999", "--verbose"]
          port  { container_port = 9999 }
          resources { requests = { memory = "128Mi"; cpu = "100m" } }
        }
      }
    }
  }
}
resource "kubernetes_service" "wiremock" {
  count      = var.install_wiremock ? 1 : 0
  depends_on = [kubernetes_deployment.wiremock]
  metadata { name = "wiremock"; namespace = "infra" }
  spec {
    type     = "NodePort"
    selector = { app = "wiremock" }
    port { port = 9999; target_port = 9999; node_port = 9999 }
  }
}
TFEOF

  # ── modules/helm-gateway ─────────────────────────────────────────────────
  cat > "$TF_ROOT/modules/helm-gateway/variables.tf" << 'TFEOF'
variable "install_kong"    { type = bool;   default = true }
variable "vm_ip"           { type = string }
variable "kubeconfig_path" { type = string }
variable "keycloak_realm"  { type = string }
TFEOF

  # Script de integración Kong ↔ Keycloak (se ejecuta post-deploy via null_resource)
  cat > "$TF_ROOT/modules/helm-gateway/kong-keycloak-setup.sh" << 'BASH'
#!/usr/bin/env bash
# kong-keycloak-setup.sh — Configura Kong JWT plugin con la clave pública de Keycloak
set -euo pipefail
KUBECONFIG_PATH="$1"
KEYCLOAK_URL="${2:-http://keycloak.identity.svc.cluster.local:8080}"
KEYCLOAK_REALM="${3:-myproject}"

echo "[INFO] Esperando Kong Admin API..."
kubectl --kubeconfig="$KUBECONFIG_PATH" wait deploy/kong-kong \
  -n gateway --for=condition=Available --timeout=120s || true

# Port-forward Kong Admin API (ClusterIP — solo accesible dentro del cluster)
kubectl --kubeconfig="$KUBECONFIG_PATH" \
  port-forward -n gateway svc/kong-kong-admin 18001:8001 &>/dev/null &
PF_PID=$!
sleep 5

KONG_ADMIN="http://localhost:18001"

echo "[INFO] Obteniendo clave pública de Keycloak (realm: $KEYCLOAK_REALM)..."
PUBLIC_KEY=$(curl -sf "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('public_key',''))" 2>/dev/null || true)

if [[ -n "$PUBLIC_KEY" ]]; then
  PEM="-----BEGIN PUBLIC KEY-----\n${PUBLIC_KEY}\n-----END PUBLIC KEY-----"

  # Consumer genérico para tokens Keycloak
  curl -sf -X PUT "${KONG_ADMIN}/consumers/keycloak-users" \
    -H "Content-Type: application/json" \
    -d '{"username":"keycloak-users"}' -o /dev/null 2>/dev/null || true

  # Registrar RSA public key como credencial JWT
  curl -sf -X POST "${KONG_ADMIN}/consumers/keycloak-users/jwt" \
    -H "Content-Type: application/json" \
    -d "{
      \"algorithm\": \"RS256\",
      \"key\":       \"${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}\",
      \"rsa_public_key\": \"${PEM}\"
    }" -o /dev/null 2>/dev/null \
    && echo "[OK] Clave pública Keycloak registrada en Kong (consumer: keycloak-users)" \
    || echo "[SKIP] Credencial JWT ya registrada"
else
  echo "[WARN] No se pudo obtener la clave pública de Keycloak — configura manualmente"
fi

# Plugin JWT global (valida tokens en todos los servicios registrados en Kong)
curl -sf -X POST "${KONG_ADMIN}/plugins" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "jwt",
    "config": {
      "key_claim_name":    "iss",
      "claims_to_verify":  ["exp"],
      "uri_param_names":   ["jwt"],
      "cookie_names":      []
    }
  }' -o /dev/null 2>/dev/null \
  && echo "[OK] Plugin JWT global habilitado en Kong" \
  || echo "[SKIP] Plugin JWT ya configurado"

# Plugin rate-limiting global (protección básica)
curl -sf -X POST "${KONG_ADMIN}/plugins" \
  -H "Content-Type: application/json" \
  -d '{"name":"rate-limiting","config":{"minute":200,"policy":"local"}}' \
  -o /dev/null 2>/dev/null \
  && echo "[OK] Plugin rate-limiting global habilitado" || true

# Plugin CORS global
curl -sf -X POST "${KONG_ADMIN}/plugins" \
  -H "Content-Type: application/json" \
  -d '{"name":"cors","config":{"origins":["*"],"methods":["GET","POST","PUT","PATCH","DELETE","OPTIONS"],"headers":["Authorization","Content-Type","Accept"],"exposed_headers":["X-Auth-Token"],"credentials":true,"max_age":3600}}' \
  -o /dev/null 2>/dev/null \
  && echo "[OK] Plugin CORS global habilitado" || true

kill $PF_PID 2>/dev/null || true
echo "[OK] Configuración Kong-Keycloak completada"
BASH

  cat > "$TF_ROOT/modules/helm-gateway/main.tf" << 'TFEOF'
# Añadir repo Kong a Helm antes de usar este módulo:
#   helm repo add kong https://charts.konghq.com && helm repo update

resource "helm_release" "kong" {
  count = var.install_kong ? 1 : 0

  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  version    = "2.38.0"
  namespace  = "gateway"
  wait       = true
  timeout    = 300

  values = [<<-YAML
    # Modo DB-less: no requiere PostgreSQL
    env:
      database: "off"

    # Proxy (entrada de tráfico de usuarios)
    proxy:
      type: NodePort
      http:
        enabled: true
        nodePort: 8000
      tls:
        enabled: false

    # Admin API (solo ClusterIP — no exponer al exterior)
    admin:
      enabled: true
      type: ClusterIP
      http:
        enabled: true

    # Ingress Controller (gestión de rutas via KongIngress / HTTPRoute)
    ingressController:
      enabled: true
      installCRDs: true
      env:
        kong_admin_url: http://localhost:8001

    resources:
      requests:
        memory: 256Mi
        cpu:    100m
      limits:
        memory: 512Mi
        cpu:    "500m"
  YAML
  ]
}

# Agregar repo Kong al cluster (necesario antes del apply)
resource "null_resource" "kong_helm_repo" {
  count      = var.install_kong ? 1 : 0
  depends_on = []

  provisioner "local-exec" {
    command = <<-CMD
      helm --kubeconfig='${var.kubeconfig_path}' repo add kong https://charts.konghq.com 2>/dev/null || true
      helm --kubeconfig='${var.kubeconfig_path}' repo update
    CMD
  }
  triggers = { always = timestamp() }
}

# Configurar Kong con JWT plugin + clave pública Keycloak
resource "null_resource" "kong_keycloak_setup" {
  count      = var.install_kong ? 1 : 0
  depends_on = [helm_release.kong]

  provisioner "local-exec" {
    command = <<-CMD
      bash '${path.module}/kong-keycloak-setup.sh' \
        '${var.kubeconfig_path}' \
        'http://keycloak.identity.svc.cluster.local:8080' \
        '${var.keycloak_realm}'
    CMD
  }
  triggers = {
    kong_version   = var.install_kong ? helm_release.kong[0].version : "disabled"
    keycloak_realm = var.keycloak_realm
  }
}
TFEOF

  log_ok "Estructura Terraform generada en $TF_ROOT"
}

# ─────────────────────────────────────────────────────────────────────────────
# FASE 2 — Instalar K3s y descargar kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
install_k3s() {
  if [[ "$SKIP_K3S" == true ]]; then
    log "Saltando K3s (--skip-k3s)"
    if [[ ! -f "$KUBECONFIG_PATH" && "$DRY_RUN" == false ]]; then
      log "Descargando kubeconfig existente..."
      scp $SSH_OPTS "${SSH_USER}@${VM_IP}:.kube/config" "$KUBECONFIG_PATH"
      sed -i "s/127.0.0.1/${VM_IP}/g" "$KUBECONFIG_PATH"
    fi
    return
  fi

  log "Verificando conectividad SSH al VPS ($VM_IP)..."
  ssh_vps "echo OK" &>/dev/null \
    || { log_err "No se puede conectar al VPS $VM_IP. Verifica IP y clave $SSH_KEY"; exit 1; }
  log_ok "VPS $VM_IP accesible via SSH."

  [[ "$DRY_RUN" == true ]] && { log "[DRY-RUN] Instalaría K3s $K3S_VER en $VM_IP"; return; }

  ssh_vps bash -s <<REMOTE
set -euo pipefail
if command -v k3s &>/dev/null && k3s kubectl get nodes &>/dev/null 2>&1; then
  echo "[SKIP] K3s ya instalado: \$(k3s --version | head -1)"
  exit 0
fi
echo "[INFO] Instalando K3s ${K3S_VER}..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VER}" sh -s - \
  --disable traefik \
  --write-kubeconfig-mode 644 \
  --node-name "${PROJECT}-node"
echo "[INFO] Esperando nodo Ready..."
timeout 120 bash -c 'until k3s kubectl get nodes 2>/dev/null | grep -q Ready; do sleep 3; done'
k3s kubectl get nodes
mkdir -p \$HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
sed -i "s/127.0.0.1/${VM_IP}/g" \$HOME/.kube/config
echo "[OK] K3s listo"
REMOTE

  mkdir -p "$HOME/.kube"
  scp $SSH_OPTS "${SSH_USER}@${VM_IP}:.kube/config" "$KUBECONFIG_PATH"
  sed -i "s/127.0.0.1/${VM_IP}/g" "$KUBECONFIG_PATH"
  log_ok "Kubeconfig: $KUBECONFIG_PATH"
}

# ─────────────────────────────────────────────────────────────────────────────
# FASE 3 — terraform apply (Helm provider gestiona todo el cluster)
# ─────────────────────────────────────────────────────────────────────────────
run_terraform() {
  if [[ "$SKIP_TF" == true ]]; then
    log "Saltando Terraform (--skip-terraform)"
    return
  fi

  command -v terraform &>/dev/null \
    || { log_err "terraform no encontrado. Instalar: https://developer.hashicorp.com/terraform/install"; exit 1; }

  local tfvars="$TF_ROOT/environments/${ENV}.tfvars"
  [[ -f "$tfvars" ]] || { log_err "tfvars no encontrado: $tfvars"; exit 1; }

  log "terraform init..."
  run terraform -chdir="$TF_ROOT" init -input=false -upgrade

  log "terraform validate..."
  run terraform -chdir="$TF_ROOT" validate

  log "terraform plan..."
  run terraform -chdir="$TF_ROOT" plan \
    -var-file="environments/${ENV}.tfvars" \
    -var-file="auto.tfvars" \
    -out=tfplan -input=false

  log "terraform apply..."
  run terraform -chdir="$TF_ROOT" apply -auto-approve tfplan

  log_ok "Terraform apply completado"
}

# ─────────────────────────────────────────────────────────────────────────────
# FASE 4a — Crear bases de datos por microservicio
# ─────────────────────────────────────────────────────────────────────────────
run_init_databases() {
  [[ "$SKIP_DB" == true ]] && { log "Saltando init-databases (--skip-databases)"; return; }

  local script="$SCRIPT_DIR/init-databases.sh"
  [[ -f "$script" ]] || { log "init-databases.sh no encontrado — omitiendo"; return; }

  local db_args=(--vm-ip "$VM_IP" --pg-prefix "$PG_PREFIX" --mongo-prefix "$MONGO_PREFIX"
                 --project "$PROJECT" --ssh-user "$SSH_USER" --ssh-key "$SSH_KEY")
  [[ -n "$SERVICES" ]]      && db_args+=(--services      "$SERVICES")
  [[ -n "$SERVICES_FILE" ]] && db_args+=(--services-file "$SERVICES_FILE")
  [[ -n "$SCHEMA_SQL" ]]    && db_args+=(--schema-sql    "$SCHEMA_SQL")
  [[ "$DRY_RUN" == true ]]  && db_args+=(--dry-run)

  run bash "$script" "${db_args[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# FASE 4b — Configurar organización y repos base en Gitea
# ─────────────────────────────────────────────────────────────────────────────
setup_gitea() {
  [[ "$SKIP_GITEA" == true ]] && { log "Saltando Gitea setup (--skip-gitea)"; return; }
  [[ "$DRY_RUN" == true ]]    && { log "[DRY-RUN] Crearía org $PROJECT + repos en Gitea"; return; }

  local gitea_url="http://${VM_IP}:3000"
  local gitea_user="gitea_admin"
  local gitea_pass
  gitea_pass=$(grep 'gitea_admin_password' "$TF_ROOT/environments/${ENV}.tfvars" 2>/dev/null \
    | awk -F'"' '{print $2}' | head -1 || echo "changeme_gitea_admin")

  log "Esperando Gitea en $gitea_url..."
  local tries=0
  until curl -sf "${gitea_url}/api/v1/version" &>/dev/null; do
    tries=$((tries+1)); [[ $tries -ge 36 ]] && { log "Gitea no responde — omitiendo"; return; }
    sleep 5
  done
  log_ok "Gitea disponible"

  _api() {
    curl -s -o /dev/null -w "%{http_code}" -X "$1" "${gitea_url}/api/v1${2}" \
      -H "Content-Type: application/json" -u "${gitea_user}:${gitea_pass}" -d "${3:-{}}"
  }

  local s
  s=$(_api POST "/orgs" "{\"username\":\"${PROJECT}\",\"visibility\":\"private\"}")
  [[ "$s" =~ ^(201|422)$ ]] && log_ok "Org: $PROJECT" || log "Org (HTTP $s — puede ya existir)"

  for repo in "${PROJECT}-migrations" "${PROJECT}-helm-charts" "${PROJECT}-jenkins-shared-library"; do
    s=$(_api POST "/orgs/${PROJECT}/repos" \
      "{\"name\":\"${repo}\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}")
    [[ "$s" =~ ^(201|409)$ ]] && log_ok "Repo: $repo" || log "Repo $repo (HTTP $s)"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# FASE 4c — Generar y publicar Jenkins Shared Library
# ─────────────────────────────────────────────────────────────────────────────
run_jenkins_lib() {
  [[ "$SKIP_JENKINS_LIB" == true ]] && { log "Saltando Jenkins shared library"; return; }

  local script="$SCRIPT_DIR/jenkins-shared-library-builder.sh"
  [[ -f "$script" ]] || { log "jenkins-shared-library-builder.sh no encontrado — omitiendo"; return; }

  local gitea_pass
  gitea_pass=$(grep 'gitea_admin_password' "$TF_ROOT/environments/${ENV}.tfvars" 2>/dev/null \
    | awk -F'"' '{print $2}' | head -1 || echo "changeme_gitea_admin")

  run bash "$script" \
    --vm-ip "$VM_IP" --project "$PROJECT" \
    --gitea-user "gitea_admin" --gitea-pass "$gitea_pass" \
    --ssh-user "$SSH_USER" --ssh-key "$SSH_KEY"
}

# ─────────────────────────────────────────────────────────────────────────────
# Resumen
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
  log ""
  log "══ Infraestructura lista ════════════════════════════════"
  log "  Proyecto:    $PROJECT  (env: $ENV)"
  log "  VPS IP:      $VM_IP"
  log "  Kubeconfig:  $KUBECONFIG_PATH"
  log "  Terraform:   $TF_ROOT"
  log ""
  log "  Gitea:       http://$VM_IP:3000"
  log "  Jenkins:     http://$VM_IP:8080"
  log "  ArgoCD:      http://$VM_IP:8081"
  log "  Keycloak:    http://$VM_IP:8082"
  log "  Vault:       http://$VM_IP:8200  (ver vault-init.json)"
  log "  Grafana:     http://$VM_IP:3001"
  log "  Prometheus:  http://$VM_IP:9090"
  [[ "$INSTALL_KONG" == true ]]     && log "  Kong Proxy:  http://$VM_IP:8000  (API gateway → servicios)"
  [[ "$INSTALL_MINIO" == true ]]    && log "  MinIO API:   http://$VM_IP:9000  (S3-compatible; bucket: $PROJECT-reports)"
  [[ "$INSTALL_MINIO" == true ]]    && log "  MinIO UI:    http://$VM_IP:9001  (minioadmin / changeme_minio)"
  [[ "$INSTALL_LRA" == true ]]      && log "  LRA:         http://$VM_IP:50000"
  [[ "$INSTALL_WIREMOCK" == true ]] && log "  WireMock:    http://$VM_IP:9999"
  log ""
  log "  Siguiente paso — migraciones:"
  log "    .claude/scripts/run-liquibase-migrations.sh \\"
  log "      --vm-ip $VM_IP --project $PROJECT \\"
  log "      --service <svc> --pg-prefix $PG_PREFIX --gitea-clone"
  log "════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────
[[ "$DRY_RUN" == true ]] && log "Modo DRY-RUN activo — no se ejecutará nada"

generate_terraform
install_k3s
run_terraform
run_init_databases
setup_gitea
run_jenkins_lib
print_summary
