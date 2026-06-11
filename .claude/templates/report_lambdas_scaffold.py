#!/usr/bin/env python3
"""Genera la capa de formatos del subsistema de reportería.

Un único *Kafka Consumer* (OCI Functions en prod / servicio en VPS dev) consume el topic
`ReportParquetGenerated` (report.processed), lee el parquet del almacenamiento de objetos,
genera los formatos pedidos (csv, xls) y escribe los archivos en `output/<fmt>/`.

**SIN EventBridge intermedio** — el consumer genera todos los formatos directamente.

Almacenamiento:
  Dev:  MinIO en K3s (STORAGE_ENDPOINT=http://minio.infra.svc.cluster.local:9000)
  Prod: OCI Object Storage (compatible S3A) o AWS S3

Terraform genera:
  - Lambda Kafka Consumer (única función, todos los formatos)
  - Trigger Kafka (self-managed sobre Strimzi/MSK)
  - IAM Role con permisos S3-compatible (sin EventBridge)
"""

import argparse
import logging
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

SUPPORTED_FORMATS = {"XLS", "CSV"}  # formatos inline en el handler; el campo `format` del evento los determina


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
# Kafka Consumer Lambda — genera TODOS los formatos directamente (sin EventBridge)
# --------------------------------------------------------------------------- #
def kafka_consumer_handler(root: Path, org: str, topic: str) -> None:
    """Genera el único Kafka Consumer Lambda.

    El evento consumido lleva el campo `format` (singular). El report-etl-service (Scala)
    publica UN mensaje por formato — el consumer genera exactamente ese archivo.
    Toda la lógica de generación está inline en este handler (sin Lambdas separadas).
    """
    base = "terraform/backend/modules/reporting-lambdas/kafka-consumer"

    handler_py = _r('''"""Lambda Kafka Consumer — capa de formatos del subsistema de reportería.

Consume el evento `ReportParquetGenerated` (topic: __TOPIC__).
Cada mensaje lleva el campo `format` (singular: "CSV" o "XLS").
El report-etl-service publica UN mensaje por formato; este consumer lo genera directamente.

Flujo: Kafka __TOPIC__ → leer parquet → generar format → escribir output/<fmt>/...
Errores → publica ReportETLFailed en Kafka (report.processing.failed).

**SIN EventBridge intermedio. Lógica de generación inline en este handler.**
Almacenamiento: MinIO (dev K3s) / OCI Object Storage (prod) via S3-compatible endpoint.
"""
import json
import os
import io
import csv
import base64
import logging

import boto3
import pyarrow.dataset as ds
import pyarrow.fs as pafs
from openpyxl import Workbook

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

REPORT_BUCKET   = os.environ.get("REPORT_BUCKET",   "__ORG__-reports")
KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "kafka-kafka-bootstrap.messaging.svc.cluster.local:9092")
FAILED_TOPIC    = "report.processing.failed"
DEFAULT_FORMAT  = "CSV"

# Almacenamiento S3-compatible (MinIO dev / OCI prod / AWS S3)
_endpoint = os.environ.get("STORAGE_ENDPOINT") or None
s3 = boto3.client(
    "s3",
    endpoint_url=_endpoint,
    aws_access_key_id=os.environ.get("STORAGE_ACCESS_KEY", "minioadmin"),
    aws_secret_access_key=os.environ.get("STORAGE_SECRET_KEY", "changeme_minio"),
)


def _records(event):
    """Soporta el envelope de trigger MSK/Kafka (event[\'records\']) y la invocación directa."""
    if "records" in event:
        for _topic, msgs in event["records"].items():
            for m in msgs:
                raw = m.get("value", "")
                try:
                    yield json.loads(base64.b64decode(raw).decode("utf-8"))
                except Exception:
                    yield json.loads(raw)
    else:
        yield event


def _s3fs():
    return pafs.S3FileSystem(
        endpoint_override=_endpoint,
        scheme="http" if _endpoint else "https",
        access_key=os.environ.get("STORAGE_ACCESS_KEY", "minioadmin"),
        secret_key=os.environ.get("STORAGE_SECRET_KEY", "changeme_minio"),
    )


def _publish_failed(report_id: str, fmt: str, reason: str) -> None:
    """Publica ReportETLFailed a Kafka (best-effort)."""
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


def handler(event, _context=None):
    results = []

    for msg in _records(event):
        report_id   = msg.get("reportId", "unknown")
        report_type = msg.get("reportType", "report")
        parquet_uri = msg.get("processedParquetUri") or msg.get("rawParquetUri", "")
        fmt         = (msg.get("format") or DEFAULT_FORMAT).upper()  # singular del evento

        if not parquet_uri:
            logger.error("processedParquetUri vacío para reportId=%s", report_id)
            _publish_failed(report_id, fmt, "processedParquetUri vacío")
            continue

        # ── Leer parquet desde almacenamiento de objetos ──────────────────────
        try:
            table = ds.dataset(parquet_uri, format="parquet", filesystem=_s3fs()).to_table()
        except Exception as exc:
            logger.error("Error leyendo parquet %s: %s", parquet_uri, exc)
            _publish_failed(report_id, fmt, f"Error leyendo parquet: {exc}")
            continue

        # ── Generar formato (lógica inline según campo `format`) ──────────────
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
                logger.warning("Formato no soportado: %s (soportados: CSV, XLS)", fmt)
                _publish_failed(report_id, fmt, f"Formato no soportado: {fmt}")
                continue

            output_uri = f"s3://{REPORT_BUCKET}/{key}"
            results.append({"format": fmt, "output": output_uri, "rows": table.num_rows})
            logger.info("Generado %s → %s (%d filas)", fmt, output_uri, table.num_rows)

        except Exception as exc:
            logger.error("Error generando %s para reportId=%s: %s", fmt, report_id, exc)
            _publish_failed(report_id, fmt, f"Error generando {fmt}: {exc}")

    return {"generated": len(results), "outputs": results}
''', TOPIC=topic, ORG=org)

    write(root, f"{base}/handler.py", handler_py)
    write(root, f"{base}/requirements.txt",
          "boto3\npyarrow\nopenpyxl\nkafka-python\n")


# --------------------------------------------------------------------------- #
# Terraform — Lambda + Kafka trigger (sin EventBridge)
# --------------------------------------------------------------------------- #
def terraform(root: Path, org: str, topic: str, runtime: str) -> None:
    base = "terraform/backend/modules/reporting-lambdas"

    write(root, f"{base}/variables.tf", _r('''variable "org" {
  type    = string
  default = "__ORG__"
}

# Endpoint almacenamiento S3-compatible.
# Dev:  http://minio.infra.svc.cluster.local:9000  (MinIO en K3s)
# Prod: OCI Object Storage endpoint o vacío para AWS S3 real.
variable "storage_endpoint" {
  type    = string
  default = "http://minio.infra.svc.cluster.local:9000"
}

variable "storage_access_key" {
  type      = string
  sensitive = true
  default   = "minioadmin"
}

variable "storage_secret_key" {
  type      = string
  sensitive = true
  default   = "changeme_minio"
}

variable "report_bucket" {
  type    = string
  default = "__ORG__-reports"
}

variable "lambda_runtime" {
  type    = string
  default = "__RUNTIME__"
}

variable "kafka_bootstrap_servers" {
  type    = string
  default = "kafka-kafka-bootstrap.messaging.svc.cluster.local:9092"
}

variable "kafka_topic" {
  type    = string
  default = "__TOPIC__"
}
''', ORG=org, RUNTIME=runtime, TOPIC=topic))

    write(root, f"{base}/iam.tf", '''data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "reporting_lambda" {
  name               = "${var.org}-reporting-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "reporting_lambda" {
  # Lee processed/, escribe output/ — sin EventBridge (SIN EventBridge intermedio).
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.report_bucket}", "arn:aws:s3:::${var.report_bucket}/processed/*"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.report_bucket}/output/*"]
  }
  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "reporting_lambda" {
  name   = "${var.org}-reporting-lambda"
  role   = aws_iam_role.reporting_lambda.id
  policy = data.aws_iam_policy_document.reporting_lambda.json
}
''')

    write(root, f"{base}/lambda.tf", _r('''# Kafka Consumer Lambda — genera CSV/XLS directamente desde parquet.
# SIN EventBridge intermedio (alineado con DS-xxx capa serverless de formatos).
data "archive_file" "kafka_consumer" {
  type        = "zip"
  source_dir  = "${path.module}/kafka-consumer"
  output_path = "${path.module}/build/kafka-consumer.zip"
}

resource "aws_lambda_function" "kafka_consumer" {
  function_name    = "${var.org}-report-format-consumer"
  role             = aws_iam_role.reporting_lambda.arn
  runtime          = var.lambda_runtime
  handler          = "handler.handler"
  filename         = data.archive_file.kafka_consumer.output_path
  source_code_hash = data.archive_file.kafka_consumer.output_base64sha256
  timeout          = 300
  memory_size      = 1024

  environment {
    variables = {
      REPORT_BUCKET              = var.report_bucket
      STORAGE_ENDPOINT           = var.storage_endpoint
      STORAGE_ACCESS_KEY         = var.storage_access_key
      STORAGE_SECRET_KEY         = var.storage_secret_key
      KAFKA_BOOTSTRAP_SERVERS    = var.kafka_bootstrap_servers
    }
  }
}

# Trigger Kafka self-managed (Strimzi en K3s / MSK en prod).
# topic: __TOPIC__ = ReportParquetGenerated (output de report-etl-service).
resource "aws_lambda_event_source_mapping" "kafka_consumer" {
  function_name     = aws_lambda_function.kafka_consumer.arn
  topics            = [var.kafka_topic]
  starting_position = "TRIM_HORIZON"

  self_managed_event_source {
    endpoints = {
      KAFKA_BOOTSTRAP_SERVERS = var.kafka_bootstrap_servers
    }
  }
}
''', TOPIC=topic))

    write(root, f"{base}/outputs.tf", '''output "format_consumer_function" {
  value       = aws_lambda_function.kafka_consumer.function_name
  description = "Lambda Kafka Consumer que genera CSV/XLS desde parquet (sin EventBridge)."
}

output "format_consumer_arn" {
  value = aws_lambda_function.kafka_consumer.arn
}
''')


# --------------------------------------------------------------------------- #
# scaffold
# --------------------------------------------------------------------------- #
def scaffold(org: str, topic: str, runtime: str, root_arg: str | None) -> None:
    root = Path(root_arg) if root_arg else Path(".")
    logger.info("Scaffolding reporting format consumer at: %s", root.resolve())
    logger.info("org=%s topic=%s runtime=%s", org, topic, runtime)

    # El handler soporta CSV y XLS inline; el formato viene del campo `format` del evento.
    kafka_consumer_handler(root, org, topic)
    terraform(root, org, topic, runtime)

    write(root, "terraform/backend/modules/reporting-lambdas/README.md", _r('''# reporting-lambdas — capa de formatos del subsistema de reportería

Generado por `report_lambdas_scaffold.py` (DS-xxx capa serverless de formatos).

## Arquitectura

```
Kafka topic: __TOPIC__  (= ReportParquetGenerated, output de report-etl-service)
       │
       ▼
Lambda Kafka Consumer  ──►  lee parquet (MinIO dev / OCI Object Storage prod)
       │                ──►  genera CSV → output/csv/<reportType>/<reportId>.csv
       │                ──►  genera XLS → output/xls/<reportType>/<reportId>.xlsx
       │
       └── error ──►  Kafka topic: report.processing.failed  (ReportETLFailed)
```

**SIN EventBridge intermedio** — un solo consumer genera todos los formatos.

## Almacenamiento

| Entorno | Endpoint | Tipo |
|---------|----------|------|
| Dev (K3s) | `http://minio.infra.svc.cluster.local:9000` | MinIO (S3-compatible) |
| Prod (OCI) | OCI Object Storage S3-compatible endpoint | OCI Object Storage |

## Estructura generada

```
terraform/backend/modules/reporting-lambdas/
├── variables.tf
├── iam.tf
├── lambda.tf          # Lambda + Kafka trigger (sin EventBridge)
├── outputs.tf
└── kafka-consumer/    # consume __TOPIC__ → genera CSV/XLS directamente
    ├── handler.py
    └── requirements.txt
```

## Desplegar (dev, K3s)

```bash
cd terraform/backend/environments/dev
terraform init
terraform apply \
  -var="storage_endpoint=http://VPS_IP:9000" \
  -var="kafka_bootstrap_servers=VPS_IP:32092"
```

## Variables de entorno de la Lambda

| Variable | Descripción |
|----------|-------------|
| `STORAGE_ENDPOINT` | Endpoint S3-compatible (MinIO o OCI) |
| `STORAGE_ACCESS_KEY` | Access key del almacenamiento |
| `STORAGE_SECRET_KEY` | Secret key del almacenamiento |
| `REPORT_BUCKET` | Nombre del bucket/contenedor |
| `KAFKA_BOOTSTRAP_SERVERS` | Bootstrap de Kafka para publicar ReportETLFailed |
''', TOPIC=topic))

    abs_root = root.resolve()
    tf_module = abs_root / "terraform/backend/modules/reporting-lambdas"
    print(f"\nDone! Reporting format consumer scaffolded at: {tf_module}")
    print("\nArquitectura:")
    print(f"  report-etl-service (Scala) → publica 1 evento por formato en: {topic}")
    print("    Evento: {reportId, reportType, processedParquetUri, format: 'CSV'|'XLS'}")
    print("  Lambda Consumer → lee format del evento → genera ese archivo inline")
    print("\nNext:")
    print("  1. Descomenta el módulo 'reporting_lambdas' en terraform/.../main.tf")
    print("  2. terraform init && terraform apply")
    print(f"  3. El consumer escuchará: {topic}")
    print("     Formato CSV  → output/csv/<reportType>/<reportId>.csv")
    print("     Formato XLS  → output/xls/<reportType>/<reportId>.xlsx")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="report_lambdas_scaffold",
        description="Genera el Kafka Consumer de formatos (CSV/XLS) — sin EventBridge.",
    )
    parser.add_argument("--org", required=True,
                        help="Prefijo del proyecto (bucket, nombres de recursos).")
    parser.add_argument("--kafka-topic", default="report.processed",
                        help="Topic Kafka a consumir (= ReportParquetGenerated). Default: report.processed")
    parser.add_argument("--runtime", default="python3.12",
                        help="Runtime Lambda. Default: python3.12")
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
        scaffold(args.org, args.kafka_topic, args.runtime, args.root)
    except OSError as e:
        logger.error("No se pudo generar la capa de formatos: %s", e)
        sys.exit(1)


if __name__ == "__main__":
    main()
