#!/usr/bin/env python3
"""Genera la capa de formatos del subsistema de reportería con OpenFaaS en K3s.

El Kafka Connector de OpenFaaS (desplegado via Terraform Helm provider) consume el topic
`ReportParquetGenerated`, invoca la función OpenFaaS `report-format-consumer` que lee
el parquet de MinIO, genera los formatos pedidos (csv, xls) y escribe en `output/<fmt>/`.

**Sin bash deploy scripts** — todo el despliegue Helm/K8s se gestiona con Terraform:
  - OpenFaaS gateway (cluster infra): helm-serverless en base-infrastructure-builder.sh
  - Kafka Connector (por proyecto): helm_release en terraform/reporting/
  - Secrets MinIO: kubernetes_secret en terraform/reporting/
  - Función: null_resource + faas-cli en terraform/reporting/

Almacenamiento:
  Dev/Prod: MinIO en K3s (STORAGE_ENDPOINT=http://minio.infra.svc.cluster.local:9000)
"""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

SUPPORTED_FORMATS = {"XLS", "CSV"}


def write(root: Path, relative: str, content: str) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)
    logger.info("  created %s", relative)


def _r(content: str, **kw: str) -> str:
    out = content
    for k, v in kw.items():
        out = out.replace(f"__{k}__", v)
    return out


# --------------------------------------------------------------------------- #
# OpenFaaS function handler
# --------------------------------------------------------------------------- #
def openfaas_handler(root: Path, org: str, topic: str) -> None:
    """Genera el handler Python para la función OpenFaaS report-format-consumer."""
    base = "k8s/reporting/openfaas/function"

    handler_py = _r('''"""OpenFaaS Function — capa de formatos del subsistema de reportería.

Invocada por el Kafka Connector de OpenFaaS cuando llega un mensaje en el topic __TOPIC__.
Cada mensaje lleva el campo `format` (singular: "CSV" o "XLS").
El report-etl-service publica UN mensaje por formato; esta función lo genera directamente.

Flujo: Kafka __TOPIC__ → leer parquet (MinIO) → generar format → escribir output/<fmt>/...
Errores → publica ReportETLFailed en Kafka (report.processing.failed).

Secrets montados por OpenFaaS en /var/openfaas/secrets/:
  - report-minio-access-key   (kubernetes_secret en terraform/reporting/)
  - report-minio-secret-key   (kubernetes_secret en terraform/reporting/)
"""
import json
import os
import io
import csv
import logging
from pathlib import Path

import boto3
import pyarrow.dataset as ds
import pyarrow.fs as pafs
from openpyxl import Workbook

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

REPORT_BUCKET    = os.environ.get("REPORT_BUCKET",   "__ORG__-reports")
STORAGE_ENDPOINT = os.environ.get("STORAGE_ENDPOINT", "http://minio.infra.svc.cluster.local:9000")
KAFKA_BOOTSTRAP  = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "kafka-kafka-bootstrap.messaging.svc.cluster.local:9092")
FAILED_TOPIC     = "report.processing.failed"
DEFAULT_FORMAT   = "CSV"


def _read_secret(name: str, env_fallback: str, default: str = "") -> str:
    try:
        return Path(f"/var/openfaas/secrets/{name}").read_text().strip()
    except FileNotFoundError:
        return os.environ.get(env_fallback, default)


def _s3_client():
    return boto3.client(
        "s3",
        endpoint_url=STORAGE_ENDPOINT,
        aws_access_key_id=_read_secret("report-minio-access-key", "STORAGE_ACCESS_KEY", "minioadmin"),
        aws_secret_access_key=_read_secret("report-minio-secret-key", "STORAGE_SECRET_KEY", "changeme_minio"),
    )


def _s3fs():
    return pafs.S3FileSystem(
        endpoint_override=STORAGE_ENDPOINT,
        scheme="http" if STORAGE_ENDPOINT else "https",
        access_key=_read_secret("report-minio-access-key", "STORAGE_ACCESS_KEY", "minioadmin"),
        secret_key=_read_secret("report-minio-secret-key", "STORAGE_SECRET_KEY", "changeme_minio"),
    )


def _publish_failed(report_id: str, fmt: str, reason: str) -> None:
    try:
        from kafka import KafkaProducer
        p = KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        )
        p.send(FAILED_TOPIC, key=f"{report_id}-{fmt}".encode(), value={
            "reportId": report_id,
            "stage": "format-generation",
            "format": fmt,
            "reason": reason,
        })
        p.flush()
        p.close()
    except Exception as exc:
        logger.warning("No se pudo publicar ReportETLFailed: %s", exc)


def _process_message(msg: dict) -> dict:
    report_id   = msg.get("reportId", "unknown")
    report_type = msg.get("reportType", "report")
    parquet_uri = msg.get("processedParquetUri") or msg.get("rawParquetUri", "")
    fmt         = (msg.get("format") or DEFAULT_FORMAT).upper()

    if not parquet_uri:
        logger.error("processedParquetUri vacío para reportId=%s", report_id)
        _publish_failed(report_id, fmt, "processedParquetUri vacío")
        return {}

    try:
        table = ds.dataset(parquet_uri, format="parquet", filesystem=_s3fs()).to_table()
    except Exception as exc:
        logger.error("Error leyendo parquet %s: %s", parquet_uri, exc)
        _publish_failed(report_id, fmt, f"Error leyendo parquet: {exc}")
        return {}

    s3 = _s3_client()

    try:
        if fmt == "CSV":
            buf = io.StringIO()
            writer = csv.writer(buf)
            writer.writerow(table.column_names)
            for row in zip(*[col.to_pylist() for col in table.columns]):
                writer.writerow(row)
            key = f"output/csv/{report_type}/{report_id}.csv"
            s3.put_object(
                Bucket=REPORT_BUCKET,
                Key=key,
                Body=buf.getvalue().encode("utf-8"),
                ContentType="text/csv",
            )

        elif fmt == "XLS":
            wb = Workbook()
            ws = wb.active
            ws.title = report_type[:31]
            ws.append(table.column_names)
            for row in zip(*[col.to_pylist() for col in table.columns]):
                ws.append(list(row))
            buf = io.BytesIO()
            wb.save(buf)
            key = f"output/xls/{report_type}/{report_id}.xlsx"
            s3.put_object(
                Bucket=REPORT_BUCKET,
                Key=key,
                Body=buf.getvalue(),
                ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            )

        else:
            logger.warning("Formato no soportado: %s", fmt)
            _publish_failed(report_id, fmt, f"Formato no soportado: {fmt}")
            return {}

        output_uri = f"s3://{REPORT_BUCKET}/{key}"
        logger.info("Generado %s → %s (%d filas)", fmt, output_uri, table.num_rows)
        return {"format": fmt, "output": output_uri, "rows": table.num_rows}

    except Exception as exc:
        logger.error("Error generando %s para reportId=%s: %s", fmt, report_id, exc)
        _publish_failed(report_id, fmt, f"Error generando {fmt}: {exc}")
        return {}


def handle(event, context):
    """Entrypoint OpenFaaS — el Kafka Connector envía el mensaje Kafka como body HTTP."""
    body = event.body
    if isinstance(body, bytes):
        body = body.decode("utf-8")

    try:
        msg = json.loads(body)
    except json.JSONDecodeError as exc:
        logger.error("Body no es JSON válido: %s", exc)
        return {"statusCode": 400, "body": json.dumps({"error": "invalid JSON"})}

    result = _process_message(msg)

    if result:
        return {"statusCode": 200, "body": json.dumps({"generated": 1, "outputs": [result]})}
    return {"statusCode": 500, "body": json.dumps({"generated": 0, "outputs": []})}
''', TOPIC=topic, ORG=org)

    write(root, f"{base}/handler.py", handler_py)
    write(root, f"{base}/requirements.txt",
          "boto3\npyarrow\nopenpyxl\nkafka-python\n")


# --------------------------------------------------------------------------- #
# faas-cli stack.yml
# --------------------------------------------------------------------------- #
def stack_yml(root: Path, org: str, topic: str, image_registry: str) -> None:
    base = "k8s/reporting/openfaas/function"

    content = _r('''version: 1.0
provider:
  name: openfaas
  # Gateway desplegado por helm-serverless en base-infrastructure-builder.sh
  gateway: http://gateway.serverless.svc.cluster.local:8080

functions:
  report-format-consumer:
    lang: python3-http
    handler: ./
    image: __REGISTRY__/__ORG__/report-format-consumer:latest
    # El Kafka Connector lee esta anotación para enrutar mensajes automáticamente
    annotations:
      topic: __TOPIC__
    environment:
      REPORT_BUCKET: __ORG__-reports
      STORAGE_ENDPOINT: http://minio.infra.svc.cluster.local:9000
      KAFKA_BOOTSTRAP_SERVERS: kafka-kafka-bootstrap.messaging.svc.cluster.local:9092
    # Secrets creados por kubernetes_secret en terraform/reporting/
    secrets:
      - report-minio-access-key
      - report-minio-secret-key
    limits:
      memory: 512Mi
      cpu: 500m
    requests:
      memory: 256Mi
      cpu: 100m
''', TOPIC=topic, ORG=org, REGISTRY=image_registry)

    write(root, f"{base}/stack.yml", content)


# --------------------------------------------------------------------------- #
# Terraform — Kafka Connector + secrets + faas-cli deploy
# --------------------------------------------------------------------------- #
def terraform_module(root: Path, org: str, topic: str, image_registry: str) -> None:
    """Genera el módulo Terraform que gestiona la capa de reportería por proyecto.

    El OpenFaaS gateway ya existe en el cluster (desplegado por base-infrastructure-builder.sh
    como helm-serverless). Este módulo añade lo que es proyecto-específico:
      - kubernetes_secret para credenciales MinIO (montadas por la función)
      - helm_release kafka-connector (configurado con el topic del proyecto)
      - null_resource con faas-cli deploy (build + push + deploy de la función)
    """
    tf_base = "terraform/reporting"

    # providers.tf
    write(root, f"{tf_base}/providers.tf", '''terraform {
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
''')

    # variables.tf
    write(root, f"{tf_base}/variables.tf", _r('''variable "kubeconfig_path"              { type = string }
variable "org"                          { type = string; default = "__ORG__" }
variable "kafka_topic"                  { type = string; default = "__TOPIC__" }
variable "kafka_bootstrap"              { type = string; default = "kafka-kafka-bootstrap.messaging.svc.cluster.local:9092" }
variable "report_bucket"                { type = string; default = "__ORG__-reports" }
variable "storage_endpoint"             { type = string; default = "http://minio.infra.svc.cluster.local:9000" }
variable "minio_access_key"             { type = string; sensitive = true; default = "minioadmin" }
variable "minio_secret_key"             { type = string; sensitive = true; default = "changeme_minio" }
variable "image_registry"               { type = string; default = "__REGISTRY__" }
variable "function_image_tag"           { type = string; default = "latest" }
variable "openfaas_gateway"             { type = string; default = "http://gateway.serverless.svc.cluster.local:8080" }
variable "openfaas_basic_auth_password" { type = string; sensitive = true; default = "changeme_openfaas" }
''', ORG=org, TOPIC=topic, REGISTRY=image_registry))

    # main.tf
    write(root, f"{tf_base}/main.tf", '''module "openfaas_function" {
  source = "./modules/openfaas-function"

  org                          = var.org
  kafka_topic                  = var.kafka_topic
  kafka_bootstrap              = var.kafka_bootstrap
  report_bucket                = var.report_bucket
  storage_endpoint             = var.storage_endpoint
  minio_access_key             = var.minio_access_key
  minio_secret_key             = var.minio_secret_key
  image_registry               = var.image_registry
  function_image_tag           = var.function_image_tag
  openfaas_gateway             = var.openfaas_gateway
  openfaas_basic_auth_password = var.openfaas_basic_auth_password
  kubeconfig_path              = var.kubeconfig_path
}
''')

    # modules/openfaas-function/variables.tf
    mod = f"{tf_base}/modules/openfaas-function"
    write(root, f"{mod}/variables.tf", '''variable "org"                          { type = string }
variable "kafka_topic"                  { type = string }
variable "kafka_bootstrap"              { type = string }
variable "report_bucket"                { type = string }
variable "storage_endpoint"             { type = string }
variable "minio_access_key"             { type = string; sensitive = true }
variable "minio_secret_key"             { type = string; sensitive = true }
variable "image_registry"               { type = string }
variable "function_image_tag"           { type = string; default = "latest" }
variable "openfaas_gateway"             { type = string }
variable "openfaas_basic_auth_password" { type = string; sensitive = true }
variable "kubeconfig_path"              { type = string }
''')

    # modules/openfaas-function/main.tf
    write(root, f"{mod}/main.tf", '''# Secrets MinIO montados por OpenFaaS en /var/openfaas/secrets/<name>
resource "kubernetes_secret" "minio_access_key" {
  metadata {
    name      = "report-minio-access-key"
    namespace = "serverless-fn"
  }
  data = { "report-minio-access-key" = var.minio_access_key }
}

resource "kubernetes_secret" "minio_secret_key" {
  metadata {
    name      = "report-minio-secret-key"
    namespace = "serverless-fn"
  }
  data = { "report-minio-secret-key" = var.minio_secret_key }
}

# Helm repo OpenFaaS (idempotente — mismo repo que usa base-infrastructure-builder.sh)
resource "null_resource" "openfaas_helm_repo" {
  provisioner "local-exec" {
    command = "helm repo add openfaas https://openfaas.github.io/faas-netes/ 2>/dev/null || true && helm repo update"
  }
  triggers = { always = timestamp() }
}

# Kafka Connector — bridge Strimzi (messaging ns) → función OpenFaaS
# El connector enruta automáticamente los mensajes del topic a las funciones
# que tienen la anotación `topic: <kafka_topic>` en su stack.yml.
resource "helm_release" "kafka_connector" {
  depends_on = [null_resource.openfaas_helm_repo]

  name       = "kafka-connector"
  repository = "https://openfaas.github.io/faas-netes/"
  chart      = "kafka-connector"
  namespace  = "serverless"
  wait       = true
  timeout    = 120

  set { name = "topics";           value = var.kafka_topic }
  set { name = "broker.host";      value = split(":", var.kafka_bootstrap)[0] }
  set { name = "broker.port";      value = split(":", var.kafka_bootstrap)[1] }
  set { name = "gatewayURL";       value = var.openfaas_gateway }
  set { name = "upstreamTimeout";  value = "300s" }
  set { name = "asyncInvocation";  value = "false" }
  set { name = "contentType";      value = "application/json" }
  set { name = "printResponse";    value = "true" }
  set { name = "basicAuth";        value = "true" }
  set_sensitive { name = "basicAuthPassword"; value = var.openfaas_basic_auth_password }
}

# Deploy función via faas-cli (build + push + deploy)
# Se re-ejecuta cuando cambia image_tag, topic o gateway.
resource "null_resource" "deploy_function" {
  depends_on = [
    helm_release.kafka_connector,
    kubernetes_secret.minio_access_key,
    kubernetes_secret.minio_secret_key,
  ]

  provisioner "local-exec" {
    command = <<-CMD
      bash '${path.module}/deploy-function.sh' \
        '${var.image_registry}' \
        '${var.org}' \
        '${var.function_image_tag}' \
        '${var.openfaas_gateway}'
    CMD
    environment = {
      OPENFAAS_BASIC_AUTH_PASSWORD = var.openfaas_basic_auth_password
    }
  }

  triggers = {
    image_tag   = var.function_image_tag
    kafka_topic = var.kafka_topic
    gateway     = var.openfaas_gateway
  }
}
''')

    # modules/openfaas-function/deploy-function.sh
    write(root, f"{mod}/deploy-function.sh", _r('''#!/usr/bin/env bash
# Construye y despliega la función report-format-consumer en OpenFaaS.
# Invocado por null_resource.deploy_function (Terraform) con las variables
# OPENFAAS_BASIC_AUTH_PASSWORD inyectadas como env por Terraform.
set -euo pipefail

REGISTRY="$1"
ORG="$2"
IMAGE_TAG="${3:-latest}"
GATEWAY="$4"

FUNCTION_DIR="$(cd "$(dirname "$0")/../../../k8s/reporting/openfaas/function" && pwd)"

echo "[INFO] Instalando template python3-http..."
OPENFAAS_URL="${GATEWAY}" faas-cli template store pull python3-http 2>/dev/null || true

echo "[INFO] Build imagen ${REGISTRY}/${ORG}/report-format-consumer:${IMAGE_TAG}..."
OPENFAAS_URL="${GATEWAY}" faas-cli build -f "${FUNCTION_DIR}/stack.yml"

echo "[INFO] Push imagen..."
OPENFAAS_URL="${GATEWAY}" faas-cli push -f "${FUNCTION_DIR}/stack.yml"

echo "[INFO] Login en OpenFaaS gateway ${GATEWAY}..."
echo "${OPENFAAS_BASIC_AUTH_PASSWORD}" \
  | OPENFAAS_URL="${GATEWAY}" faas-cli login --username admin --password-stdin

echo "[INFO] Deploy función report-format-consumer..."
OPENFAAS_URL="${GATEWAY}" faas-cli deploy -f "${FUNCTION_DIR}/stack.yml"

echo "[OK] report-format-consumer desplegada en ${GATEWAY}"
echo "     Escuchando topic: __TOPIC__"
''', TOPIC=topic))

    # environments/local.tfvars
    write(root, f"{tf_base}/environments/local.tfvars", _r('''kubeconfig_path              = "/etc/rancher/k3s/k3s.yaml"
org                          = "__ORG__"
kafka_topic                  = "__TOPIC__"
image_registry               = "localhost:5000"
minio_access_key             = "minioadmin"
minio_secret_key             = "changeme_minio"
openfaas_basic_auth_password = "changeme_openfaas"
''', ORG=org, TOPIC=topic))


# --------------------------------------------------------------------------- #
# README
# --------------------------------------------------------------------------- #
def readme(root: Path, org: str, topic: str, image_registry: str) -> None:
    content = _r('''# reporting-openfaas — capa de formatos del subsistema de reportería

Generado por `report_lambdas_scaffold.py`.
OpenFaaS desplegado via Terraform Helm provider en K3s. Sin AWS Lambda ni bash deploy scripts.

## Arquitectura

```
Kafka topic: __TOPIC__  (= ReportParquetGenerated, output de report-etl-service)
       │
       ▼
helm_release.kafka_connector  [terraform/reporting/]
  (openfaas/kafka-connector via Terraform Helm provider)
       │   [HTTP POST body = mensaje Kafka]
       ▼
OpenFaaS Function: report-format-consumer  [k8s/reporting/openfaas/function/]
  (desplegada por null_resource + faas-cli en terraform/reporting/)
       │ ──► lee parquet (MinIO vía kubernetes_secret con credenciales)
       │ ──► genera CSV  → output/csv/<reportType>/<reportId>.csv
       │ ──► genera XLS  → output/xls/<reportType>/<reportId>.xlsx
       │
       └── error ──► Kafka topic: report.processing.failed

OpenFaaS Gateway  [cluster infra — base-infrastructure-builder.sh → helm-serverless]
  helm_release.openfaas  (helm-serverless module, install_openfaas = true)
```

## Prerrequisito: OpenFaaS gateway en el cluster

El gateway ya debe estar desplegado por `base-infrastructure-builder.sh` con
`install_openfaas = true`. Este módulo NO lo despliega; solo añade:
  - `kubernetes_secret` con credenciales MinIO (namespace `serverless-fn`)
  - `helm_release` kafka-connector (namespace `serverless`)
  - `null_resource` con faas-cli build + push + deploy

## Estructura generada

```
k8s/reporting/openfaas/
└── function/
    ├── handler.py      # OpenFaaS handler (python3-http)
    ├── requirements.txt
    └── stack.yml       # faas-cli: imagen, annotations topic, secrets

terraform/reporting/
├── providers.tf        # helm + kubernetes + null providers
├── variables.tf
├── main.tf             # module "openfaas_function"
├── environments/
│   └── local.tfvars
└── modules/
    └── openfaas-function/
        ├── variables.tf
        ├── main.tf     # kubernetes_secret + helm_release + null_resource
        └── deploy-function.sh  # build + push + faas-cli deploy
```

## Despliegue

```bash
# 1. Verificar que OpenFaaS gateway está corriendo (base-infrastructure-builder.sh)
kubectl get pods -n serverless

# 2. Desplegar capa de reportería
cd terraform/reporting
terraform init
terraform apply -var-file=environments/local.tfvars \
  -var="kubeconfig_path=/etc/rancher/k3s/k3s.yaml" \
  -var="minio_access_key=<key>" \
  -var="minio_secret_key=<secret>" \
  -var="openfaas_basic_auth_password=<password>" \
  -var="image_registry=__REGISTRY__"
```

## Variables sensibles

| Variable                        | Descripción                              |
|---------------------------------|------------------------------------------|
| `minio_access_key`              | Access key MinIO (sensitive)             |
| `minio_secret_key`              | Secret key MinIO (sensitive)             |
| `openfaas_basic_auth_password`  | Password del gateway OpenFaaS (sensitive)|

## Evento esperado (topic: __TOPIC__)

```json
{
  "reportId": "abc-123",
  "reportType": "cartera",
  "processedParquetUri": "s3://__ORG__-reports/processed/cartera/abc-123.parquet",
  "format": "CSV"
}
```

Un evento por formato. El report-etl-service publica uno por cada formato solicitado.
''', ORG=org, TOPIC=topic, REGISTRY=image_registry)

    write(root, "k8s/reporting/openfaas/README.md", content)


# --------------------------------------------------------------------------- #
# scaffold
# --------------------------------------------------------------------------- #
def scaffold(org: str, topic: str, image_registry: str, root_arg: str | None) -> None:
    root = Path(root_arg) if root_arg else Path(".")
    logger.info("Scaffolding OpenFaaS reporting layer at: %s", root.resolve())
    logger.info("org=%s topic=%s registry=%s", org, topic, image_registry)

    openfaas_handler(root, org, topic)
    stack_yml(root, org, topic, image_registry)
    terraform_module(root, org, topic, image_registry)
    readme(root, org, topic, image_registry)

    abs_root = root.resolve()
    print(f"\nDone! OpenFaaS reporting layer scaffolded at: {abs_root}")
    print("\nArquitectura de despliegue (Terraform Helm provider):")
    print("  cluster infra:    base-infrastructure-builder.sh → helm-serverless (openfaas gateway)")
    print(f"  kafka connector:  terraform/reporting/ → helm_release.kafka_connector (topic: {topic})")
    print("  minio secrets:    terraform/reporting/ → kubernetes_secret")
    print("  función deploy:   terraform/reporting/ → null_resource + faas-cli")
    print("\nNext:")
    print("  1. Asegurar install_openfaas = true en base-infrastructure-builder.sh")
    print("  2. cd terraform/reporting && terraform init && terraform apply \\")
    print(f"       -var-file=environments/local.tfvars \\")
    print(f"       -var=\"image_registry={image_registry}\"")
    print(f"  3. El Kafka Connector escuchará: {topic}")
    print("     Formato CSV  → output/csv/<reportType>/<reportId>.csv")
    print("     Formato XLS  → output/xls/<reportType>/<reportId>.xlsx")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="report_lambdas_scaffold",
        description="Genera la capa de formatos (OpenFaaS + Terraform Helm provider en K3s).",
    )
    parser.add_argument("--org", required=True,
                        help="Prefijo del proyecto (bucket, nombres de recursos).")
    parser.add_argument("--kafka-topic", default="report.processed",
                        help="Topic Kafka a consumir (= ReportParquetGenerated). Default: report.processed")
    parser.add_argument("--image-registry", default="localhost:5000",
                        help="Registry de imágenes Docker. Default: localhost:5000")
    parser.add_argument("root", nargs="?", default=None,
                        help="Directorio raíz (default: .)")
    parser.add_argument("-v", "--verbose", action="store_true")

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    try:
        scaffold(args.org, args.kafka_topic, args.image_registry, args.root)
    except OSError as e:
        logger.error("No se pudo generar la capa de formatos: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
