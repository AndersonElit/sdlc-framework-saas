#!/usr/bin/env bash
# jenkins-shared-library-builder.sh — Genera y publica la Jenkins Shared Library del proyecto
#
# Crea en Gitea el repo `<project>-jenkins-shared-library` con:
#   vars/         — pasos globales reutilizables (buildService, dockerBuild, helmDeploy, etc.)
#   src/          — clases Groovy de soporte
#   resources/    — archivos de configuración (Dockerfiles template, etc.)
#   Jenkinsfile   — pipeline de referencia para microservicios Spring Boot reactivo
#
# Uso: ./jenkins-shared-library-builder.sh [OPCIONES]
#
# Opciones:
#   --vm-ip      IP      IP del VPS                    (requerido)
#   --project    NAME    Nombre del proyecto           (requerido)
#   --gitea-user USER    Admin Gitea                   (default: gitea_admin)
#   --gitea-pass PASS    Password Gitea                (default: changeme_gitea_admin)
#   --ssh-user   USER    Usuario SSH VPS               (default: ubuntu)
#   --ssh-key    FILE    Clave SSH privada             (default: ~/.ssh/id_ed25519)
#
# Ejemplos:
#   ./jenkins-shared-library-builder.sh --vm-ip 192.168.122.50 --project myapp

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
GITEA_USER="gitea_admin"
GITEA_PASS="changeme_gitea_admin"
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip)      VM_IP="$2";      shift 2 ;;
    --project)    PROJECT="$2";    shift 2 ;;
    --gitea-user) GITEA_USER="$2"; shift 2 ;;
    --gitea-pass) GITEA_PASS="$2"; shift 2 ;;
    --ssh-user)   SSH_USER="$2";   shift 2 ;;
    --ssh-key)    SSH_KEY="$2";    shift 2 ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

[[ -z "$VM_IP" ]]   && die "--vm-ip es requerido"
[[ -z "$PROJECT" ]] && die "--project es requerido"

GITEA_URL="http://${VM_IP}:3000"
REPO_NAME="${PROJECT}-jenkins-shared-library"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ─── crear repo en Gitea ──────────────────────────────────────────────────────
create_repo() {
  header "Creando repo Gitea: $REPO_NAME"

  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_URL}/api/v1/orgs/${PROJECT}/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -d "{\"name\":\"${REPO_NAME}\",\"private\":true,\"auto_init\":true,\"default_branch\":\"main\"}")

  if [[ "$status" == "201" ]]; then
    ok "Repo creado: ${GITEA_URL}/${PROJECT}/${REPO_NAME}"
  elif [[ "$status" == "409" ]]; then
    warn "Repo ya existe — actualizando contenido"
  else
    die "Error creando repo (HTTP $status)"
  fi
}

# ─── generar estructura local ─────────────────────────────────────────────────
generate_library() {
  header "Generando Jenkins Shared Library"

  mkdir -p "$TMP_DIR"/{vars,src/org/sdlc,resources/templates}

  # ── vars/buildService.groovy ──────────────────────────────────────────────
  cat > "$TMP_DIR/vars/buildService.groovy" <<'EOF'
/**
 * buildService — compila, testea y construye JAR del microservicio (Gradle/Maven)
 *
 * Uso en Jenkinsfile:
 *   buildService(tool: 'gradle', javaVersion: '21')
 */
def call(Map cfg = [:]) {
  def tool        = cfg.tool        ?: 'gradle'
  def javaVersion = cfg.javaVersion ?: '21'

  container('build') {
    stage('Compilar') {
      if (tool == 'gradle') {
        sh './gradlew clean build -x test --no-daemon'
      } else {
        sh 'mvn -B clean package -DskipTests'
      }
    }
    stage('Test') {
      if (tool == 'gradle') {
        sh './gradlew test --no-daemon'
      } else {
        sh 'mvn -B test'
      }
      junit allowEmptyResults: true, testResults: '**/build/test-results/**/*.xml,**/target/surefire-reports/*.xml'
    }
  }
}
EOF

  # ── vars/dockerBuild.groovy ───────────────────────────────────────────────
  cat > "$TMP_DIR/vars/dockerBuild.groovy" <<'EOF'
/**
 * dockerBuild — construye imagen Docker y la publica en Gitea Package Registry (OCIR en prod)
 *
 * Uso:
 *   dockerBuild(registry: 'VPS_IP:3000/myorg', service: 'my-service', tag: '1.0.0')
 */
def call(Map cfg = [:]) {
  def registry = cfg.registry ?: error('registry es requerido')
  def service  = cfg.service  ?: error('service es requerido')
  def tag      = cfg.tag      ?: env.GIT_COMMIT?.take(7) ?: 'latest'
  def fullTag  = "${registry}/${service}:${tag}"

  container('docker') {
    stage('Docker Build') {
      sh "docker build -t ${fullTag} ."
    }
    stage('Docker Push') {
      withCredentials([usernamePassword(
        credentialsId: 'gitea-registry',
        usernameVariable: 'REG_USER',
        passwordVariable: 'REG_PASS'
      )]) {
        sh "docker login ${registry.split('/')[0]} -u \$REG_USER -p \$REG_PASS"
        sh "docker push ${fullTag}"
      }
    }
  }
  return fullTag
}
EOF

  # ── vars/helmDeploy.groovy ────────────────────────────────────────────────
  cat > "$TMP_DIR/vars/helmDeploy.groovy" <<'EOF'
/**
 * helmDeploy — actualiza el tag de imagen en el values.yaml del chart y hace push a Gitea
 *              ArgoCD detecta el cambio y sincroniza automáticamente.
 *
 * Uso:
 *   helmDeploy(
 *     chartsRepo: 'http://VPS_IP:3000/myorg/myapp-helm-charts',
 *     service: 'my-service',
 *     imageTag: '1.0.0-abc1234',
 *     env: 'prod'
 *   )
 */
def call(Map cfg = [:]) {
  def chartsRepo = cfg.chartsRepo ?: error('chartsRepo es requerido')
  def service    = cfg.service    ?: error('service es requerido')
  def imageTag   = cfg.imageTag   ?: error('imageTag es requerido')
  def environment = cfg.env      ?: 'dev'

  stage("Helm bumpImageTag → ${environment}") {
    withCredentials([usernamePassword(
      credentialsId: 'gitea-credentials',
      usernameVariable: 'GIT_USER',
      passwordVariable: 'GIT_PASS'
    )]) {
      sh """
        set -euo pipefail
        TMP=\$(mktemp -d)
        git clone ${chartsRepo} \$TMP
        VALUES="\$TMP/charts/${service}/values-${environment}.yaml"
        sed -i "s|tag:.*|tag: \\"${imageTag}\\"|" "\$VALUES"
        git -C "\$TMP" config user.email "jenkins@ci.local"
        git -C "\$TMP" config user.name  "Jenkins"
        git -C "\$TMP" add "\$VALUES"
        git -C "\$TMP" commit -m "ci(${service}): bump image tag to ${imageTag} [${environment}]"
        git -C "\$TMP" push
        rm -rf "\$TMP"
      """
    }
  }
}
EOF

  # ── vars/liquibaseMigrate.groovy ──────────────────────────────────────────
  cat > "$TMP_DIR/vars/liquibaseMigrate.groovy" <<'EOF'
/**
 * liquibaseMigrate — ejecuta run-liquibase-migrations.sh desde el agente Jenkins
 *
 * Uso:
 *   liquibaseMigrate(vmIp: '192.168.122.50', service: 'clientes-service', env: 'local')
 */
def call(Map cfg = [:]) {
  def vmIp    = cfg.vmIp    ?: error('vmIp es requerido')
  def service = cfg.service ?: error('service es requerido')
  def env     = cfg.env     ?: 'local'

  stage('Liquibase Migrations') {
    withCredentials([sshUserPrivateKey(
      credentialsId: 'vps-ssh-key',
      keyFileVariable: 'SSH_KEY'
    )]) {
      sh """
        .claude/scripts/run-liquibase-migrations.sh \
          --vm-ip ${vmIp} \
          --service ${service} \
          --env ${env} \
          --ssh-key \$SSH_KEY
      """
    }
  }
}
EOF

  # ── vars/vaultSecret.groovy ───────────────────────────────────────────────
  cat > "$TMP_DIR/vars/vaultSecret.groovy" <<'EOF'
/**
 * vaultSecret — lee un secreto de HashiCorp Vault y lo expone como env var
 *
 * Uso:
 *   vaultSecret(path: 'secret/myapp/db', key: 'password', envVar: 'DB_PASS') {
 *     sh 'echo $DB_PASS'
 *   }
 */
def call(Map cfg = [:], Closure body) {
  def path   = cfg.path   ?: error('path es requerido')
  def key    = cfg.key    ?: error('key es requerido')
  def envVar = cfg.envVar ?: key.toUpperCase()

  withCredentials([string(credentialsId: 'vault-token', variable: 'VAULT_TOKEN')]) {
    def value = sh(
      script: "vault kv get -field=${key} ${path}",
      returnStdout: true
    ).trim()
    withEnv(["${envVar}=${value}"]) {
      body()
    }
  }
}
EOF

  # ── Jenkinsfile de referencia ─────────────────────────────────────────────
  cat > "$TMP_DIR/resources/templates/Jenkinsfile.template" <<'JEOF'
// Jenkinsfile — Pipeline de referencia para microservicio Spring Boot reactivo
// Copiar a la raíz del repo del microservicio y ajustar las variables.
//
// Requiere Jenkins Shared Library configurada:
//   Manage Jenkins → Configure System → Global Pipeline Libraries
//   Name: sdlc-shared-lib  |  Default version: main
//   Retrieval: Modern SCM → Git → http://VPS_IP:3000/PROJECT/PROJECT-jenkins-shared-library

@Library('sdlc-shared-lib') _

def SERVICE_NAME  = 'my-service'          // nombre del microservicio
def REGISTRY      = 'VPS_IP:3000/PROJECT' // Gitea Package Registry (dev) / OCIR (prod)
def CHARTS_REPO   = 'http://VPS_IP:3000/PROJECT/PROJECT-helm-charts'
def VPS_IP        = 'VPS_IP'
def BUILD_TOOL    = 'gradle'              // gradle | maven

pipeline {
  agent {
    kubernetes {
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: build
      image: eclipse-temurin:21-jdk
      command: ["sleep", "infinity"]
    - name: docker
      image: docker:24-dind
      securityContext:
        privileged: true
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
'''
    }
  }

  environment {
    IMAGE_TAG = "${env.GIT_COMMIT?.take(7) ?: 'latest'}"
  }

  stages {
    stage('Build & Test') {
      steps {
        buildService(tool: BUILD_TOOL, javaVersion: '21')
      }
    }

    stage('Docker Build & Push') {
      steps {
        script {
          env.FULL_IMAGE_TAG = dockerBuild(
            registry: REGISTRY,
            service: SERVICE_NAME,
            tag: "${env.BUILD_NUMBER}-${env.IMAGE_TAG}"
          )
        }
      }
    }

    stage('Migrations') {
      when { branch 'main' }
      steps {
        liquibaseMigrate(vmIp: VPS_IP, service: SERVICE_NAME, env: 'local')
      }
    }

    stage('Deploy') {
      when { branch 'main' }
      steps {
        helmDeploy(
          chartsRepo: CHARTS_REPO,
          service: SERVICE_NAME,
          imageTag: env.FULL_IMAGE_TAG,
          env: 'local'
        )
      }
    }
  }

  post {
    always {
      cleanWs()
    }
    failure {
      echo "Pipeline falló — revisar logs"
    }
  }
}
JEOF

  ok "Shared library generada en $TMP_DIR"
}

# ─── publicar en Gitea via API ────────────────────────────────────────────────
push_to_gitea() {
  header "Publicando shared library en Gitea"

  local api_base="${GITEA_URL}/api/v1/repos/${PROJECT}/${REPO_NAME}/contents"

  push_file() {
    local remote_path="$1"
    local local_path="$2"
    local content
    content=$(base64 -w0 < "$local_path")

    # Obtener SHA del archivo si ya existe (para update)
    local sha
    sha=$(curl -s -u "${GITEA_USER}:${GITEA_PASS}" \
      "${api_base}/${remote_path}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || true)

    local payload
    if [[ -n "$sha" ]]; then
      payload="{\"message\":\"ci: update ${remote_path}\",\"content\":\"${content}\",\"sha\":\"${sha}\"}"
    else
      payload="{\"message\":\"ci: add ${remote_path}\",\"content\":\"${content}\"}"
    fi

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      -X PUT "${api_base}/${remote_path}" \
      -H "Content-Type: application/json" \
      -u "${GITEA_USER}:${GITEA_PASS}" \
      -d "$payload")

    if [[ "$status" =~ ^(200|201)$ ]]; then
      ok "Subido: $remote_path"
    else
      warn "Error subiendo $remote_path (HTTP $status)"
    fi
  }

  push_file "vars/buildService.groovy"                      "$TMP_DIR/vars/buildService.groovy"
  push_file "vars/dockerBuild.groovy"                       "$TMP_DIR/vars/dockerBuild.groovy"
  push_file "vars/helmDeploy.groovy"                        "$TMP_DIR/vars/helmDeploy.groovy"
  push_file "vars/liquibaseMigrate.groovy"                  "$TMP_DIR/vars/liquibaseMigrate.groovy"
  push_file "vars/vaultSecret.groovy"                       "$TMP_DIR/vars/vaultSecret.groovy"
  push_file "resources/templates/Jenkinsfile.template"      "$TMP_DIR/resources/templates/Jenkinsfile.template"
}

# ─── main ─────────────────────────────────────────────────────────────────────
main() {
  header "jenkins-shared-library-builder — proyecto=$PROJECT"

  create_repo
  generate_library
  push_to_gitea

  header "Shared Library lista"
  echo ""
  echo -e "  ${BOLD}Repo:${RESET}  ${GITEA_URL}/${PROJECT}/${REPO_NAME}"
  echo ""
  echo -e "  ${BOLD}Configurar en Jenkins:${RESET}"
  echo -e "    Manage Jenkins → Configure System → Global Pipeline Libraries"
  echo -e "    Name:              sdlc-shared-lib"
  echo -e "    Default version:   main"
  echo -e "    Retrieval:         Modern SCM → Git"
  echo -e "    URL:               ${GITEA_URL}/${PROJECT}/${REPO_NAME}"
  echo ""
  echo -e "  ${BOLD}Jenkinsfile de referencia:${RESET}"
  echo -e "    resources/templates/Jenkinsfile.template"
  echo ""
}

main
