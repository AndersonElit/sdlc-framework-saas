#!/usr/bin/env bash
# setup-cicd-pipeline.sh — Configura el pipeline CI/CD completo sobre la infraestructura Terraform
#
# Ejecutar DESPUÉS de base-infrastructure-builder.sh (Jenkins, ArgoCD, Gitea ya desplegados via Helm).
# Este script hace la CONFIGURACIÓN de aplicación que Terraform no puede hacer:
#
#   §0  Genera y publica la Jenkins Shared Library en Gitea
#   §1  Instala plugins en Jenkins + configura credenciales Gitea y Vault
#   §2  Crea jobs MultiBranch en Jenkins (uno por microservicio)
#   §3  Configura webhooks Gitea → Jenkins (push + PR)
#   §4  Sube credenciales de repo a ArgoCD para sincronizar helm-charts
#   §5  Genera .env.jenkins con variables de entorno del ambiente
#   §6  Verificación end-to-end
#
# Uso:
#   ./setup-cicd-pipeline.sh -P <proyecto> -S <svc1,svc2,...> --vm-ip <IP> [OPCIONES]
#
# Opciones:
#   -P, --project    NAME     Slug del proyecto                  (requerido)
#   -S, --services   LIST     Microservicios separados por coma  (requerido)
#   --vm-ip          IP       IP del VPS                         (requerido)
#   --env            ENV      local | prod                       (default: local)
#   --frontend               Incluir frontend en ArgoCD ApplicationSet
#   --ssh-user       USER     Usuario SSH VPS                    (default: ubuntu)
#   --ssh-key        FILE     Clave SSH privada                  (default: ~/.ssh/id_ed25519)
#   --kubeconfig     FILE     Kubeconfig K3s                     (auto)
#   --gitea-user     USER     Admin Gitea                        (default: gitea_admin)
#   --gitea-pass     PASS     Password Gitea                     (default: changeme_gitea_admin)
#   --jenkins-user   USER     Admin Jenkins                      (default: admin)
#   --jenkins-pass   PASS     Password Jenkins                   (default: changeme_jenkins_admin)
#   --skip-plugins            Omite instalación de plugins
#   --skip-jobs               Omite creación de jobs
#   --skip-webhooks           Omite configuración de webhooks
#
# Ejemplos:
#   ./setup-cicd-pipeline.sh -P myapp \
#     -S "clientes-service,pedidos-service,pagos-service,integration-service" \
#     --vm-ip 192.168.122.50

set -euo pipefail

log()    { echo "[$(date '+%H:%M:%S')] $*"; }
log_ok() { echo "[$(date '+%H:%M:%S')] OK  $*"; }
log_err(){ echo "[$(date '+%H:%M:%S')] ERR $*" >&2; }

PROJECT=""
SERVICES_CSV=""
VM_IP=""
ENV="local"
INCLUDE_FRONTEND=false
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"
KUBECONFIG_PATH=""
GITEA_USER="gitea_admin"
GITEA_PASS="changeme_gitea_admin"
JENKINS_USER="admin"
JENKINS_PASS="changeme_jenkins_admin"
SKIP_PLUGINS=false
SKIP_JOBS=false
SKIP_WEBHOOKS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -P|--project)    PROJECT="$2";       shift 2 ;;
    -S|--services)   SERVICES_CSV="$2";  shift 2 ;;
    --vm-ip)         VM_IP="$2";         shift 2 ;;
    --env)           ENV="$2";           shift 2 ;;
    --frontend)      INCLUDE_FRONTEND=true; shift ;;
    --ssh-user)      SSH_USER="$2";      shift 2 ;;
    --ssh-key)       SSH_KEY="$2";       shift 2 ;;
    --kubeconfig)    KUBECONFIG_PATH="$2"; shift 2 ;;
    --gitea-user)    GITEA_USER="$2";    shift 2 ;;
    --gitea-pass)    GITEA_PASS="$2";    shift 2 ;;
    --jenkins-user)  JENKINS_USER="$2";  shift 2 ;;
    --jenkins-pass)  JENKINS_PASS="$2";  shift 2 ;;
    --skip-plugins)  SKIP_PLUGINS=true;  shift   ;;
    --skip-jobs)     SKIP_JOBS=true;     shift   ;;
    --skip-webhooks) SKIP_WEBHOOKS=true; shift   ;;
    *) log_err "Opción desconocida: $1"; exit 1 ;;
  esac
done

[[ -z "$PROJECT" ]]     && { log_err "-P/--project es requerido"; exit 1; }
[[ -z "$SERVICES_CSV" ]] && { log_err "-S/--services es requerido"; exit 1; }
[[ -z "$VM_IP" ]]       && { log_err "--vm-ip es requerido"; exit 1; }

[[ -z "$KUBECONFIG_PATH" ]] && KUBECONFIG_PATH="$HOME/.kube/config-${PROJECT}-${ENV}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITEA_URL="http://${VM_IP}:3000"
JENKINS_URL="http://${VM_IP}:8080"
ARGOCD_URL="http://${VM_IP}:8081"
KUBECTL="kubectl --kubeconfig=$KUBECONFIG_PATH"

IFS=',' read -ra SERVICES <<< "$SERVICES_CSV"

log "setup-cicd-pipeline — proyecto=$PROJECT env=$ENV servicios=${#SERVICES[@]}"

# ─── §0: Jenkins Shared Library ──────────────────────────────────────────────
section_shared_library() {
  log "── §0 Jenkins Shared Library"
  local lib_script="$SCRIPT_DIR/jenkins-shared-library-builder.sh"
  [[ -f "$lib_script" ]] || { log_err "jenkins-shared-library-builder.sh no encontrado"; return 1; }

  bash "$lib_script" \
    --vm-ip     "$VM_IP" \
    --project   "$PROJECT" \
    --gitea-user "$GITEA_USER" \
    --gitea-pass "$GITEA_PASS" \
    --ssh-user  "$SSH_USER" \
    --ssh-key   "$SSH_KEY"

  log_ok "Shared Library publicada en ${GITEA_URL}/${PROJECT}/${PROJECT}-jenkins-shared-library"
}

# ─── §1: Plugins Jenkins + credenciales ──────────────────────────────────────
section_jenkins_plugins() {
  [[ "$SKIP_PLUGINS" == true ]] && { log "── §1 Plugins (omitido)"; return; }
  log "── §1 Plugins Jenkins + credenciales"

  # Esperar a Jenkins
  log "  Esperando Jenkins en $JENKINS_URL..."
  local tries=0
  until curl -sf "${JENKINS_URL}/login" -o /dev/null; do
    tries=$((tries+1)); [[ $tries -ge 40 ]] && { log_err "Jenkins no responde"; return 1; }
    sleep 5
  done
  log_ok "Jenkins disponible"

  # Obtener crumb
  local crumb
  crumb=$(curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)

  # Plugins necesarios para el stack
  local plugins=(
    "configuration-as-code:latest"
    "kubernetes:latest"
    "gitea:latest"
    "multibranch-scan-webhook-trigger:latest"
    "pipeline-stage-view:latest"
    "blueocean:latest"
    "sonar:latest"
    "credentials:latest"
    "credentials-binding:latest"
    "plain-credentials:latest"
    "ssh-credentials:latest"
    "git:latest"
    "workflow-aggregator:latest"
    "junit:latest"
    "jacoco:latest"
    "docker-workflow:latest"
    "kubernetes-credentials-provider:latest"
  )

  log "  Instalando ${#plugins[@]} plugins..."
  for plugin in "${plugins[@]}"; do
    curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "$crumb" \
      "${JENKINS_URL}/pluginManager/installNecessaryPlugins" \
      -d "<jenkins><install plugin=\"${plugin}\" /></jenkins>" \
      -H "Content-Type: text/xml" -o /dev/null 2>/dev/null || true
  done
  log_ok "Plugins enviados (Jenkins reiniciará automáticamente)"

  # Crear credencial para Gitea registry
  log "  Creando credencial Gitea registry..."
  curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_PASS}" \
    -H "$crumb" \
    "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
    -H "Content-Type: application/xml" \
    -d "<com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>
          <scope>GLOBAL</scope>
          <id>gitea-registry</id>
          <description>Gitea Package Registry — ${PROJECT}</description>
          <username>${GITEA_USER}</username>
          <password>${GITEA_PASS}</password>
        </com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl>" \
    -o /dev/null 2>/dev/null && log_ok "Credencial gitea-registry creada" || true

  # Credencial Vault token
  log "  Creando credencial Vault token..."
  local vault_token=""
  [[ -f "vault-init.json" ]] && vault_token=$(python3 -c "import json; print(json.load(open('vault-init.json'))['root_token'])" 2>/dev/null \
    || jq -r '.root_token' vault-init.json 2>/dev/null || true)

  if [[ -n "$vault_token" ]]; then
    curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "$crumb" \
      "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
      -H "Content-Type: application/xml" \
      -d "<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
            <scope>GLOBAL</scope>
            <id>vault-token</id>
            <description>HashiCorp Vault root token</description>
            <secret>${vault_token}</secret>
          </org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>" \
      -o /dev/null 2>/dev/null && log_ok "Credencial vault-token creada" || true
  fi

  # Credencial SSH para el VPS
  log "  Creando credencial SSH VPS..."
  if [[ -f "$SSH_KEY" ]]; then
    local ssh_priv_key
    ssh_priv_key=$(cat "$SSH_KEY")
    curl -sf -X POST -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "$crumb" \
      "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
      -H "Content-Type: application/xml" \
      -d "<com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>
            <scope>GLOBAL</scope>
            <id>vps-ssh-key</id>
            <description>VPS SSH key</description>
            <username>${SSH_USER}</username>
            <privateKeySource class=\"com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey\$DirectEntryPrivateKeySource\">
              <privateKey>${ssh_priv_key}</privateKey>
            </privateKeySource>
          </com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey>" \
      -o /dev/null 2>/dev/null && log_ok "Credencial vps-ssh-key creada" || true
  fi
}

# ─── §2: Jobs MultiBranch en Jenkins ─────────────────────────────────────────
section_jenkins_jobs() {
  [[ "$SKIP_JOBS" == true ]] && { log "── §2 Jobs (omitido)"; return; }
  log "── §2 Jobs MultiBranch Jenkins"

  # Esperar Jenkins (por si reinició por plugins)
  local tries=0
  until curl -sf "${JENKINS_URL}/login" -o /dev/null; do
    tries=$((tries+1)); [[ $tries -ge 40 ]] && { log_err "Jenkins no responde"; return 1; }
    sleep 5
  done

  local crumb
  crumb=$(curl -sf -u "${JENKINS_USER}:${JENKINS_PASS}" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)

  for svc in "${SERVICES[@]}"; do
    log "  Creando job: $svc"
    local repo_url="${GITEA_URL}/${PROJECT}/${svc}.git"

    local job_xml
    job_xml=$(cat <<XML
<org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
  <description>Pipeline para ${svc} — proyecto ${PROJECT}</description>
  <sources class="jenkins.branch.MultiBranchProject\$BranchSourceList">
    <data>
      <jenkins.branch.BranchSource>
        <source class="com.gitea.GiteaSCMSource">
          <serverUrl>${GITEA_URL}</serverUrl>
          <repoOwner>${PROJECT}</repoOwner>
          <repository>${svc}</repository>
          <credentialsId>gitea-registry</credentialsId>
        </source>
        <strategy class="jenkins.branch.DefaultBranchPropertyStrategy">
          <properties class="empty-list"/>
        </strategy>
      </jenkins.branch.BranchSource>
    </data>
  </sources>
  <factory class="org.jenkinsci.plugins.workflow.multibranch.WorkflowBranchProjectFactory">
    <owner class="org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject" reference="../.."/>
    <scriptPath>Jenkinsfile</scriptPath>
  </factory>
</org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject>
XML
)

    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST -u "${JENKINS_USER}:${JENKINS_PASS}" \
      -H "$crumb" \
      "${JENKINS_URL}/createItem?name=${svc}" \
      -H "Content-Type: application/xml" \
      -d "$job_xml" 2>/dev/null || echo "000")

    [[ "$status" =~ ^(200|201|302)$ ]] \
      && log_ok "Job $svc creado (HTTP $status)" \
      || log_err "Job $svc (HTTP $status — puede ya existir)"
  done
}

# ─── §3: Webhooks Gitea → Jenkins ─────────────────────────────────────────────
section_gitea_webhooks() {
  [[ "$SKIP_WEBHOOKS" == true ]] && { log "── §3 Webhooks (omitido)"; return; }
  log "── §3 Webhooks Gitea → Jenkins"

  local jenkins_hook_url="${JENKINS_URL}/multibranch-webhook-trigger/invoke?token=${PROJECT}"

  for svc in "${SERVICES[@]}"; do
    # Crear repo si no existe
    curl -sf -o /dev/null -w "%{http_code}" \
      -X POST "${GITEA_URL}/api/v1/orgs/${PROJECT}/repos" \
      -H "Content-Type: application/json" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -d "{\"name\":\"${svc}\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}" \
      | grep -qE "^(201|409)" || true

    # Webhook push
    local status
    status=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST "${GITEA_URL}/api/v1/repos/${PROJECT}/${svc}/hooks" \
      -H "Content-Type: application/json" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -d "{
        \"type\":\"gitea\",
        \"active\":true,
        \"events\":[\"push\",\"pull_request\"],
        \"config\":{
          \"url\":\"${jenkins_hook_url}&job=${svc}\",
          \"content_type\":\"json\"
        }
      }" 2>/dev/null || echo "000")

    [[ "$status" =~ ^(201|200)$ ]] \
      && log_ok "Webhook $svc → Jenkins" \
      || log_err "Webhook $svc (HTTP $status)"
  done
}

# ─── §4: ArgoCD repo credentials ──────────────────────────────────────────────
section_argocd_credentials() {
  log "── §4 ArgoCD — credenciales repo helm-charts"

  local helm_charts_repo="${GITEA_URL}/${PROJECT}/${PROJECT}-helm-charts.git"

  $KUBECTL apply -n cicd -f - <<YAML 2>/dev/null && log_ok "ArgoCD: repo-credentials creado" || true
apiVersion: v1
kind: Secret
metadata:
  name: ${PROJECT}-helm-charts-repo
  namespace: cicd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${helm_charts_repo}
  username: ${GITEA_USER}
  password: ${GITEA_PASS}
YAML
}

# ─── §5: Generar .env.jenkins ─────────────────────────────────────────────────
section_env_jenkins() {
  log "── §5 Generando .env.jenkins"

  cat > ".env.jenkins" <<ENV
# Auto-generado por setup-cicd-pipeline.sh — no commitear
PROJECT=${PROJECT}
ENV=${ENV}
VM_IP=${VM_IP}

# Gitea
GITEA_URL=${GITEA_URL}
GITEA_REGISTRY=${VM_IP}:3000/${PROJECT}
GITEA_USER=${GITEA_USER}

# K3s
K3S_API_SERVER=https://${VM_IP}:6443
KUBECONFIG=${KUBECONFIG_PATH}

# Kafka
KAFKA_BOOTSTRAP=kafka-kafka-bootstrap.messaging.svc.cluster.local:9092

# Keycloak
KEYCLOAK_URL=http://${VM_IP}:8082
KEYCLOAK_REALM=${PROJECT}

# Vault
VAULT_ADDR=http://${VM_IP}:8200
VAULT_BASE_PATH=secret/${PROJECT}/${ENV}

# Observabilidad
OTEL_ENDPOINT=http://tempo.observability.svc.cluster.local:4317
PROMETHEUS_URL=http://${VM_IP}:9090
GRAFANA_URL=http://${VM_IP}:3001

# LRA / WireMock
LRA_COORDINATOR_URL=http://${VM_IP}:50000
WIREMOCK_URL=http://${VM_IP}:9999
ENV

  log_ok ".env.jenkins generado"
}

# ─── §6: Verificación ─────────────────────────────────────────────────────────
section_verify() {
  log "── §6 Verificación"
  local ok=0; local fail=0

  # Shared library existe
  local lib_count
  lib_count=$(curl -sf -u "${GITEA_USER}:${GITEA_PASS}" \
    "${GITEA_URL}/api/v1/repos/${PROJECT}/${PROJECT}-jenkins-shared-library/contents/vars" \
    2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  [[ "$lib_count" -ge 3 ]] \
    && { log_ok "Shared library: $lib_count steps en vars/"; ok=$((ok+1)); } \
    || { log_err "Shared library: solo $lib_count steps"; fail=$((fail+1)); }

  # Jobs Jenkins
  for svc in "${SERVICES[@]}"; do
    local http
    http=$(curl -sf -o /dev/null -w "%{http_code}" \
      -u "${JENKINS_USER}:${JENKINS_PASS}" \
      "${JENKINS_URL}/job/${svc}/api/json" 2>/dev/null || echo "000")
    [[ "$http" == "200" ]] \
      && { ok=$((ok+1)); } \
      || { log_err "Job no encontrado: $svc"; fail=$((fail+1)); }
  done
  [[ "$ok" -gt 1 ]] && log_ok "Jobs Jenkins: $ok creados"

  # .env.jenkins
  [[ -f ".env.jenkins" ]] && log_ok ".env.jenkins presente" || log_err ".env.jenkins no generado"

  log ""
  log "  Verificación: OK=$ok  FAIL=$fail"
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  section_shared_library
  section_jenkins_plugins
  section_jenkins_jobs
  section_gitea_webhooks
  section_argocd_credentials
  section_env_jenkins
  section_verify

  log ""
  log_ok "CI/CD pipeline configurado"
  log "  Jenkins:    ${JENKINS_URL}  (${#SERVICES[@]} jobs)"
  log "  ArgoCD:     ${ARGOCD_URL}   (ApplicationSet activo cuando haya charts)"
  log "  Shared lib: ${GITEA_URL}/${PROJECT}/${PROJECT}-jenkins-shared-library"
  log "  Variables:  .env.jenkins"
}

main
