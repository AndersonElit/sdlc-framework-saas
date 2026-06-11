#!/usr/bin/env python3
"""Genera un proyecto base Scala (sbt) multimódulo con arquitectura hexagonal y batch Spark.

Modo genérico (sin --report-role): arquetipo batch vacío (placeholders + BatchMain vacío).
Modo reportería (--report-role extraction|processing): genera el subsistema ETL Spark
descrito en PLAN-reporteria-spark-etl.md (§7.1.1), con adaptadores Mongo (read model CQRS) /
JDBC / S3-parquet / Kafka y el patrón Factory de transformadores (DR-10).
"""

import argparse
import logging
import re
import sys
from pathlib import Path

logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------- #
# build.sbt
# --------------------------------------------------------------------------- #
def build_files(root: Path, svc: str, pkg: str,
                report_role: str | None = None,
                source: str = "mongo") -> None:
    write(root, "project/build.properties", "sbt.version=1.9.8\n")

    write(root, "project/plugins.sbt",
          'addSbtPlugin("com.eed3si9n" % "sbt-assembly" % "2.1.4")\n')

    reporting = report_role is not None
    extraction_mongo = report_role == "extraction" and source == "mongo"
    processing = report_role == "processing"

    # vals de dependencias extra del modo reportería
    extra_vals = ""
    if reporting:
        extra_vals += (
            'val kafka = Seq("org.apache.kafka" % "kafka-clients" % "3.7.0")\n'
        )
    if extraction_mongo:
        extra_vals += (
            'val mongo = Seq("org.mongodb.spark" %% "mongo-spark-connector" % "10.3.0")\n'
        )

    # listas de dependencias por módulo
    driven_libs = "catsEffect ++ spark ++ hadoop"
    if reporting:
        driven_libs += " ++ kafka"
    if extraction_mongo:
        driven_libs += " ++ mongo"

    entry_extra = " ++ logging"
    if processing:
        entry_extra += " ++ kafka"

    write(root, "build.sbt",
          'ThisBuild / organization := "com.example"\n'
          'ThisBuild / version      := "0.1.0-SNAPSHOT"\n'
          'ThisBuild / scalaVersion := "2.13.14"\n'
          "\n"
          'ThisBuild / scalacOptions += "-Xsource:3"\n'
          "\n"
          'val catsEffectVersion = "3.5.3"\n'
          'val logbackVersion    = "1.4.14"\n'
          'val sparkVersion      = "3.5.1"\n'
          "\n"
          'val catsEffect = Seq("org.typelevel" %% "cats-effect" % catsEffectVersion)\n'
          'val logging    = Seq("ch.qos.logback" % "logback-classic" % logbackVersion)\n'
          "val spark = Seq(\n"
          '  "org.apache.spark" %% "spark-core" % sparkVersion % "provided",\n'
          '  "org.apache.spark" %% "spark-sql"  % sparkVersion % "provided"\n'
          ")\n"
          "val hadoop = Seq(\n"
          '  "org.apache.hadoop"  % "hadoop-aws"         % "3.3.4",\n'
          '  "com.amazonaws"      % "aws-java-sdk-bundle" % "1.12.262"\n'
          ")\n"
          f"{extra_vals}"
          "\n"
          "lazy val domain = project\n"
          '  .in(file("domain/model"))\n'
          '  .settings(name := "domain", libraryDependencies ++= catsEffect ++ spark)\n'
          "\n"
          "lazy val useCases = project\n"
          '  .in(file("application/use-cases"))\n'
          '  .settings(name := "use-cases", libraryDependencies ++= catsEffect ++ spark)\n'
          "  .dependsOn(domain)\n"
          "\n"
          "lazy val drivenAdapters = project\n"
          '  .in(file("infrastructure/driven-adapters"))\n'
          "  .settings(\n"
          '    name := "driven-adapters",\n'
          f"    libraryDependencies ++= {driven_libs}\n"
          "  )\n"
          "  .dependsOn(domain)\n"
          "\n"
          "lazy val entryPoints = project\n"
          '  .in(file("infrastructure/entry-points"))\n'
          "  .settings(\n"
          '    name := "entry-points",\n'
          "    libraryDependencies ++= Seq(\n"
          '      "org.apache.spark" %% "spark-core" % sparkVersion,\n'
          '      "org.apache.spark" %% "spark-sql"  % sparkVersion\n'
          f"    ){entry_extra},\n"
          "    Compile / run / fork := true,\n"
          "    Compile / run / baseDirectory := (ThisBuild / baseDirectory).value,\n"
          "    Compile / run / javaOptions ++= Seq(\n"
          '      "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.nio=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.io=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.net=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.nio.cs=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.security.action=ALL-UNNAMED",\n'
          '      "--add-opens=java.base/sun.util.calendar=ALL-UNNAMED",\n'
          '      "--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED"\n'
          "    ),\n"
          f'    Compile / run / mainClass := Some("com.example.{pkg}.infrastructure.entrypoints.BatchMain"),\n'
          f'    assembly / mainClass := Some("com.example.{pkg}.infrastructure.entrypoints.BatchMain"),\n'
          "    assembly / assemblyMergeStrategy := {\n"
          '      case PathList("META-INF", _ @ _*) => MergeStrategy.discard\n'
          "      case _                            => MergeStrategy.first\n"
          "    }\n"
          "  )\n"
          "  .dependsOn(useCases, drivenAdapters)\n"
          "\n"
          "lazy val root = project\n"
          '  .in(file("."))\n'
          "  .aggregate(domain, useCases, drivenAdapters, entryPoints)\n"
          '  .settings(name := "scala-hexagonal-architecture", publish / skip := true)\n')


# --------------------------------------------------------------------------- #
# .env
# --------------------------------------------------------------------------- #
def dotenv_files(root: Path, report_role: str | None = None,
                 source: str = "mongo", pg_db_prefix: str = "", org: str = "myproject") -> None:
    # BD del read model CQRS (PostgreSQL): <prefix>_readmodel si hay prefijo.
    readmodel_db = f"{pg_db_prefix}_readmodel" if pg_db_prefix else "readmodel_db"

    if report_role is None:
        content = (
            "STORAGE_ENDPOINT=\n"
            "STORAGE_ACCESS_KEY=\n"
            "STORAGE_SECRET_KEY=\n"
        )
    else:
        content = (
            "# --- Almacenamiento de objetos S3-compatible ---\n"
            "# Dev:  MinIO en K3s  (http://minio.infra.svc.cluster.local:9000)\n"
            "# Prod: OCI Object Storage (https://namespace.compat.objectstorage.region.oraclecloud.com)\n"
            "STORAGE_ENDPOINT=${STORAGE_ENDPOINT:-http://minio.infra.svc.cluster.local:9000}\n"
            "STORAGE_ACCESS_KEY=${STORAGE_ACCESS_KEY:-minioadmin}\n"
            "STORAGE_SECRET_KEY=${STORAGE_SECRET_KEY:-changeme_minio}\n"
            f"REPORT_BUCKET=${{REPORT_BUCKET:-{org}-reports}}\n"
            "# --- Kafka (K3s via Strimzi) ---\n"
            "KAFKA_BOOTSTRAP_SERVERS=kafka-kafka-bootstrap.messaging.svc.cluster.local:9092\n"
        )
        if report_role == "extraction" and source == "mongo":
            content += (
                "# --- Read model CQRS (MongoDB en K3s) ---\n"
                "MONGO_URI=mongodb://mongodb.data.svc.cluster.local:27017\n"
                "MONGO_READ_DB=readmodel\n"
                "MONGO_READ_COLLECTION=ventas\n"
            )
        elif report_role == "extraction" and source == "jdbc":
            content += (
                "# --- Read model CQRS PostgreSQL (<prefix>_readmodel — NO usar BD operacional) ---\n"
                f"JDBC_URL=jdbc:postgresql://postgresql.data.svc.cluster.local:5432/{readmodel_db}\n"
                "JDBC_TABLE=ventas\n"
                "JDBC_USER=app\n"
                "JDBC_PASSWORD=app\n"
            )
    write(root, ".env", content)
    write(root, ".env.example", content)


# --------------------------------------------------------------------------- #
# Dockerfile
# --------------------------------------------------------------------------- #
def dockerfile_files(root: Path, svc: str) -> None:
    jar = "infrastructure/entry-points/target/scala-2.13/entry-points-assembly-*.jar"

    write(root, "Dockerfile",
          "# Stage 1 — cachear dependencias SBT (capa separada → rebuilds más rápidos)\n"
          "FROM sbtscala/scala-sbt:eclipse-temurin-17.0.10_7_1.9.8_2.13.14 AS builder\n"
          "WORKDIR /app\n"
          "COPY build.sbt .\n"
          "COPY project/ project/\n"
          "RUN sbt update\n"
          "\n"
          "# Copiar fuentes y ensamblar fat JAR\n"
          "COPY . .\n"
          'RUN sbt "entryPoints/assembly"\n'
          "\n"
          "# Stage 2 — runtime (JRE only; Spark runs embedded in local[*] mode)\n"
          "FROM eclipse-temurin:17-jre-jammy\n"
          "WORKDIR /app\n"
          f"COPY --from=builder /app/{jar} app.jar\n"
          "\n"
          'ENV SPARK_MASTER="local[*]"\n'
          "\n"
          'ENTRYPOINT ["java",\\\n'
          '  "--add-opens=java.base/sun.nio.ch=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.nio=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.lang=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.io=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.net=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.util=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/sun.nio.cs=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/sun.security.action=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.base/sun.util.calendar=ALL-UNNAMED",\\\n'
          '  "--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED",\\\n'
          '  "-jar","app.jar"]\n')

    write(root, ".dockerignore",
          "target/\n"
          ".git/\n"
          ".env\n"
          "*.class\n"
          ".bsp/\n"
          ".metals/\n"
          ".idea/\n")


# --------------------------------------------------------------------------- #
# Jenkinsfile
# --------------------------------------------------------------------------- #
def get_jenkinsfile_content(svc: str, org: str = "myproject") -> str:
    lib_org = "".join(c for c in org.lower() if c.isascii() and c.isalnum()) or "myproject"
    template = """\
@Library('jenkins-shared-library@main') _

// ───────────────────────────────────────────────────────────────────────────
// Jenkinsfile — Spark batch job '__SVC__'
// Pipeline CI puro; el CD lo gestiona ArgoCD (CronJob en K8s).
// Sin smoke tests HTTP: los batch jobs no exponen endpoints.
// Modelo de agentes: Kubernetes plugin (pod efímero con contenedor SBT).
// El deploy NO ocurre aquí: bumpImageTag escribe el nuevo tag en Git
// y ArgoCD auto-sincroniza el CronJob en dev/staging (manual en prod).
// ───────────────────────────────────────────────────────────────────────────

pipeline {
    agent {
        kubernetes {
            defaultContainer 'sbt'
            yaml libraryResource('org/__LIB_ORG__/podScalaBatch.yaml')
        }
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '30'))
    }

    parameters {
        string(
            name: 'SERVICE_NAME',
            defaultValue: '__SVC__',
            description: 'Nombre del batch job (deriva el repo en Gitea Package Registry y el CronJob K8s).'
        )
        choice(
            name: 'DEPLOY_ENV',
            choices: ['dev', 'staging', 'prod'],
            description: 'Ambiente destino del despliegue.'
        )
    }

    environment {
        SERVICE_NAME  = "${params.SERVICE_NAME}"
        DEPLOY_ENV    = "${params.DEPLOY_ENV}"
        IMAGE_REPO    = "${params.SERVICE_NAME}"
        K8S_NAMESPACE = "${params.DEPLOY_ENV}"
    }

    stages {
        // 1 — Checkout + IMAGE_TAG inmutable (<version>-<sha>).
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = computeImageTag()
                    echo "IMAGE_TAG=${env.IMAGE_TAG}"
                }
            }
        }

        // 2 — Compilar, tests unitarios y fat JAR (sbt compile test assembly).
        stage('Build & Test') {
            steps { buildScalaBatchJob() }
        }

        // 3 — Análisis estático + quality gate (SonarQube). Falla si gate = ERROR.
        //     projectType: 'sbt' usa "sbt sonarScan" en lugar de mvn sonar:sonar.
        stage('Quality Gate (SonarQube)') {
            steps { runQualityGates(projectType: 'sbt') }
        }

        // 4 — OWASP Dependency Check (sbt-dependency-check) + gitleaks.
        stage('Security Scans') {
            steps { runSecurityScans(projectType: 'sbt') }
        }

        // 5 — Imagen Docker multi-stage vía Kaniko → push a Gitea Package Registry.
        stage('Build & Push Image') {
            steps {
                buildAndPushImage(
                    service:   env.SERVICE_NAME,
                    imageRepo: env.IMAGE_REPO,
                    imageTag:  env.IMAGE_TAG
                )
            }
        }

        // 6 — Escaneo Trivy de la imagen publicada. Falla ante CVE crítico.
        stage('Image Scan (Trivy)') {
            steps { scanImage(imageRepo: env.IMAGE_REPO, imageTag: env.IMAGE_TAG) }
        }

        // 7 — Frontera CI → CD: escribe image.repository/tag en
        //     helm/__SVC__/values-<env>.yaml y commitea (GitOps).
        //     ArgoCD detecta el commit y actualiza el CronJob en el cluster.
        stage('Update GitOps (image tag)') {
            steps {
                bumpImageTag(
                    service:  env.SERVICE_NAME,
                    env:      env.DEPLOY_ENV,
                    imageTag: env.IMAGE_TAG
                )
            }
        }
    }

    post {
        success { notify(status: 'SUCCESS', service: env.SERVICE_NAME, env: env.DEPLOY_ENV) }
        failure { notify(status: 'FAILURE', service: env.SERVICE_NAME, env: env.DEPLOY_ENV) }
    }
}
"""
    return template.replace("__SVC__", svc).replace("__LIB_ORG__", lib_org)


# --------------------------------------------------------------------------- #
# Helm chart (CronJob)
# --------------------------------------------------------------------------- #
def get_helm_chart_files(svc: str, schedule: str = "0 * * * *") -> dict:
    chart_yaml = f"""\
apiVersion: v2
name: {svc}
description: Helm chart del Spark batch job {svc} (Kubernetes CronJob)
type: application
version: 0.1.0
appVersion: "0.1.0"
"""

    values_yaml = f"""\
# Valores base. image.repository/tag se fijan por ambiente en values-<env>.yaml (GitOps).

# Expresión cron que controla cuándo Kubernetes lanza el Job.
# Formato: "minuto hora día-mes mes día-semana"  →  "0 * * * *" = cada hora en punto.
schedule: "{schedule}"

image:
  repository: ""   # <registry>/<service> — definido en values-<env>.yaml
  tag: ""          # <version>-<sha> inmutable — definido en values-<env>.yaml
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: "2"
    memory: 4Gi

# Never: el pod no se reinicia si falla (el Job reintenta según backoffLimit).
restartPolicy: Never
# Forbid: no lanza un nuevo Job si el anterior todavía está corriendo.
concurrencyPolicy: Forbid
successfulJobsHistoryLimit: 3
failedJobsHistoryLimit: 1

env: []
"""

    image_block = """\
# image.repository / image.tag los fija el pipeline (bumpImageTag); ArgoCD los lee.
image:
  repository: ""
  tag: ""
"""

    values_dev = image_block + """\
resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    cpu: "1"
    memory: 2Gi
"""

    values_staging = image_block + """\
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: "2"
    memory: 4Gi
"""

    values_prod = image_block + """\
resources:
  requests:
    cpu: "1"
    memory: 4Gi
  limits:
    cpu: "4"
    memory: 8Gi
"""

    cronjob_tpl = """\
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
spec:
  schedule: {{ .Values.schedule | quote }}
  concurrencyPolicy: {{ .Values.concurrencyPolicy }}
  successfulJobsHistoryLimit: {{ .Values.successfulJobsHistoryLimit }}
  failedJobsHistoryLimit: {{ .Values.failedJobsHistoryLimit }}
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: {{ .Chart.Name }}
        spec:
          restartPolicy: {{ .Values.restartPolicy }}
          containers:
            - name: {{ .Chart.Name }}
              image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
              imagePullPolicy: {{ .Values.image.pullPolicy }}
              resources:
                {{- toYaml .Values.resources | nindent 16 }}
              {{- with .Values.env }}
              env:
                {{- toYaml . | nindent 16 }}
              {{- end }}
"""

    return {
        "Chart.yaml": chart_yaml,
        "values.yaml": values_yaml,
        "values-dev.yaml": values_dev,
        "values-staging.yaml": values_staging,
        "values-prod.yaml": values_prod,
        ".helmignore": ".git\n*.tmp\n*.bak\n",
        "templates/cronjob.yaml": cronjob_tpl,
    }


# --------------------------------------------------------------------------- #
# scripts/create-secrets-dev.sh
# --------------------------------------------------------------------------- #
def get_secrets_script_content(svc: str, report_role: str | None,
                                source: str, org: str = "myproject",
                                pg_db_prefix: str = "") -> str:
    # BD PostgreSQL del read model CQRS: <prefix>_readmodel
    readmodel_db = f"{pg_db_prefix}_readmodel" if pg_db_prefix else "readmodel_db"
    svc_slug = svc.replace("-", "_")

    if report_role is None:
        kvpairs = [
            "STORAGE_ENDPOINT=http://minio.infra.svc.cluster.local:9000",
            "STORAGE_ACCESS_KEY=minioadmin",
            "STORAGE_SECRET_KEY=changeme_minio",
        ]
    else:
        kvpairs = [
            "STORAGE_ENDPOINT=http://minio.infra.svc.cluster.local:9000",
            "STORAGE_ACCESS_KEY=minioadmin",
            "STORAGE_SECRET_KEY=changeme_minio",
            f"REPORT_BUCKET={org}-reports",
            "KAFKA_BOOTSTRAP_SERVERS=kafka-kafka-bootstrap.messaging.svc.cluster.local:9092",
        ]
        if report_role == "extraction" and source == "mongo":
            kvpairs += [
                "MONGO_URI=mongodb://mongodb.data.svc.cluster.local:27017",
                "MONGO_READ_DB=readmodel",
                "MONGO_READ_COLLECTION=ventas",
            ]
        elif report_role == "extraction" and source == "jdbc":
            kvpairs += [
                f"JDBC_URL=jdbc:postgresql://postgresql.data.svc.cluster.local:5432/{readmodel_db}",
                "JDBC_TABLE=ventas",
                f"JDBC_USER={readmodel_db}_user",
                f"JDBC_PASSWORD=changeme_{svc_slug}",
            ]

    kvpairs_str = " ".join(f'"{kv}"' for kv in kvpairs)

    return f"""\
#!/usr/bin/env bash
# Crea/actualiza el secret de desarrollo en HashiCorp Vault (K3s).
# Uso: KUBECONFIG=~/.kube/config-{org}-local bash scripts/create-secrets-dev.sh
# Requiere que Vault esté unsealed y vault-init.json esté disponible.

set -euo pipefail
KUBECONFIG="${{KUBECONFIG:-$HOME/.kube/config-{org}-local}}"
SECRET_PATH="{org}/dev/{svc}"
INIT_FILE="${{VAULT_INIT_FILE:-./vault-init.json}}"

if [[ -f "$INIT_FILE" ]]; then
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['root_token'])" 2>/dev/null \\
        || jq -r '.root_token' "$INIT_FILE" 2>/dev/null)
fi
VAULT_TOKEN="${{VAULT_TOKEN:-${{VAULT_ROOT_TOKEN:-}}}}"
[[ -z "$VAULT_TOKEN" ]] && {{ echo "ERROR: VAULT_TOKEN no disponible"; exit 1; }}

kubectl --kubeconfig="$KUBECONFIG" exec -n secrets vault-0 -- \\
    sh -c "VAULT_TOKEN=${{VAULT_TOKEN}} vault kv put secret/${{SECRET_PATH}} {kvpairs_str}"

echo "Secret creado/actualizado: secret/${{SECRET_PATH}}"
"""


# --------------------------------------------------------------------------- #
# Gitea, ArgoCD, Terraform
# --------------------------------------------------------------------------- #
def _setup_gitea_repo(svc: str, root: Path, org: str = "myproject") -> None:
    import base64
    import json as _json
    import subprocess
    import urllib.error
    import urllib.request

    import os
    vps_ip = os.environ.get("VPS_IP", "")
    gitea_host = f"http://{vps_ip}:3000" if vps_ip else "http://localhost:3000"
    gitea_user = os.environ.get("GITEA_USER", "gitea_admin")
    gitea_pass = os.environ.get("GITEA_PASS", "changeme_gitea_admin")
    credentials = base64.b64encode(f"{gitea_user}:{gitea_pass}".encode()).decode()

    try:
        urllib.request.urlopen(f"{gitea_host}/api/healthz", timeout=3)
    except Exception:
        logger.warning(
            "[Gitea] No activo en %s — exportar VPS_IP=<IP> o crear repo manualmente "
            "tras correr base-infrastructure-builder.sh.", gitea_host
        )
        return

    payload = _json.dumps({
        "name": svc, "private": True,
        "auto_init": False, "default_branch": "main",
    }).encode()
    req = urllib.request.Request(
        f"{gitea_host}/api/v1/orgs/{org}/repos",
        data=payload,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Basic {credentials}"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
        logger.info("[Gitea] Repo %s/%s creado.", org, svc)
    except urllib.error.HTTPError as e:
        if e.code == 409:
            logger.info("[Gitea] Repo %s/%s ya existe.", org, svc)
        elif e.code == 401:
            logger.warning("[Gitea] HTTP 401: correr base-infrastructure-builder.sh primero.")
            return
        else:
            logger.warning("[Gitea] No se pudo crear el repo: HTTP %s", e.code)
            return

    try:
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, check=True)
        result = subprocess.run(["git", "config", "user.email"], cwd=root, capture_output=True)
        if result.returncode != 0:
            subprocess.run(["git", "config", "user.email", f"cicd@{org}.local"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", f"{org} CI"], cwd=root, check=True)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-q", "-m", f"chore: scaffold {svc}"], cwd=root, check=True)
        remote_url = f"{gitea_host}/{org}/{svc}.git"
        subprocess.run(["git", "remote", "add", "origin", remote_url], cwd=root, check=False)
        logger.info("[Gitea] Remote 'origin' → %s", remote_url)
        push_url = remote_url.replace("http://", f"http://{gitea_user}:{gitea_pass}@", 1)
        push = subprocess.run(["git", "push", push_url, "main"], cwd=root, capture_output=True)
        if push.returncode == 0:
            logger.info("[Gitea] Push a %s/%s completado (rama main).", org, svc)
        else:
            logger.info("[Gitea] Para publicar: cd %s && git push -u origin main", root)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        logger.warning("[Gitea] No se pudo inicializar el repo git: %s", e)


def _update_argocd_applicationset(svc: str, org: str = "myproject") -> None:
    """Sube el Helm chart del batch job al repo <org>-helm-charts en Gitea.

    El ApplicationSet de ArgoCD usa un Git generator que auto-descubre servicios
    desde charts/ en el repo helm-charts. No se necesita actualizar YAML estáticos.
    """
    import base64 as _b64
    import json as _json
    import urllib.error
    import urllib.request
    import os as _os

    _vps_ip = _os.environ.get("VPS_IP", "localhost")
    gitea_host = f"http://{_vps_ip}:3000"
    gitea_user = _os.environ.get("GITEA_USER", "gitea_admin")
    gitea_pass = _os.environ.get("GITEA_PASS", "changeme_gitea_admin")
    credentials = _b64.b64encode(f"{gitea_user}:{gitea_pass}".encode()).decode()
    helm_charts_repo = f"{org}-helm-charts"

    try:
        urllib.request.urlopen(f"{gitea_host}/api/healthz", timeout=3)
    except Exception:
        logger.warning("[Gitea] No activo — subir manualmente chart a %s/charts/%s/", helm_charts_repo, svc)
        return

    for env in ("local", "dev", "prod"):
        content = f"# values-{env}.yaml para {svc}\nimage:\n  repository: \"\"\n  tag: \"\"\n"
        encoded = _b64.b64encode(content.encode()).decode()
        sha = ""
        file_path = f"charts/{svc}/values-{env}.yaml"
        try:
            req = urllib.request.Request(
                f"{gitea_host}/api/v1/repos/{org}/{helm_charts_repo}/contents/{file_path}",
                headers={"Authorization": f"Basic {credentials}"},
            )
            with urllib.request.urlopen(req, timeout=5) as r:
                sha = _json.loads(r.read())["sha"]
        except urllib.error.HTTPError:
            pass
        payload: dict = {"message": f"ci: scaffold {svc} helm chart ({env})", "content": encoded}
        if sha:
            payload["sha"] = sha
        req = urllib.request.Request(
            f"{gitea_host}/api/v1/repos/{org}/{helm_charts_repo}/contents/{file_path}",
            data=_json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": f"Basic {credentials}"},
            method="PUT",
        )
        try:
            urllib.request.urlopen(req, timeout=10)
            logger.debug("[Gitea helm-charts] %s subido.", file_path)
        except urllib.error.HTTPError as e:
            logger.warning("[Gitea helm-charts] No se pudo subir %s: HTTP %s", file_path, e.code)

    logger.info("[ArgoCD] Helm chart '%s' subido a %s/charts/%s/ — ApplicationSet lo sincronizará.", svc, helm_charts_repo, svc)


def _update_terraform_services(svc: str) -> None:
    """No-op: Terraform se genera en tiempo de ejecución por base-infrastructure-builder.sh.
    Ejecutar init-databases.sh para crear la BD del servicio.
    """
    logger.info(
        "[Terraform] Omitido — la infra se genera en runtime. "
        "Ejecutar: .claude/scripts/init-databases.sh --service %s para crear la BD.",
        svc
    )


# --------------------------------------------------------------------------- #
# Generadores genéricos (modo sin --report-role) — comportamiento original
# --------------------------------------------------------------------------- #
def domain_model(root: Path, pkg: str) -> None:
    base = f"domain/model/src/main/scala/com/example/{pkg}/domain"
    write(root, f"{base}/model/.gitkeep", "")
    write(root, f"{base}/ports/.gitkeep", "")


def application_use_cases(root: Path, pkg: str) -> None:
    write(root, f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases/.gitkeep", "")


def driven_adapters(root: Path, pkg: str) -> None:
    base = f"infrastructure/driven-adapters/src/main/scala/com/example/{pkg}/infrastructure/driven"
    write(root, f"{base}/inmemory/.gitkeep", "")
    write(root, f"{base}/eventbus/.gitkeep", "")


def entry_points(root: Path, svc: str, pkg: str) -> None:
    base = f"infrastructure/entry-points/src/main/scala/com/example/{pkg}/infrastructure/entrypoints"
    full_pkg = f"com.example.{pkg}.infrastructure.entrypoints"

    write(root, f"{base}/BatchMain.scala",
          f"package {full_pkg}\n"
          "\n"
          "import org.apache.spark.sql.SparkSession\n"
          "\n"
          "object BatchMain {\n"
          "\n"
          "  def main(args: Array[String]): Unit = {\n"
          "    val argMap: Map[String, String] =\n"
          "      args.grouped(2)\n"
          '        .collect { case Array(k, v) if k.startsWith("--") => k.stripPrefix("--") -> v }\n'
          "        .toMap\n"
          "\n"
          "    val spark = SparkSession.builder\n"
          f'      .appName("{svc}")\n'
          '      .master(sys.env.getOrElse("SPARK_MASTER", "local[*]"))\n'
          "      .getOrCreate()\n"
          "\n"
          "    try {\n"
          "      run(spark, argMap)\n"
          "    } finally {\n"
          "      spark.stop()\n"
          "    }\n"
          "  }\n"
          "\n"
          "  private def run(spark: SparkSession, args: Map[String, String]): Unit = {\n"
          "    // TODO: implement batch logic\n"
          "  }\n"
          "}\n")


# --------------------------------------------------------------------------- #
# Helpers de generación de código Scala (modo reportería)
# --------------------------------------------------------------------------- #
def _r(content: str, pkg: str, **kw: str) -> str:
    """Sustituye sentinelas __PKG__/__X__ por valores reales (evita choques con `{`/`$` de Scala)."""
    out = content.replace("__PKG__", pkg)
    for k, v in kw.items():
        out = out.replace(f"__{k}__", v)
    return out


def _transformer_class(report_type: str) -> str:
    parts = [p for p in re.split(r"[-_\s]+", report_type) if p]
    return "".join(p.capitalize() for p in parts) + "Transformer"


def _scala_base(pkg: str, layer: str) -> str:
    mapping = {
        "domain.model": f"domain/model/src/main/scala/com/example/{pkg}/domain/model",
        "domain.ports": f"domain/model/src/main/scala/com/example/{pkg}/domain/ports",
        "usecases": f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases",
        "transformers": f"application/use-cases/src/main/scala/com/example/{pkg}/application/usecases/transformers",
        "driven": f"infrastructure/driven-adapters/src/main/scala/com/example/{pkg}/infrastructure/driven",
        "entry": f"infrastructure/entry-points/src/main/scala/com/example/{pkg}/infrastructure/entrypoints",
    }
    return mapping[layer]


# --------------------------------------------------------------------------- #
# Dominio (ambos roles)
# --------------------------------------------------------------------------- #
def report_domain_model(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "domain.model")
    ports = _scala_base(pkg, "domain.ports")

    write(root, f"{base}/ReportType.scala", _r('''package com.example.__PKG__.domain.model

/** Tipo de reporte (lenguaje ubicuo del bounded context de Reportería). */
final case class ReportType(value: String)

object ReportType {
  def fromString(s: String): ReportType = ReportType(s.trim.toLowerCase)
}
''', pkg))

    write(root, f"{base}/ColumnSpec.scala", _r('''package com.example.__PKG__.domain.model

/** Especificación declarativa de una columna del esquema de un reporte (DR-1). */
final case class ColumnSpec(name: String, dataType: String, nullable: Boolean)
''', pkg))

    write(root, f"{base}/IntegrityRule.scala", _r('''package com.example.__PKG__.domain.model

/** Regla de integridad declarativa. `rule` admite p.ej. "NOT_NULL", "UNIQUE", "RANGE:0:100". */
final case class IntegrityRule(column: String, rule: String)
''', pkg))

    write(root, f"{base}/ReportSchema.scala", _r('''package com.example.__PKG__.domain.model

/** Esquema declarado de un reporte: contrato y fuente de verdad de la validación (DR-1). */
final case class ReportSchema(
    reportType: ReportType,
    version: String,
    columns: List[ColumnSpec],
    integrityRules: List[IntegrityRule]
) {
  def columnNames: Set[String] = columns.map(_.name).toSet
  def notNullColumns: List[String] = columns.filterNot(_.nullable).map(_.name)
}
''', pkg))

    write(root, f"{base}/ReportEvents.scala", _r('''package com.example.__PKG__.domain.model

/** Eventos de dominio del subsistema de reportería (§6). La serialización vive en infraestructura. */
sealed trait ReportEvent { def reportId: String }

final case class ReportExtracted(
    reportId: String,
    runId: String,
    reportType: String,
    schemaVersion: String,
    rawParquetUri: String,
    rowCount: Long,
    validatedAt: String
) extends ReportEvent

/** Un evento por formato: report-etl-service publica N mensajes (uno por formato pedido).
 *  El Kafka Consumer lee el campo `format` y genera exactamente ese archivo. */
final case class ReportProcessed(
    reportId: String,
    runId: String,
    reportType: String,
    processedParquetUri: String,
    format: String,
    processedAt: String
) extends ReportEvent

final case class ReportFailed(
    reportId: String,
    stage: String,
    reason: String,
    failedColumns: List[String]
) extends ReportEvent
''', pkg))

    # Puertos
    write(root, f"{ports}/EventBusPort.scala", _r('''package com.example.__PKG__.domain.ports

/** Puerto de publicación de eventos. Mantiene el dominio libre de Kafka. */
trait EventBusPort {
  def publish(topic: String, key: String, payload: String): Unit
}
''', pkg))

    write(root, f"{ports}/SourceDataPort.scala", _r('''package com.example.__PKG__.domain.ports

import org.apache.spark.sql.DataFrame

/** Puerto de lectura de la fuente de datos (read model CQRS o JDBC).
 *  `DataFrame` aparece solo como detalle de la transformación tabular en la frontera (DR-10);
 *  los clientes Mongo/JDBC/Spark concretos viven exclusivamente en infraestructura. */
trait SourceDataPort {
  def read(): DataFrame
}
''', pkg))

    write(root, f"{ports}/ParquetStorePort.scala", _r('''package com.example.__PKG__.domain.ports

import org.apache.spark.sql.DataFrame

/** Puerto de lectura/escritura de parquet en almacenamiento de objetos (S3). */
trait ParquetStorePort {
  def writeRaw(reportType: String, reportId: String, df: DataFrame): String
  def readRaw(uri: String): DataFrame
  def writeProcessed(reportType: String, reportId: String, df: DataFrame): String
}
''', pkg))


# --------------------------------------------------------------------------- #
# Use case de extracción (MS1)
# --------------------------------------------------------------------------- #
def validate_extract_use_case(root: Path, pkg: str, out_topic: str) -> None:
    base = _scala_base(pkg, "usecases")
    write(root, f"{base}/ValidateAndExtractUseCase.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model._
import com.example.__PKG__.domain.ports._
import org.apache.spark.sql.functions.col

/** MS1: valida el DataFrame de origen contra el `ReportSchema` declarado (DR-1),
 *  materializa parquet crudo en `raw/` y publica `report.extracted`.
 *  Si la validación falla ⇒ publica `report.extraction.failed` y falla rápido. */
class ValidateAndExtractUseCase(
    source: SourceDataPort,
    store: ParquetStorePort,
    events: EventBusPort,
    outTopic: String = "__OUT_TOPIC__"
) {

  def execute(schema: ReportSchema, reportId: String, runId: String): Unit = {
    val df = source.read()
    val actual = df.columns.toSet

    val missing = schema.columnNames.diff(actual)
    if (missing.nonEmpty) {
      fail(reportId, "extraction", "missing columns", missing.toList)
      throw new IllegalStateException(s"Schema validation failed: missing columns $missing")
    }

    val nullViolations = schema.notNullColumns.filter { c =>
      actual.contains(c) && df.filter(col(c).isNull).limit(1).count() > 0
    }
    if (nullViolations.nonEmpty) {
      fail(reportId, "extraction", "null values in non-nullable columns", nullViolations)
      throw new IllegalStateException(s"Integrity validation failed: nulls in $nullViolations")
    }

    val uri = store.writeRaw(schema.reportType.value, reportId, df)
    val rowCount = df.count()
    val payload =
      s"""{"reportId":"$reportId","runId":"$runId","reportType":"${schema.reportType.value}",""" +
      s""""schemaVersion":"${schema.version}","rawParquetUri":"$uri","rowCount":$rowCount,""" +
      s""""validatedAt":"${java.time.Instant.now()}"}"""
    events.publish(outTopic, reportId, payload)
  }

  private def fail(reportId: String, stage: String, reason: String, cols: List[String]): Unit = {
    val arr = cols.map(c => "\\"" + c + "\\"").mkString(",")
    val payload =
      s"""{"reportId":"$reportId","stage":"$stage","reason":"$reason","failedColumns":[$arr]}"""
    events.publish("report.extraction.failed", reportId, payload)
  }
}
''', pkg, OUT_TOPIC=out_topic))


# --------------------------------------------------------------------------- #
# Factory de transformadores (MS2, DR-10)
# --------------------------------------------------------------------------- #
def report_transformer_factory(root: Path, pkg: str, types: list[str],
                               out_topic: str) -> None:
    base = _scala_base(pkg, "usecases")
    tbase = _scala_base(pkg, "transformers")

    write(root, f"{base}/ReportTransformer.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType
import org.apache.spark.sql.DataFrame

/** Contrato común de transformación por tipo de reporte (DR-10). `DataFrame` es el detalle
 *  de la transformación Spark; cada tipo implementa su agregación/pivot/formato lógico. */
trait ReportTransformer {
  def reportType: ReportType
  def transform(raw: DataFrame): DataFrame
}

/** Se lanza cuando MS2 recibe un `reportType` no registrado en la factory. */
class UnsupportedReportTypeException(rt: ReportType)
    extends RuntimeException(s"Unsupported report type: ${rt.value}")
''', pkg))

    write(root, f"{base}/ReportTransformerFactory.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType

/** Resuelve el `ReportTransformer` concreto por `ReportType` (patrón Factory, DR-10).
 *  Añadir un tipo nuevo = añadir una clase + registrarla en `BatchMain`; sin tocar el use case. */
class ReportTransformerFactory(registry: Map[ReportType, ReportTransformer]) {
  def resolve(rt: ReportType): ReportTransformer =
    registry.getOrElse(rt, throw new UnsupportedReportTypeException(rt))
}
''', pkg))

    write(root, f"{base}/ProcessReportUseCase.scala", _r('''package com.example.__PKG__.application.usecases

import com.example.__PKG__.domain.model.ReportType
import com.example.__PKG__.domain.ports._

/** MS2: resuelve el transformer por `reportType` vía factory, transforma el parquet `raw/`,
 *  materializa `processed/` y publica UN evento por formato en `report.processed`.
 *  El campo `format` (singular) permite que el Kafka Consumer genere exactamente ese archivo. */
class ProcessReportUseCase(
    factory: ReportTransformerFactory,
    store: ParquetStorePort,
    events: EventBusPort,
    outTopic: String = "__OUT_TOPIC__"
) {

  def execute(
      reportType: ReportType,
      reportId: String,
      runId: String,
      rawUri: String,
      formats: List[String]
  ): Unit = {
    try {
      val transformer = factory.resolve(reportType)
      val raw = store.readRaw(rawUri)
      val processed = transformer.transform(raw)
      val uri = store.writeProcessed(reportType.value, reportId, processed)
      val ts  = java.time.Instant.now().toString
      // Un evento por formato: el Kafka Consumer lee el campo `format` y genera ese archivo.
      formats.foreach { fmt =>
        val payload =
          s"""{"reportId":"$reportId","runId":"$runId","reportType":"${reportType.value}",""" +
          s""""processedParquetUri":"$uri","format":"$fmt",""" +
          s""""processedAt":"$ts"}"""
        events.publish(outTopic, s"$reportId-$fmt", payload)
      }
    } catch {
      case e: UnsupportedReportTypeException =>
        val payload =
          s"""{"reportId":"$reportId","stage":"processing","reason":"${e.getMessage}","failedColumns":[]}"""
        events.publish("report.processing.failed", reportId, payload)
        throw e
    }
  }
}
''', pkg, OUT_TOPIC=out_topic))

    for t in types:
        cls = _transformer_class(t)
        write(root, f"{tbase}/{cls}.scala", _r('''package com.example.__PKG__.application.usecases.transformers

import com.example.__PKG__.application.usecases.ReportTransformer
import com.example.__PKG__.domain.model.ReportType
import org.apache.spark.sql.DataFrame

/** Transformer del reporte `__TYPE__` (DR-10). */
class __CLASS__ extends ReportTransformer {
  override val reportType: ReportType = ReportType("__TYPE__")

  override def transform(raw: DataFrame): DataFrame = {
    // TODO: implementar la agregación/pivot/formato lógico de `__TYPE__`.
    // Una fila del resultado debe aproximarse a una celda lógica del formato final (DR-2).
    raw
  }
}
''', pkg, TYPE=t, CLASS=cls))


# --------------------------------------------------------------------------- #
# Driven adapters
# --------------------------------------------------------------------------- #
def mongo_source_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/mongosource/SparkMongoSourceAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.mongosource

import com.example.__PKG__.domain.ports.SourceDataPort
import org.apache.spark.sql.{DataFrame, SparkSession}

/** Lee la colección del read model CQRS (MongoDB) vía mongo-spark-connector (§0, DS-CQRS-3).
 *  Nunca apunta a la BD de escritura (PostgreSQL). */
class SparkMongoSourceAdapter(
    spark: SparkSession,
    uri: String,
    database: String,
    collection: String
) extends SourceDataPort {

  override def read(): DataFrame =
    spark.read
      .format("mongodb")
      .option("connection.uri", uri)
      .option("database", database)
      .option("collection", collection)
      .load()
}
''', pkg))


def jdbc_source_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/jdbcsource/SparkJdbcSourceAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.jdbcsource

import com.example.__PKG__.domain.ports.SourceDataPort
import org.apache.spark.sql.{DataFrame, SparkSession}

/** Lee el read model PostgreSQL CQRS (`<prefix>_readmodel`) — DS-CQRS-3.
 *  NUNCA apunta a las BDs operacionales de los microservicios de dominio.
 *  Variable JDBC_URL debe apuntar a `<prefix>_readmodel` (Database-per-Service del projection-service). */
class SparkJdbcSourceAdapter(
    spark: SparkSession,
    url: String,
    table: String,
    user: String,
    password: String
) extends SourceDataPort {

  override def read(): DataFrame =
    spark.read
      .format("jdbc")
      .option("url", url)
      .option("dbtable", table)
      .option("user", user)
      .option("password", password)
      .load()
}
''', pkg))


def s3_parquet_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/s3parquet/SparkS3ParquetAdapter.scala", _r('''package com.example.__PKG__.infrastructure.driven.s3parquet

import com.example.__PKG__.domain.ports.ParquetStorePort
import org.apache.spark.sql.{DataFrame, SaveMode, SparkSession}

/** Lee/escribe parquet en almacenamiento de objetos S3-compatible.
 *  Dev: MinIO en K3s (endpoint via STORAGE_ENDPOINT).
 *  Prod: OCI Object Storage (compatible S3A via endpoint override) o AWS S3.
 *  Idempotente por `reportId` con sobrescritura determinista (DR-3). */
class SparkS3ParquetAdapter(spark: SparkSession, bucket: String) extends ParquetStorePort {

  override def writeRaw(reportType: String, reportId: String, df: DataFrame): String = {
    val uri = s"s3a://$bucket/raw/$reportType/$reportId/"
    df.write.mode(SaveMode.Overwrite).parquet(uri)
    uri
  }

  override def readRaw(uri: String): DataFrame =
    spark.read.parquet(uri)

  override def writeProcessed(reportType: String, reportId: String, df: DataFrame): String = {
    val uri = s"s3a://$bucket/processed/$reportType/$reportId/"
    df.write.mode(SaveMode.Overwrite).parquet(uri)
    uri
  }
}
''', pkg))


def kafka_producer_adapter(root: Path, pkg: str) -> None:
    base = _scala_base(pkg, "driven")
    write(root, f"{base}/kafkaproducer/KafkaEventPublisher.scala", _r('''package com.example.__PKG__.infrastructure.driven.kafkaproducer

import com.example.__PKG__.domain.ports.EventBusPort
import org.apache.kafka.clients.producer.{KafkaProducer, ProducerRecord}

import java.util.Properties

/** Publica eventos de dominio (payload JSON) en Kafka. Implementa `EventBusPort`. */
class KafkaEventPublisher(bootstrapServers: String) extends EventBusPort with AutoCloseable {

  private val props = new Properties()
  props.put("bootstrap.servers", bootstrapServers)
  props.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer")
  props.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer")
  props.put("acks", "all")

  private val producer = new KafkaProducer[String, String](props)

  override def publish(topic: String, key: String, payload: String): Unit = {
    producer.send(new ProducerRecord[String, String](topic, key, payload)).get()
  }

  override def close(): Unit = producer.close()
}
''', pkg))


# --------------------------------------------------------------------------- #
# Entry point: kafka consumer (MS2)
# --------------------------------------------------------------------------- #
def kafka_consumer_entry_point(root: Path, pkg: str, topic_in: str) -> None:
    base = _scala_base(pkg, "entry")
    write(root, f"{base}/kafkaconsumer/ReportExtractedConsumer.scala", _r('''package com.example.__PKG__.infrastructure.entrypoints.kafkaconsumer

import com.example.__PKG__.application.usecases.ProcessReportUseCase
import com.example.__PKG__.domain.model.ReportType
import org.apache.kafka.clients.consumer.KafkaConsumer

import java.time.Duration
import java.util.{Collections, Properties, UUID}
import scala.jdk.CollectionConverters._

/** Entry-point dirigido por evento: consume `__TOPIC_IN__` (report.extracted) y dispara MS2. */
class ReportExtractedConsumer(
    bootstrapServers: String,
    topicIn: String = "__TOPIC_IN__",
    groupId: String = "report-processing-service",
    useCase: ProcessReportUseCase
) {

  @volatile private var running = true

  private def buildConsumer(): KafkaConsumer[String, String] = {
    val props = new Properties()
    props.put("bootstrap.servers", bootstrapServers)
    props.put("group.id", groupId)
    props.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer")
    props.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer")
    props.put("auto.offset.reset", "earliest")
    props.put("enable.auto.commit", "true")
    new KafkaConsumer[String, String](props)
  }

  def stop(): Unit = running = false

  def start(): Unit = {
    val consumer = buildConsumer()
    consumer.subscribe(Collections.singletonList(topicIn))
    try {
      while (running) {
        val records = consumer.poll(Duration.ofMillis(1000))
        for (record <- records.asScala) {
          handle(record.value())
        }
      }
    } finally {
      consumer.close()
    }
  }

  private def handle(json: String): Unit = {
    val reportType = field(json, "reportType").getOrElse("")
    val reportId   = field(json, "reportId").getOrElse(UUID.randomUUID().toString)
    val runId      = field(json, "runId").getOrElse(UUID.randomUUID().toString)
    val rawUri     = field(json, "rawParquetUri").getOrElse("")
    // Formatos a generar: un evento por formato → "format" singular en cada mensaje Kafka.
    val formats = List("XLS", "CSV")  // ajustar si el catálogo define otros formatos
    useCase.execute(ReportType.fromString(reportType), reportId, runId, rawUri, formats)
  }

  // Extracción mínima de campos JSON (sustituible por una librería en endurecimiento).
  private def field(json: String, key: String): Option[String] = {
    val pattern = ("\\"" + key + "\\"\\\\s*:\\\\s*\\"([^\\"]*)\\"").r
    pattern.findFirstMatchIn(json).map(_.group(1))
  }
}
''', pkg, TOPIC_IN=topic_in))


# --------------------------------------------------------------------------- #
# BatchMain por rol
# --------------------------------------------------------------------------- #
def report_batch_main(root: Path, svc: str, pkg: str, report_role: str,
                      source: str, out_topic: str, in_topic: str,
                      types: list[str]) -> None:
    base = _scala_base(pkg, "entry")

    spark_builder = _r('''  private def buildSpark(): SparkSession = {
    val builder = SparkSession.builder
      .appName("__SVC__")
      .master(sys.env.getOrElse("SPARK_MASTER", "local[*]"))
    // Almacenamiento de objetos S3-compatible: MinIO en dev (K3s), OCI Object Storage en prod.
    // STORAGE_ENDPOINT vacío → usa AWS S3 real (o provider nativo si OCI SDK configurado).
    val endpoint = sys.env.getOrElse("STORAGE_ENDPOINT", "")
    val spark = builder.getOrCreate()
    val hc = spark.sparkContext.hadoopConfiguration
    if (endpoint.nonEmpty) hc.set("fs.s3a.endpoint", endpoint)
    hc.set("fs.s3a.path.style.access", "true")
    hc.set("fs.s3a.access.key", sys.env.getOrElse("STORAGE_ACCESS_KEY", "minioadmin"))
    hc.set("fs.s3a.secret.key", sys.env.getOrElse("STORAGE_SECRET_KEY", "changeme_minio"))
    hc.set("fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
    spark
  }
''', pkg, SVC=svc)

    if report_role == "extraction":
        if source == "mongo":
            source_wiring = _r('''      val source = new SparkMongoSourceAdapter(
        spark,
        sys.env.getOrElse("MONGO_URI", "mongodb://localhost:27017"),
        sys.env.getOrElse("MONGO_READ_DB", "readmodel"),
        sys.env.getOrElse("MONGO_READ_COLLECTION", "ventas")
      )
''', pkg)
            source_import = f"import com.example.{pkg}.infrastructure.driven.mongosource.SparkMongoSourceAdapter"
        else:
            source_wiring = _r('''      val source = new SparkJdbcSourceAdapter(
        spark,
        sys.env.getOrElse("JDBC_URL", "jdbc:postgresql://localhost:5432/app"),
        sys.env.getOrElse("JDBC_TABLE", "ventas"),
        sys.env.getOrElse("JDBC_USER", "app"),
        sys.env.getOrElse("JDBC_PASSWORD", "app")
      )
''', pkg)
            source_import = f"import com.example.{pkg}.infrastructure.driven.jdbcsource.SparkJdbcSourceAdapter"

        body = _r('''package com.example.__PKG__.infrastructure.entrypoints

import com.example.__PKG__.application.usecases.ValidateAndExtractUseCase
import com.example.__PKG__.domain.model.{ColumnSpec, ReportSchema, ReportType}
import com.example.__PKG__.infrastructure.driven.kafkaproducer.KafkaEventPublisher
import com.example.__PKG__.infrastructure.driven.s3parquet.SparkS3ParquetAdapter
__SOURCE_IMPORT__
import org.apache.spark.sql.SparkSession

import java.util.UUID

/** MS1 — extracción + validación de esquema. Lee el read model CQRS → valida → parquet `raw/`
 *  → publica `report.extracted` (§3, DR-1). */
object BatchMain {

  def main(args: Array[String]): Unit = {
    val argMap: Map[String, String] =
      args.grouped(2)
        .collect { case Array(k, v) if k.startsWith("--") => k.stripPrefix("--") -> v }
        .toMap

    val spark = buildSpark()
    try {
      val bucket    = sys.env.getOrElse("REPORT_BUCKET", "reports")
      val bootstrap = sys.env.getOrElse("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")

__SOURCE_WIRING__
      val store  = new SparkS3ParquetAdapter(spark, bucket)
      val events = new KafkaEventPublisher(bootstrap)
      val useCase = new ValidateAndExtractUseCase(source, store, events, "__OUT_TOPIC__")

      val reportType = ReportType.fromString(argMap.getOrElse("reportType", "ventas-mensual"))
      val reportId   = argMap.getOrElse("reportId", UUID.randomUUID().toString)
      val runId      = UUID.randomUUID().toString

      // TODO: resolver el ReportSchema vigente desde report_schema_catalog (§9.2).
      val schema = ReportSchema(
        reportType,
        version = "v1",
        columns = List(
          ColumnSpec("id", "string", nullable = false)
          // TODO: declarar las columnas reales del reporte.
        ),
        integrityRules = List.empty
      )

      try {
        useCase.execute(schema, reportId, runId)
      } finally {
        events.close()
      }
    } finally {
      spark.stop()
    }
  }

__SPARK_BUILDER__}
''', pkg, SOURCE_IMPORT=source_import, SOURCE_WIRING=source_wiring,
              OUT_TOPIC=out_topic, SPARK_BUILDER=spark_builder)

    else:  # processing
        imports = "\n".join(
            f"import com.example.{pkg}.application.usecases.transformers.{_transformer_class(t)}"
            for t in types
        )
        if types:
            registry_lines = "\n".join(
                f"      val t{i} = new {_transformer_class(t)}()" for i, t in enumerate(types)
            )
            registry_map = ", ".join(f"t{i}.reportType -> t{i}" for i in range(len(types)))
        else:
            registry_lines = "      // TODO: registrar transformers (--report-types vacío)."
            registry_map = ""

        body = _r('''package com.example.__PKG__.infrastructure.entrypoints

import com.example.__PKG__.application.usecases.{ProcessReportUseCase, ReportTransformer, ReportTransformerFactory}
import com.example.__PKG__.domain.model.ReportType
import com.example.__PKG__.infrastructure.driven.kafkaproducer.KafkaEventPublisher
import com.example.__PKG__.infrastructure.driven.s3parquet.SparkS3ParquetAdapter
import com.example.__PKG__.infrastructure.entrypoints.kafkaconsumer.ReportExtractedConsumer
__IMPORTS__
import org.apache.spark.sql.SparkSession

/** MS2 — transformación por tipo de reporte (modo triggered-by-event).
 *  Cablea la ReportTransformerFactory con los tipos registrados (DR-10) y arranca el consumer. */
object BatchMain {

  def main(args: Array[String]): Unit = {
    val spark = buildSpark()
    val bucket    = sys.env.getOrElse("REPORT_BUCKET", "reports")
    val bootstrap = sys.env.getOrElse("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
    val topicIn   = sys.env.getOrElse("KAFKA_TOPIC_IN", "__TOPIC_IN__")

    val store  = new SparkS3ParquetAdapter(spark, bucket)
    val events = new KafkaEventPublisher(bootstrap)

__REGISTRY_LINES__
    val registry: Map[ReportType, ReportTransformer] = Map(__REGISTRY_MAP__)
    val factory = new ReportTransformerFactory(registry)
    val useCase = new ProcessReportUseCase(factory, store, events, "__OUT_TOPIC__")

    val consumer = new ReportExtractedConsumer(bootstrap, topicIn, "report-processing-service", useCase)
    sys.addShutdownHook {
      consumer.stop()
      events.close()
      spark.stop()
    }
    consumer.start()
  }

__SPARK_BUILDER__}
''', pkg, IMPORTS=imports, REGISTRY_LINES=registry_lines, REGISTRY_MAP=registry_map,
              TOPIC_IN=in_topic, OUT_TOPIC=out_topic, SPARK_BUILDER=spark_builder)

    write(root, f"{base}/BatchMain.scala", body)


# --------------------------------------------------------------------------- #
# Orquestación del modo reportería
# --------------------------------------------------------------------------- #
def scaffold_reporting(root: Path, svc: str, pkg: str, report_role: str,
                       source: str, in_topic: str, out_topic: str,
                       types: list[str]) -> None:
    report_domain_model(root, pkg)
    s3_parquet_adapter(root, pkg)
    kafka_producer_adapter(root, pkg)

    if report_role == "extraction":
        validate_extract_use_case(root, pkg, out_topic)
        if source == "mongo":
            mongo_source_adapter(root, pkg)
        else:
            jdbc_source_adapter(root, pkg)
    else:  # processing
        report_transformer_factory(root, pkg, types, out_topic)
        kafka_consumer_entry_point(root, pkg, in_topic)

    report_batch_main(root, svc, pkg, report_role, source, out_topic, in_topic, types)


# --------------------------------------------------------------------------- #
# write helper
# --------------------------------------------------------------------------- #
def write(root: Path, relative: str, content: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    logger.info("  created %s", relative)


# --------------------------------------------------------------------------- #
# scaffold
# --------------------------------------------------------------------------- #
def scaffold(service_name: str, root_arg: str | None, service_name_provided: bool,
             report_role: str | None = None, source: str = "mongo",
             kafka_in: str = "report.extracted", kafka_out: str | None = None,
             report_types: str = "",
             schedule: str = "0 * * * *",
             org: str = "myproject",
             pg_db_prefix: str = "") -> None:
    root = Path(root_arg) if root_arg else Path(".")
    if service_name_provided:
        root = root / service_name

    logger.info("Scaffolding Scala hexagonal architecture at: %s", root.resolve())
    logger.info("Service name: %s", service_name)

    pkg = service_name.replace("-", "")

    # default de kafka_out por rol
    if kafka_out is None:
        kafka_out = "report.processed" if report_role == "processing" else "report.extracted"

    types = [t.strip() for t in report_types.split(",") if t.strip()]

    build_files(root, service_name, pkg, report_role, source)
    dotenv_files(root, report_role, source, pg_db_prefix, org)
    dockerfile_files(root, service_name)

    if report_role is None:
        # Comportamiento original (retrocompatible): placeholders + BatchMain vacío.
        domain_model(root, pkg)
        application_use_cases(root, pkg)
        driven_adapters(root, pkg)
        entry_points(root, service_name, pkg)
    else:
        logger.info("Report role: %s | source: %s | types: %s", report_role, source, types)
        scaffold_reporting(root, service_name, pkg, report_role, source,
                           kafka_in, kafka_out, types)

    # Helm chart (CronJob)
    helm_root = root / "helm" / service_name
    for rel_path, content in get_helm_chart_files(service_name, schedule).items():
        target = helm_root / rel_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    logger.info("Helm chart (CronJob) creado en %s", helm_root)

    # scripts/create-secrets-dev.sh
    scripts_dir = root / "scripts"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    secrets_script = scripts_dir / "create-secrets-dev.sh"
    secrets_script.write_text(get_secrets_script_content(service_name, report_role, source, org,
                                                          pg_db_prefix=pg_db_prefix))
    secrets_script.chmod(0o755)
    logger.info("scripts/create-secrets-dev.sh creado")

    # Jenkinsfile
    write(root, "Jenkinsfile", get_jenkinsfile_content(service_name, org))

    # Registro en infraestructura (Terraform ECR, ArgoCD ApplicationSet, Gitea)
    _update_terraform_services(service_name)
    _update_argocd_applicationset(service_name, org)
    _setup_gitea_repo(service_name, root, org)

    abs_root = root.resolve()
    print(f"""
╔══════════════════════════════════════════════════════════════════════╗
║          Proyecto listo: {service_name:<44}║
╚══════════════════════════════════════════════════════════════════════╝

 ── Ejecución local (sbt) ──────────────────────────────────────────────

 1. Entra al directorio:
      cd {abs_root}

 2. Crea el secret en Vault (K3s local):
      export VAULT_TOKEN=$(jq -r '.root_token' ./vault-init.json)
      bash scripts/create-secrets-dev.sh""")

    if report_role is None:
        print("""
 3. Ejecuta el batch job:
      sbt "entryPoints/run"
""")
    else:
        if report_role == "extraction" and source == "mongo":
            print("    (requiere K3s corriendo con MongoDB y Kafka via Strimzi)")
        elif report_role == "extraction":
            print("    (requiere K3s corriendo con PostgreSQL read model y Kafka via Strimzi)")
        else:
            print("    (requiere K3s corriendo con Kafka via Strimzi)")
        if report_role == "extraction":
            print(f'\n 3. Ejecutar extracción:\n      sbt "entryPoints/run --reportType ventas-mensual"')
            print(f"    → valida esquema, escribe raw/ y publica '{kafka_out}'")
        else:
            print(f'\n 3. Ejecutar procesamiento:\n      sbt "entryPoints/run"')
            print(f"    → consume '{kafka_in}', transforma y publica '{kafka_out}'")

    print(f"""
 4. Override Spark master (cluster externo):
      SPARK_MASTER=spark://host:7077 sbt "entryPoints/run"

 5. Fat JAR:
      sbt "entryPoints/assembly"
      java -jar infrastructure/entry-points/target/scala-2.13/entry-points-assembly-0.1.0-SNAPSHOT.jar

 ── Docker ─────────────────────────────────────────────────────────────

 6. Build de la imagen (Stage 1 cachea deps SBT; Stage 2 solo JRE):
      docker build -t {service_name}:latest .

 7. Ejecutar con Docker:
      docker run --env-file .env {service_name}:latest

 ── Kubernetes (CronJob) ───────────────────────────────────────────────

    Schedule configurado : {schedule}
    Helm chart generado  : helm/{service_name}/

 8. Instalar/actualizar en el cluster:
      helm upgrade --install {service_name} helm/{service_name}/ \\
        --namespace <namespace> \\
        -f helm/{service_name}/values-dev.yaml

 9. Forzar ejecución inmediata (sin esperar el schedule):
      kubectl create job --from=cronjob/{service_name} {service_name}-manual -n <namespace>

10. Ver logs del último Job:
      kubectl logs -l app={service_name} -n <namespace> --tail=100

 ── CI/CD ──────────────────────────────────────────────────────────────

    Jenkinsfile generado con pipeline:
      Checkout → Build & Test → SonarQube → Security Scans
      → Kaniko build/push ECR → Trivy scan → bumpImageTag (GitOps)
    ArgoCD detecta el commit y actualiza el CronJob en el cluster.

════════════════════════════════════════════════════════════════════════
""")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="scala_hexagonal_scaffold",
        description="Genera un proyecto base Scala (sbt) multimódulo con arquitectura hexagonal.",
    )
    parser.add_argument("--service-name", default="users", metavar="NAME",
                        help="Nombre del servicio (default: users)")
    parser.add_argument("--report-role", choices=["extraction", "processing"], default=None,
                        help="Activa el modo reportería (ETL Spark). Sin este flag → arquetipo genérico.")
    parser.add_argument("--source", choices=["mongo", "jdbc"], default="mongo",
                        help="Solo extraction: fuente de datos (mongo=read model CQRS [default] | jdbc).")
    parser.add_argument("--kafka-in", default="report.extracted", metavar="TOPIC",
                        help="Solo processing: topic Kafka a consumir (default: report.extracted).")
    parser.add_argument("--kafka-out", default=None, metavar="TOPIC",
                        help="Topic Kafka a publicar (default: report.extracted en extraction / report.processed en processing).")
    parser.add_argument("--report-types", default="", metavar="CSV",
                        help="Solo processing: lista CSV de tipos de reporte (un transformer + registro por tipo).")
    parser.add_argument("--schedule", default="0 * * * *", metavar="CRON",
                        help="Expresión cron del CronJob K8s (default: '0 * * * *' = cada hora). "
                             "Ej: '0 2 * * *' = 2 AM diario, '0 8 * * 1' = lunes 8 AM.")
    parser.add_argument("--org", default="myproject", metavar="ORG",
                        help="Slug org/proyecto: prefijo de secrets (<org>/dev/<svc>), "
                             "organización Gitea y paquete Shared Library (org.<org>). "
                             "(default: myproject)")
    parser.add_argument("--pg-db", default="", metavar="PREFIX",
                        help="Prefijo de BD PostgreSQL (Database-per-Service). "
                             "El read model CQRS (--source jdbc) usará: <prefix>_readmodel. "
                             "Debe coincidir con el -p/--pg-db de init-databases.sh.")
    parser.add_argument("root", nargs="?", default=None, metavar="ROOT",
                        help="Directorio raíz donde generar el proyecto (default: .)")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Mostrar logs detallados (DEBUG)")

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    service_name_provided = "--service-name" in sys.argv

    try:
        scaffold(args.service_name, args.root, service_name_provided,
                 report_role=args.report_role, source=args.source,
                 kafka_in=args.kafka_in, kafka_out=args.kafka_out,
                 report_types=args.report_types,
                 schedule=args.schedule,
                 org=args.org,
                 pg_db_prefix=args.pg_db)
    except OSError as e:
        logger.error("No se pudo crear el proyecto: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
