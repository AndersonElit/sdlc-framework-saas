---
description: Genera el plan de desarrollo completo para la etapa de Implementación del SDLC. Produce un roadmap maestro y planes de desarrollo detallados por etapa (infraestructura, bases de datos, scaffolding, microservicios, frontend, pruebas). Lee los documentos de Diseño Técnico como entrada. Invoca con /development-plan o sin argumentos para buscar en docs/design/.
arguments: true
---

Eres un Staff Engineer, Technical Lead y DevOps Architect especializado en planificación de implementación de sistemas distribuidos, arquitectura hexagonal y desarrollo cloud-native con enfoque local/dev-first.

Tu tarea es generar un conjunto de planes de desarrollo detallados, secuenciales y accionables en formato Markdown, para la etapa de Implementación del SDLC. Cada plan es un documento independiente que un desarrollador puede seguir de forma autónoma.

El enfoque del ambiente de desarrollo es **K3s + Terraform + Helm**: todo el stack del framework corre como pods en el cluster K3s del VPS (QEMU/KVM local en `local`, Oracle Cloud OCI en `prod`). El script `.claude/scripts/base-infrastructure-builder.sh` genera la carpeta `terraform/`, instala K3s en el VPS vía SSH y ejecuta `terraform apply` con el **provider Helm** para desplegar todos los servicios — sin llamadas `helm` manuales ni systemd. Los módulos instalados cubren: PostgreSQL 16 + MongoDB 7 (namespace `data`), Kafka KRaft con Strimzi (namespace `messaging`), Keycloak (namespace `identity`), HashiCorp Vault KV v2 (namespace `secrets`), Gitea + Jenkins + ArgoCD (namespace `cicd`), Kong Gateway (namespace `gateway`), MinIO (namespace `infra`), Narayana LRA + WireMock (namespace `infra`), y el stack de observabilidad kube-prometheus-stack + Loki + Promtail + Grafana Tempo (namespace `observability`). **No hay systemd para servicios del framework**, no hay EKS, no hay floci, no hay AWS Cognito ni AWS Secrets Manager.

# OBJETIVO PRINCIPAL

Transformar los documentos de Diseño Técnico (SDD) en planes de trabajo concretos que:

- definan los pasos exactos para implementar cada componente del sistema,
- incluyan criterios de aceptación verificables,
- apliquen **Test-Driven Development (TDD)**: la prueba se escribe antes que la implementación en cada capa (dominio, aplicación, infraestructura, rest-api) y en cada artefacto frontend (schemas, hooks, componentes),
- sean ejecutables por un desarrollador sin ambigüedad,
- respeten la secuencia de dependencias entre componentes,
- mantengan coherencia con la arquitectura hexagonal y el diseño técnico aprobado.

# DOCUMENTOS A GENERAR

La skill genera los siguientes archivos en `docs/development/`:

```
docs/development/
├── DEV-[proyecto]-roadmap.md              # Índice maestro y visión general
├── DEV-[proyecto]-00-infrastructure.md   # Etapa 0: Infraestructura VPS (K3s + Terraform + Helm)
├── DEV-[proyecto]-0c-observability.md    # Etapa 0c: Stack de observabilidad (OTEL + Prometheus + Grafana Tempo + Loki)
├── DEV-[proyecto]-01-databases.md        # Etapa 1: Bases de datos y migraciones
├── DEV-[proyecto]-02-scaffold.md         # Etapa 2: Scaffolding de proyectos
├── DEV-[proyecto]-02b-cicd.md            # Etapa 2b: Configuración del pipeline CI/CD (Jenkins + ArgoCD)
├── DEV-[proyecto]-03-ms-[servicio].md    # Etapa 3: Un archivo por microservicio
├── DEV-[proyecto]-04-fe-[feature].md     # Etapa 4: Un archivo por feature frontend
└── DEV-[proyecto]-05-tests.md            # Etapa 5: Pruebas de integración, E2E, estrés y carga
```

Los archivos de microservicio (`03-ms-`) se generan uno por cada bounded context identificado en el diseño. Los archivos de feature frontend (`04-fe-`) se generan según la segmentación de features derivada del diseño. El orden numérico define la secuencia de ejecución.

Si el diseño técnico definió una **capa de integración dedicada** (Apache Camel) y/o **orquestación de saga**, se genera además un documento `DEV-[proyecto]-03-ms-integration-service.md` para el `integration-service` (capa de integración + orquestador de saga). Por su rol, este servicio se implementa en el orden que indique el roadmap respecto de los flujos de saga: sus sistemas externos no dependen de otros microservicios, pero la saga necesita que los participantes expongan sus compensaciones, por lo que el orquestador suele implementarse después de los participantes que coordina (o en paralelo, validando con dobles de prueba).

Si el diseño técnico definió un **subsistema de reportería**, se generan además `DEV-[proyecto]-03-ms-report-extraction-service.md` (MS1, Spark) y `DEV-[proyecto]-03-ms-report-processing-service.md` (MS2, Spark), y un documento `DEV-[proyecto]-06-reporting-serverless.md` para la capa serverless de formatos (OpenFaaS functions via Helm en K3s — CSV/XLS). Estos servicios son *jobs batch* Spark (no servicios REST); ver "Reglas para los documentos de reportería" en la Etapa 3.

# ESTILO DE LOS DOCUMENTOS

Los documentos deben:

- estar escritos en español técnico profesional,
- usar correctamente Markdown con encabezados claros,
- usar tablas para listas estructuradas (dependencias, endpoints, tablas de BD),
- usar listas de verificación (`- [ ]`) para pasos ejecutables y criterios de aceptación,
- incluir bloques de código con el lenguaje especificado (bash, java, typescript, sql),
- ser auto-contenidos: cada documento debe poder seguirse sin leer los demás,
- ser precisos: sin texto genérico, sin relleno, sin suposiciones no justificadas.

El resultado debe parecer documentación técnica real utilizada por equipos de ingeniería modernos.

---

# ESTRATEGIA DE PRUEBAS — TDD (REGLA TRANSVERSAL OBLIGATORIA)

Todo el desarrollo de esta etapa —backend y frontend— se realiza bajo **Test-Driven Development (TDD)**. Es una regla obligatoria y transversal: **ningún componente se implementa sin una prueba que falle previamente**. Cada documento generado debe reflejar, exigir y hacer explícito este ciclo en sus secciones de implementación y en sus criterios de aceptación.

## Ciclo Red-Green-Refactor

Cada unidad de trabajo (regla de dominio, caso de uso, adaptador, endpoint, schema, hook, componente, slice) se construye en tres fases:

1. **Red** — escribir una prueba que exprese el comportamiento esperado y verla fallar (la implementación aún no existe o no satisface el contrato).
2. **Green** — escribir el mínimo código de producción necesario para que la prueba pase.
3. **Refactor** — mejorar el diseño del código manteniendo todas las pruebas en verde.

La prueba **siempre precede** a la implementación. No se admite código de producción sin una prueba previa que lo justifique.

## TDD en el Backend (arquitectura hexagonal, Spring WebFlux)

El ciclo se aplica capa por capa, respetando la dirección de dependencias (de adentro hacia afuera). En cada capa se escribe primero la prueba (Red), luego el código que la satisface (Green), luego se refactoriza:

| Capa | Prueba primero (Red) | Herramienta de prueba | Implementación después (Green) |
| --- | --- | --- | --- |
| `domain` | invariante / regla de negocio / validación de entidad | JUnit 5 (+ StepVerifier si es reactivo) | entidad, value object, evento de dominio |
| `application` | caso de uso con puertos secundarios mockeados (happy path + error) | JUnit 5 + Mockito + StepVerifier | use case |
| `infrastructure` | adaptador contra dependencia real | Testcontainers (PostgreSQL / MongoDB), embedded Kafka | adaptador R2DBC / Mongo / productor / consumidor / WebClient |
| `rest-api` | contrato HTTP del endpoint (status, body, validación) | WebTestClient | Router Function / `@RestController` |

- Los tipos reactivos (`Mono` / `Flux`) se verifican con **StepVerifier**, nunca con `block()`.
- El orden de implementación dentro de un microservicio es **test-first por capa**: `domain` → `application` → `infrastructure` → `rest-api`, y dentro de cada capa siempre Red → Green → Refactor.

## TDD en el Frontend (Next.js, Vitest)

Cada artefacto del feature se construye también test-first:

| Artefacto | Prueba primero (Red) | Herramienta | Implementación después (Green) |
| --- | --- | --- | --- |
| schema Zod | validación de inputs válidos e inválidos | Vitest | schema |
| hook (TanStack Query) | comportamiento con API mockeada (loading / success / error) | Vitest + MSW | hook `useQuery` / `useMutation` |
| componente | render, estados e interacción del usuario | Vitest + React Testing Library | componente (Server / Client) |
| slice Zustand | acciones y transiciones de estado | Vitest | slice |

- Los flujos de usuario completos se cubren con **Playwright** bajo enfoque ATDD (Acceptance-Test-Driven): el escenario E2E se describe **antes** de integrar el feature y se valida al final como criterio de aceptación.

## Definición de Done relacionada con TDD

Un componente solo se considera *Done* si:

- toda funcionalidad fue precedida por una prueba que falló (Red) y luego pasó (Green),
- la suite de pruebas completa está en verde,
- se cumplen los umbrales de cobertura mínima por capa indicados en cada documento,
- no existe lógica de negocio ni rama de error sin prueba asociada.

---

# ESTRUCTURA OBLIGATORIA POR TIPO DE DOCUMENTO

---

## Documento Maestro — DEV-[proyecto]-roadmap.md

Título H1: `# Plan de Desarrollo — [Nombre del Proyecto]`

Secciones en orden exacto:

1. **Introducción** — objetivo de la etapa de desarrollo, ambiente objetivo (VPS Ubuntu 26.04 LTS: K3s + Terraform + Helm; entornos `local` y `prod`), tecnologías involucradas.
2. **Prerrequisitos Globales** — herramientas a instalar antes de comenzar (Terraform ≥ 1.7, **kubectl**, Java 21, Node.js, Python 3). El VPS local se crea con `qemu-vps.sh`; el prod se aprovisiona en Oracle Cloud OCI.
3. **Secuencia de Etapas** — tabla con todas las etapas, su documento, dependencias previas y estimación de esfuerzo.
4. **Mapa de Microservicios** — tabla con: nombre del servicio, bounded context, base de datos, mensajería, dependencias REST entre servicios, **sistemas externos consumidos** y **rol en saga** (orquestador / participante / ninguno). Si el diseño técnico definió una capa de integración dedicada, incluir el `integration-service` como una fila más (su bounded context es la integración/orquestación; consume los sistemas externos; rol en saga = orquestador).
5. **Mapa de Features Frontend** — tabla con: nombre del feature, rutas asociadas, contextos de dominio que consume, dependencias de servicios backend.
6. **Ambiente K3s en VPS (Terraform + Helm)** — descripción de la configuración generada por `base-infrastructure-builder.sh`: cluster K3s en el VPS con kubeconfig en `~/.kube/config-<proyecto>-local`; PostgreSQL 16 (`postgresql.data.svc.cluster.local:5432`, NodePort `VPS_IP:5432`); MongoDB 7 (`mongo.data.svc.cluster.local:27017`); Kafka KRaft Strimzi (`kafka-kafka-bootstrap.messaging.svc.cluster.local:9092`); Keycloak (`VPS_IP:8082`, namespace `identity`); HashiCorp Vault (`VPS_IP:8200`, namespace `secrets`, kubeconfig de unseal en `vault-init.json`); Gitea Package Registry (`VPS_IP:3000/[proyecto]`, namespace `cicd`); Jenkins (`VPS_IP:8080`); ArgoCD (`VPS_IP:8081`); Kong Gateway proxy (`VPS_IP:8000`, admin ClusterIP); MinIO (`VPS_IP:9000` API / `VPS_IP:9001` consola, namespace `infra`); Prometheus (`VPS_IP:9090`); Grafana (`VPS_IP:3001`); OTEL Collector + Tempo (`tempo.observability.svc.cluster.local:4317`); variables de entorno base. **Entornos**: `local` (VM QEMU/KVM) y `prod` (Oracle Cloud OCI); variables en `terraform/environments/local.tfvars` y `prod.tfvars`.
7. **Criterios de Done (Definition of Done)** — criterios que debe cumplir cada componente para considerarse completo en esta etapa. Debe incluir explícitamente los criterios de TDD: toda funcionalidad fue precedida por una prueba que falló y luego pasó (Red-Green-Refactor); la suite de pruebas está en verde; se cumplen los umbrales de cobertura mínima por capa; no existe lógica de negocio ni rama de error sin prueba asociada.

---

## Etapa 0 — DEV-[proyecto]-00-infrastructure.md

Título H1: `# Etapa 0 — Infraestructura VPS (K3s + Terraform + Helm)`

Secciones en orden exacto:

1. **Objetivo** — descripción breve de lo que se configura en esta etapa: generar `terraform/`, instalar K3s en el VPS y desplegar todo el stack del framework como pods mediante `terraform apply` con el provider Helm.
2. **Prerrequisitos** — VPS Ubuntu 26.04 LTS accesible vía SSH; `terraform >= 1.7`, `kubectl` y la clave SSH (`~/.ssh/id_ed25519`) disponibles localmente. Para `local`: VM QEMU/KVM creada con `qemu-vps.sh create` e instalado Ubuntu; para `prod`: VPS Oracle Cloud OCI aprovisionado.
3. **Paso 0: Provisionar el VPS (pre-requisito local)**
   - Comandos para entorno `local`: `qemu-vps.sh create`, `virsh console sdlc-vps` (instalar Ubuntu 26.04 LTS), `qemu-vps.sh setup --vm-ip <IP>`, `qemu-vps.sh snapshot`.
   - Para `prod` (Oracle Cloud OCI): VPS aprovisionado con Terraform OCI; no se usa `qemu-vps.sh`.
4. **Paso 1: Ejecutar el script de infraestructura base**
   - Comando exacto:
     ```bash
     bash .claude/scripts/base-infrastructure-builder.sh \
       --vm-ip <VPS_IP> --project <nombre-proyecto> \
       --pg-prefix <prefijo> --mongo-prefix <prefijo> \
       --env local
     ```
   - Flags opcionales: `--no-lra`, `--no-wiremock`, `--no-kong`, `--no-minio`, `--no-loki`, `--no-tempo` para omitir componentes no requeridos por el diseño.
   - Descripción de las cuatro fases que ejecuta el script:
     1. **Genera `terraform/`** — estructura completa de módulos Terraform (providers, variables, main, outputs, `environments/local.tfvars` y `prod.tfvars`) usando heredocs; la carpeta no existe previamente.
     2. **Instala K3s** en el VPS vía SSH y descarga el kubeconfig localmente a `~/.kube/config-<proyecto>-local`.
     3. **`terraform init → plan → apply`** — el provider Helm despliega todos los servicios en K3s: PostgreSQL 16 + MongoDB 7 (`data`), Kafka KRaft Strimzi (`messaging`), Keycloak (`identity`), HashiCorp Vault (`secrets`), Gitea + Jenkins + ArgoCD (`cicd`), Kong Gateway (`gateway`), MinIO (`infra`), Narayana LRA + WireMock (`infra`), stack de observabilidad (`observability`).
     4. **Post-apply** — `init-databases.sh` crea las BDs, configura org/repos en Gitea, publica la Jenkins Shared Library.
   - Tabla de módulos Terraform generados (derivada de `technical-design.md`): nombre del módulo → Helm chart → namespace → NodePort.
5. **Paso 2: Verificar el ambiente**
   - Comando exacto: `bash .claude/scripts/init-dev-environment.sh -P <nombre-proyecto> --vm-ip <VPS_IP>`
   - Descripción de qué verifica: K3s nodos Ready, todos los pods Helm en `Running`, Vault unsealed (`vault-init.json` presente), BDs accesibles, Kafka, Gitea, Jenkins, ArgoCD y Keycloak.
   - Tabla de endpoints del VPS tras `base-infrastructure-builder.sh`:

     | Componente | Endpoint NodePort | Namespace |
     |---|---|---|
     | Gitea Package Registry | `http://VPS_IP:3000/[proyecto]` | `cicd` |
     | Jenkins | `http://VPS_IP:8080` | `cicd` |
     | ArgoCD | `http://VPS_IP:8081` | `cicd` |
     | Keycloak | `http://VPS_IP:8082` | `identity` |
     | HashiCorp Vault | `http://VPS_IP:8200` | `secrets` |
     | Kong Proxy | `http://VPS_IP:8000` | `gateway` |
     | MinIO API | `http://VPS_IP:9000` | `infra` |
     | MinIO Console | `http://VPS_IP:9001` | `infra` |
     | Prometheus | `http://VPS_IP:9090` | `observability` |
     | Grafana | `http://VPS_IP:3001` | `observability` |
     | K3s API | `https://VPS_IP:6443` | — |

6. **Paso 3: Variables de entorno base**
   - Tabla de variables de entorno necesarias (`VPS_IP`, `GITEA_REGISTRY=VPS_IP:3000/[proyecto]`, `KUBECONFIG=~/.kube/config-<proyecto>-local`, `VAULT_ADDR=http://VPS_IP:8200`).
   - Indicar cómo leer el root token de Vault: `jq -r '.root_token' vault-init.json`.
7. **Criterios de Aceptación** — lista de verificación (`- [ ]`) para dar esta etapa por completada. Incluir: `base-infrastructure-builder.sh` finaliza las cuatro fases con código 0; `kubectl get nodes` muestra nodos Ready; `kubectl get pods -A` muestra todos los pods del framework en `Running`; Vault unsealed (`vault-init.json` presente); `init-dev-environment.sh` finaliza con checklist ✓; Gitea Package Registry accesible en `VPS_IP:3000`.

---

## Etapa 0c — DEV-[proyecto]-0c-observability.md

Título H1: `# Etapa 0c — Stack de Observabilidad`

**Propósito:** Instalar el stack de observabilidad en el cluster K3s nativo del VPS y documentar la instrumentación que el scaffold aplica automáticamente a cada microservicio. Esta etapa se ejecuta inmediatamente después de la Etapa 0 (`init-dev-environment.sh`) y antes de la Etapa 1 (bases de datos). Los microservicios generados en la Etapa 2 ya incluyen las dependencias, configuraciones y Helm chart modificados — el desarrollador no instrumenta manualmente nada.

**Stack por ambiente:**

| Pilar | Local / VPS (K3s + Helm) | Prod (K3s + Oracle Cloud OCI) |
|---|---|---|
| Trazas | OTEL Collector → Grafana Tempo | OTEL Collector → Grafana Tempo |
| Métricas | Prometheus (`kube-prometheus-stack`) + Grafana | Prometheus (`kube-prometheus-stack`) + Grafana |
| Logs | Promtail DaemonSet → Loki + Grafana | Promtail DaemonSet → Loki + Grafana |
| Alertas | Alertmanager + Grafana Alerts | Alertmanager + Grafana Alerts |

Secciones en orden exacto:

1. **Objetivo y Stack de Observabilidad** — tabla local vs prod; principio central: instrumentación unificada con OpenTelemetry Java Agent (sin cambios en código de dominio) + Micrometer para métricas de aplicación.
2. **Prerrequisitos** — Etapa 0 completa; cluster K3s en VPS corriendo; `kubectl` apuntando a `~/.kube/config-<proyecto>-local`; `base-infrastructure-builder.sh` ya instaló el módulo `helm-observability` con `kube-prometheus-stack`, Loki, Promtail y Grafana Tempo.
3. **Stack de observabilidad (instalado en Etapa 0)**
   - Aclarar que el stack de observabilidad **no requiere un script adicional**: el módulo `modules/helm-observability` es instalado automáticamente por `base-infrastructure-builder.sh` durante el `terraform apply` de la Etapa 0. Esta etapa 0c documenta únicamente la verificación y la instrumentación automática del scaffold.
   - Para omitir componentes opcionales: usar `--no-loki` o `--no-tempo` al invocar `base-infrastructure-builder.sh`.
   - Tabla de endpoints del stack de observabilidad (accesibles por NodePort):

     | Componente | Endpoint VPS / NodePort | Endpoint interno K3s |
     |---|---|---|
     | Prometheus | `http://VPS_IP:9090` | `prometheus-operated.observability:9090` |
     | Grafana | `http://VPS_IP:3001` (admin/changeme) | `kube-prometheus-stack-grafana.observability:80` |
     | Grafana Tempo (gRPC OTEL) | — | `tempo.observability.svc.cluster.local:4317` |
     | Loki | — | `loki.observability:3100` |

   - Indicar que los endpoints se pueden consultar con `terraform output` desde `terraform/`.
4. **Instrumentación de Microservicios Spring Boot (automática vía scaffold)**
   - Aclarar que `maven_hexagonal_scaffold.py` ya genera todos los artefactos de observabilidad sin intervención manual. Esta sección es **referencia** de lo que el scaffold produce:
   - **Dependencias Maven** en el `pom.xml` raíz: `spring-boot-starter-actuator`, `micrometer-registry-prometheus`, `micrometer-tracing-bridge-otel`, `opentelemetry-exporter-otlp`, `logstash-logback-encoder:7.4`.
   - **`application.yml`**: bloque `management` con `endpoints.web.exposure.include: health,readiness,liveness,prometheus,info,metrics` y `metrics.tags` con `application` y `environment`; las variables OTEL (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `JAVA_TOOL_OPTIONS`) se inyectan como env vars en el Helm chart, no en `application.yml`.
   - **`logback-spring.xml`**: perfil no-dev usa `LogstashEncoder` (JSON con `traceId`, `spanId` desde MDC); perfil dev usa `ConsoleAppender` con patrón legible incluyendo `traceId`/`spanId`. Los campos de traza los inyecta automáticamente el bridge Micrometer-OTEL.
5. **Instrumentación de Jobs Spark/Scala (si el diseño incluye reportería)**
   - Si el diseño definió subsistema de reportería, indicar que los jobs Spark/Scala usan el OTEL Java Agent via `JAVA_TOOL_OPTIONS` en el CronJob K8s y métricas vía `spark.metrics.conf` con `PrometheusServlet` en el namespace `monitoring`. Logs: JSON estructurado con `logback-spark.xml` (misma lógica que el backend).
6. **Modificaciones a los Helm Charts (automáticas vía scaffold)**
   - Referencia de lo que genera `maven_hexagonal_scaffold.py` en cada chart:
   - **Pod annotations** en `templates/deployment.yaml` (sección `spec.template.metadata`): `prometheus.io/scrape: "true"`, `prometheus.io/path: "/actuator/prometheus"`, `prometheus.io/port: "{{ .Values.service.port }}"`. El `kube-prometheus-stack` detecta estas annotations y configura el scrape automáticamente.
   - **Init container `otel-agent`**: copia `opentelemetry-javaagent.jar` desde `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest` a un `emptyDir` compartido montado en `/otel`.
   - **Env vars OTEL**: `OTEL_SERVICE_NAME: "{{ .Chart.Name }}"`, `OTEL_EXPORTER_OTLP_ENDPOINT: "{{ .Values.otel.collectorEndpoint }}"`, `OTEL_RESOURCE_ATTRIBUTES: "deployment.environment={{ .Values.env }},service.version={{ .Values.image.tag }}"`, `JAVA_TOOL_OPTIONS: "-javaagent:/otel/opentelemetry-javaagent.jar"`.
   - **`values-dev.yaml`** (y `values-local.yaml`): `otel.collectorEndpoint: http://tempo.observability.svc.cluster.local:4317`.
   - **`values-prod.yaml`**: `otel.collectorEndpoint: http://tempo.observability.svc.cluster.local:4317` (mismo endpoint; Tempo corre en K3s en ambos entornos).
7. **Dashboards y Alertas**
   - **Local y Prod (Grafana)**: importar dashboards JVM Micrometer (ID `4701`) y Spring Boot Statistics (ID `12685`) desde Grafana.com. En Grafana Explore: seleccionar el datasource Tempo para visualizar trazas por `traceId`. Alertas en Alertmanager: error rate > 5 % durante 5 min, P99 latency > 2 s.
   - El módulo `modules/helm-observability` de Terraform gestiona Prometheus, Grafana (con Alertmanager), Loki y Tempo en ambos entornos (`local` y `prod`) — no hay módulo CloudWatch ni X-Ray.
8. **Terraform — Módulo `helm-observability/` (ambos entornos)**
   - Estructura generada por `base-infrastructure-builder.sh`:
     ```
     terraform/modules/helm-observability/
     ├── variables.tf          # grafana_admin_password, install_loki, install_tempo
     └── main.tf               # helm_release: kube-prometheus-stack, loki, promtail, tempo
     ```
   - Los flags `--no-loki` y `--no-tempo` de `base-infrastructure-builder.sh` controlan qué releases se instalan (`count = var.install_loki ? 1 : 0`).
9. **Integración con CI/CD**
   - El step `runSmokeTests` de la Shared Library verifica `/actuator/prometheus` (HTTP 200) además de `/actuator/health/readiness`, confirmando que el endpoint de métricas está activo tras el despliegue.
   - Con auto-sync ArgoCD: verificar que Grafana Explore (datasource Tempo) muestra trazas del servicio tras el primer despliegue exitoso.
10. **Criterios de Aceptación** — lista de verificación (`- [ ]`):
    - `base-infrastructure-builder.sh` desplegó el módulo `helm-observability` sin errores (verificado en la salida del `terraform apply`).
    - `kubectl get pods -n observability` muestra Prometheus, Grafana, Loki, Promtail y Tempo en `Running`.
    - Prometheus (`http://VPS_IP:9090 → Status > Targets`) scrapea `/actuator/prometheus` de todos los microservicios desplegados.
    - Grafana Explore (datasource Tempo, `http://VPS_IP:3001`) muestra la traza del servicio tras una request HTTP.
    - Los logs en Grafana Loki muestran JSON con campos `traceId`, `spanId`, `level`, `service`.

### Reglas para el documento de observabilidad

- Derivar los nombres de los servicios exactamente de los microservicios identificados en el roadmap.
- El endpoint del OTEL Collector/Tempo en `values-local.yaml` y `values-prod.yaml` es `tempo.observability.svc.cluster.local:4317` (igual en ambos entornos; Tempo corre en K3s).
- Describir explícitamente qué hace el scaffold automáticamente (secciones 4 y 6) vs. qué configura el desarrollador manualmente (dashboards en Grafana, alertas en Alertmanager).
- No referenciar `setup-observability.sh` — ese script no existe; el stack de observabilidad lo instala `base-infrastructure-builder.sh`.

---

## Etapa 1 — DEV-[proyecto]-01-databases.md

Título H1: `# Etapa 1 — Bases de Datos y Migraciones`

Secciones en orden exacto:

0. **Automatización** — bloque inicial antes del Objetivo, con el comando de ejecución del script. `init-databases.sh` recibe **cuatro parámetros obligatorios** (no tiene valores por defecto): el prefijo del nombre de las BDs PostgreSQL, el prefijo de las BDs MongoDB y el usuario/clave de aplicación. Mostrar el comando con los valores concretos derivados del diseño:
   ```bash
   bash .claude/scripts/init-databases.sh \
     -P <nombre-proyecto> \
     -p <prefijo-postgres> \
     -m <prefijo-mongo> \
     -u <usuario-app> \
     -w <clave-app>
   ```
   Describir brevemente qué automatiza (patrón **Database-per-Service**): se conecta a PostgreSQL en `postgresql.data.svc.cluster.local:5432` (K3s pod) y a MongoDB en `mongo.data.svc.cluster.local:27017`; por cada microservicio con adaptador `postgres`, crea una BD aislada `<prefijo-postgres>_<servicio_slug>`; por cada uno con adaptador `mongo`, crea `<prefijo-mongo>_<servicio_slug>` con usuario `readWrite` restringido a esa BD. **No aplica `schema.sql` global**: el esquema de cada servicio lo aplica Liquibase standalone (`run-liquibase-migrations.sh`) como paso previo al despliegue; no depende del arranque del servicio. Aclarar que las secciones siguientes son referencia de diseño y para ejecución manual puntual.
1. **Objetivo** — crear las bases de datos aisladas por servicio que el sistema requiere (patrón Database-per-Service).
2. **Estrategia de Persistencia** — resumen de la decisión: **Database-per-Service** (cada microservicio posee su propia BD, sin acceso a las BDs de otros servicios) con persistencia políglota (PostgreSQL transaccional + MongoDB auditoría). Documentar la convención de nombres: `<prefijo>_<servicio_slug>` (ej. `mydb_clientes_service`). Referencia a los archivos de diseño.
3. **PostgreSQL — Esquema Relacional**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-schema.sql`
   - Tabla de bounded contexts con sus tablas correspondientes
4. **PostgreSQL — Changelogs Liquibase por Microservicio**
   - Para cada microservicio que usa PostgreSQL: los changelogs residen en el repo Git dedicado **`<proyecto>-migrations`** en Gitea del VPS (`http://VPS_IP:3000/<proyecto>/<proyecto>-migrations`); se generan localmente en `db/<servicio>/changelog/` y el scaffold hace push automático (fuera del JAR — Liquibase corre standalone)
   - Nomenclatura obligatoria: `00001_initial_schema.yaml`, `00002_...yaml`, etc.; changelog maestro `root.yaml` los incluye en orden
   - Tabla indicando qué tablas pertenecen a qué microservicio y en qué changeSet de migración deben estar
   - Regla de propiedad: cada tabla es propiedad de exactamente un microservicio; ningún otro servicio hace DDL sobre ella
   - Regla Database-per-Service: los changelogs de cada servicio aplican sobre **su propia BD** (`<prefijo>_<servicio_slug>`), no sobre una BD compartida; Liquibase los aplica ejecutando `run-liquibase-migrations.sh --gitea-clone` (clona el repo `<proyecto>-migrations` desde Gitea automáticamente) previo al despliegue; alternativamente `--db-dir <ruta>` si ya está clonado localmente
5. **MongoDB — Colecciones y Validadores**
   - Referencia al archivo `docs/design/database/SDD-[proyecto]-collections.js`
   - Tabla de colecciones con su propósito y bounded context
6. **Criterios de Aceptación** — lista de verificación para dar esta etapa por completada. Incluir como primer criterio: `bash .claude/scripts/init-databases.sh` (con sus cuatro parámetros obligatorios `-p`, `-m`, `-u`, `-w`) finalizó con checklist ✓ y cada servicio tiene su propia BD aislada (`<prefijo>_<servicio_slug>`).

---

## Etapa 2 — DEV-[proyecto]-02-scaffold.md

Título H1: `# Etapa 2 — Scaffolding de Proyectos`

Secciones en orden exacto:

1. **Objetivo** — generar la estructura base de todos los proyectos.
2. **Scaffolding de Microservicios y Frontend**
   - Referenciar el script `.claude/scripts/scaffold-all-services.sh` y explicar que es genérico: acepta `--backend nombre:db:messaging:puerto` (repetible), `--frontend nombre` (opcional) y `--bc-tags servicio=BC-XX` (repetible, opcional). No incluir comandos `python3` individuales.
   - Bloque de ejemplo con la invocación completa del script con todos los `--backend`, `--frontend`, los cuatro parámetros de BD (`-p <pg-db>`, `-m <mongo-db>`, `-u <usuario>`, `-w <clave>`, **idénticos** a los usados en `init-databases.sh`) y `--bc-tags` derivados del diseño técnico. Los `--bc-tags` deben incluirse para todos los servicios PostgreSQL, usando el tag `BC-XX` que corresponde a su bloque en `docs/design/database/SDD-[proyecto]-schema.sql`.
   - Si el diseño definió capa de integración u orquestación de saga, incluir además: `--integration-service "<sistema=BC-XX,...>"` (genera el `integration-service` con sus rutas Camel), `--saga-flows <flujo1,flujo2>` (un orquestador por flujo), y, por cada servicio de dominio participante, `--saga-participant <servicio>` y `--outbox <servicio>` (generan el consumidor de comandos de saga, el endpoint de compensación, el módulo outbox y el changelog Liquibase `00003_outbox.yaml` en el repo `<proyecto>-migrations` de Gitea).
   - Si el diseño definió **subsistema de reportería con CQRS**, incluir además:
     - `--backend reporting-projection-service:postgres:kafka-consumer:<puerto>` (Projection Service, Spring Boot reactivo; Kafka consumer + R2DBC PostgreSQL; generado con `maven_hexagonal_scaffold.py`; conecta a `<pg-prefix>_readmodel` — `create-all-secrets-vault.sh` lo detecta por el patrón `*projection*` y le asigna esa BD). Es el **único escritor** del read model PostgreSQL.
     - `--report-extraction <svc>:jdbc:<topic-out>` (**ETL unificado**, Spark; `--source jdbc` lee el read model PostgreSQL `<pg-prefix>_readmodel` vía `SparkJdbcSourceAdapter`; hace extracción + validación de esquema + transformación (Factory DR-10) en un solo job CronJob; publica `ReportParquetGenerated`; recibe `--pg-db <pg-prefix>` para derivar `<prefix>_readmodel` y `<prefix>_reporting`; `--report-types <lista>` registra un `ReportTransformer` por tipo en la Factory).
     - `--report-formats pdf,xls,csv` (capa serverless: OpenFaaS Function Kafka Consumer que lee `ReportParquetGenerated` y genera el archivo final; desplegada con Helm en K3s, generada con `report_lambdas_scaffold.py`).
     - El ETL unificado se genera con `scala_hexagonal_scaffold.py` (no Maven); compila/ensambla con sbt. El Projection Service se genera con Maven scaffold. **No hay un segundo MS Spark separado** para procesamiento.
   - Tabla resumen: servicio → puerto local → DB → mensajería → módulos generados.
   - Indicar si el servicio usa mensajería (kafka-producer / kafka-consumer / ambos / none).
   - Documentar los artefactos que produce el scaffold y que consume la Etapa 2b: `Jenkinsfile` (backend y frontend), `Dockerfile` multi-stage (backend) y charts Helm (`helm/<service>/`)
   - **Observabilidad (automática):** el scaffold genera adicionalmente `logback-spring.xml` (JSON estructurado con `traceId`/`spanId` en el MDC), añade las dependencias `micrometer-registry-prometheus`, `micrometer-tracing-bridge-otel`, `opentelemetry-exporter-otlp` y `logstash-logback-encoder` al `pom.xml` raíz, configura el bloque `management` en `application.yml` con los endpoints de Actuator, e incorpora en el Helm chart las annotations de Prometheus, el init container del OTEL Java Agent y las variables de entorno OTEL. El desarrollador no instrumenta observabilidad manualmente.
   - Indicar que, en dev, cada scaffold (`maven_hexagonal_scaffold.py` / `nextjs_feature_scaffold.py`) además **crea el repositorio en Gitea** (en `http://VPS_IP:3000/[proyecto]/`) y **hace push automático de la rama `main`** usando las credenciales fijas `gitea-admin:gitea-admin`. La URL que consumen Jenkins/ArgoCD es `http://VPS_IP:3000/[proyecto]/<servicio>.git`.
   - **Backend `Jenkinsfile` (Spring Boot / Maven)**: tabla de stages con el step de la shared library: `computeImageTag`, `buildBackendService`, `runIntegrationTests`, `runQualityGates`, `runSecurityScans`, `buildAndPushImage` (push a **Gitea Package Registry** `VPS_IP:3000/[proyecto]` en local / **OCIR** en prod), `scanImage`, `bumpImageTag`, `runSmokeTests`, `notify`. El pod se carga desde `org/[proyecto]/podBackend.yaml` (contenedor `maven`); corre en K3s del VPS en ambos entornos.
   - **Batch `Jenkinsfile` (Spark / Scala)**: para los servicios generados por `scala_hexagonal_scaffold.py` el pipeline es CI puro sin smoke tests (los batch jobs no exponen endpoints HTTP). Stages: `computeImageTag`, `buildScalaBatchJob`, `runQualityGates(projectType:'sbt')`, `runSecurityScans(projectType:'sbt')`, `buildAndPushImage` (Gitea registry), `scanImage`, `bumpImageTag`, `notify`. El pod se carga desde `org/[proyecto]/podScalaBatch.yaml` (contenedor `sbt`; sin sidecar dind). El `bumpImageTag` actualiza `helm/<service>/values-<env>.yaml` y ArgoCD sincroniza el **CronJob** (no un Deployment).
   - **Frontend `Jenkinsfile`**: tabla de stages (Install, Type Check, Lint, Unit Tests, Build, `docker build`, push a **Gitea Package Registry**, `bumpImageTag`, ArgoCD sync → pod K3s con Ingress Traefik, E2E Tests, Notify). Indicar que **el frontend despliega como pod en K3s** (no a Vercel); el Helm chart generado por `base-infrastructure-builder.sh` se encuentra en `terraform/frontend/chart/`.
   - **`Dockerfile` backend (Maven)**: imagen multi-stage (builder `maven:3.9-eclipse-temurin-21` + runtime `eclipse-temurin:21-jre-alpine`); Kaniko lo usa sin Docker daemon.
   - **`Dockerfile` batch (Scala/sbt)**: imagen multi-stage con **caché de deps SBT** (Stage 1: `sbt update` con `build.sbt`+`project/` → Stage 2: `sbt "entryPoints/assembly"` → Stage 3: runtime `eclipse-temurin:17-jre-jammy` con fat JAR).
   - **Helm charts `helm/<service>/`**: servicios Maven → `templates/deployment.yaml` (Deployment + Service + readiness/liveness probes); servicios Scala → `templates/cronjob.yaml` (CronJob con `concurrencyPolicy: Forbid`, `restartPolicy: Never`). En ambos casos `values-local.yaml`/`values-prod.yaml` tienen los campos `image.repository`/`image.tag` que escribe `bumpImageTag` y lee ArgoCD.
 3. **Generación de Changelogs Liquibase** — indicar explícitamente que estas secciones son **ejecutadas de forma automática por `scaffold-all-services.sh`** como pasos 5, 6 y 6b del script, inmediatamente después del scaffold (cuando los directorios de los servicios ya existen); la sección es informativa de lo que el script hace, no pasos manuales. Los changelogs se generan localmente en `db/<servicio>/changelog/` y se publican en el repo Git dedicado **`<proyecto>-migrations`** en Gitea del VPS, fuera del JAR — Liquibase corre standalone, nunca embebido (Flyway requiere JDBC bloqueante, incompatible con R2DBC):
    - **Paso 5 — changelog inicial por microservicio**: para cada servicio incluido en `--bc-tags`, extrae el bloque `-- BC-XX:` correspondiente del `schema.sql` y lo escribe en `db/<servicio>/changelog/00001_initial_schema.yaml` como changeSet Liquibase; si el archivo ya existe lo omite (idempotente); si no se pasó `--bc-tags`, este paso se salta.
    - **Paso 6 — seed de seguridad-service**: si `backend/seguridad-service` existe, genera `db/seguridad-service/changelog/00002_seed_roles.yaml` con los 7 roles del sistema, permisos por bounded context y el mapeo `roles_permisos`; si el archivo ya existe lo omite.
    - **Paso 6b — repo `<proyecto>-migrations` en Gitea**: crea el repo `<proyecto>-migrations` bajo la org del proyecto en Gitea (`POST /api/v1/orgs/<proyecto>/repos`, idempotente — HTTP 409 no es error), hace `git init -b main` en el directorio local de changelogs, commit inicial y `git push` a `http://VPS_IP:3000/<proyecto>/<proyecto>-migrations`; si Gitea no responde, registra el comando manual y continúa sin fallar.
    - Estructura de directorios esperada por proyecto (referencia)
 4. **Verificación Post-Scaffolding** — indicar explícitamente que estas verificaciones son **ejecutadas de forma automática por `scaffold-all-services.sh`** como pasos 9 y 10 del script; la sección es informativa de lo que el script hace, no pasos manuales:
    - **Paso 9 — Compilación backend** (`compile-services.sh`): detecta todos los directorios `*-service` en `backend/` con `find`, ejecuta `mvn -q -DskipTests package` en cada uno, reporta OK/FALLA por servicio y sale con código 1 si algún servicio falla
    - **Paso 10 — Verificación frontend** (`verify-frontend.sh`): detecta los proyectos en `frontend/`, ejecuta `npm install`, `npm run type-check` y `npm run lint`; se omite si no se pasó `--frontend` al script
 5. **Configuración Inicial Post-Scaffold** — indicar que el script ejecuta automáticamente el paso 11 (`create-all-secrets-vault.sh`); **no hay ajuste manual posterior**: el script es completamente autónomo:
    - **Paso 11 — Secrets en HashiCorp Vault** (`create-all-secrets-vault.sh`, **automático, sin edición manual**): recibe de `scaffold-all-services.sh` los parámetros de BD y `--vps-ip`; lee el root token de Vault desde `vault-init.json`; detecta el tipo de BD de cada servicio inspeccionando `infrastructure/driven-adapters/`; aplica **Database-per-Service**: por cada servicio deriva su BD propia como `<pg-prefix>_<servicio_slug>` (postgres en `postgresql.data.svc.cluster.local:5432`) o `<mongo-prefix>_<servicio_slug>` (mongo en `mongo.data.svc.cluster.local:27017`); inyecta `KEYCLOAK_URL`, `KEYCLOAK_JWKS_URI` y `VAULT_ADDR`; Kafka bootstrap en `kafka-kafka-bootstrap.messaging.svc.cluster.local:9092`; escribe en Vault KV v2 bajo `secret/<proyecto>/<env>/<servicio>`; re-ejecutar en cualquier momento actualiza los valores; **no usar un loop con nombres hardcodeados**.
    - Documentar el override puntual: `bash .claude/scripts/create-all-secrets-vault.sh -P <proyecto> --vm-ip <VPS_IP> --pg-prefix <prefijo> --mongo-prefix <prefijo>`
    - Crear `frontend/<proyecto>/.env.local` con los outputs de Terraform: `KEYCLOAK_URL=http://VPS_IP:8082`, `KEYCLOAK_REALM=<proyecto>`, `NEXT_PUBLIC_API_BASE_URL=http://VPS_IP:8000` (vía Kong proxy)
 6. **Re-aplicar Infraestructura Terraform** — indicar que el script ejecuta automáticamente los pasos 12 y 13; la sección documenta qué hace cada paso:
    - Explicar que `maven_hexagonal_scaffold.py` edita automáticamente `terraform/environments/local.tfvars` (y `prod.tfvars`) agregando el nombre del servicio a la lista `services = [...]` que alimenta `module.helm_cicd`; la edición ocurre en ambos entornos pero **solo `local` se aplica en esta etapa**; `prod` se aprovisiona vía CI/CD.
    - **Paso 12 — Terraform apply** (**automático**): el script ejecuta `terraform apply -auto-approve -var-file=environments/local.tfvars` desde `terraform/`
    - **Paso 13 — Verificación Gitea Package Registry + secrets Vault** (**automático**): el script verifica que `VPS_IP:3000/[proyecto]` es accesible y lista secretos con `kubectl exec -n secrets vault-0 -- vault kv list secret/<proyecto>/local`; criterio: una entrada `secret/<proyecto>/local/<servicio>` en Vault por cada microservicio generado.
 7. **Criterios de Aceptación** — lista de verificación; el criterio principal es `bash .claude/scripts/scaffold-all-services.sh finalizó los 13 pasos con código de salida 0`. Incluir también: `00001_initial_schema.yaml generado en db/<svc>/changelog/ para cada servicio PostgreSQL (paso 5)`, `00002_seed_roles.yaml generado en db/seguridad-service/changelog/ (paso 6)`, `db/<svc>/liquibase.properties existe para cada servicio PostgreSQL`, `repo <proyecto>-migrations accesible en http://VPS_IP:3000/<proyecto>/<proyecto>-migrations (paso 6b)`, `Gitea Package Registry accesible en VPS_IP:3000/[proyecto]`, `Los secrets secret/<proyecto>/local/<servicio> existen en Vault (verificado en paso 13)`, `.env.local del frontend creado con KEYCLOAK_URL y NEXT_PUBLIC_API_BASE_URL`.

---

## Etapa 2b — DEV-[proyecto]-02b-cicd.md

Título H1: `# Etapa 2b — Configuración del Pipeline CI/CD`

**Propósito:** Esta etapa se ejecuta inmediatamente después del scaffold y antes de comenzar cualquier microservicio. El objetivo es que cada commit de las etapas 3 y 4 sea validado automáticamente por el pipeline: build, tests, quality gate, imagen y actualización del estado GitOps. Jenkins hace CI; ArgoCD hace CD por GitOps.

Secciones en orden exacto:

1. **Objetivo** — describir que el CI/CD se configura antes de la implementación para validar el código a medida que se genera. Indicar el modelo: Jenkins CI → `bumpImageTag` → ArgoCD CD (auto-sync local; manual prod). Incluir un diagrama ASCII del flujo: `git push → Jenkins stages → helm/<service>/values-<env>.yaml → ArgoCD → K3s cluster` (K3s corre en el VPS en ambos entornos: QEMU/KVM local u Oracle Cloud OCI prod).
2. **Prerrequisitos** — Etapa 2 completa (Jenkinsfile + Dockerfile + Helm charts generados). En local: cluster K3s en VPS levantado (Etapa 0); Jenkins corre como **pod K3s** en namespace `cicd` (instalado por `base-infrastructure-builder.sh`, accesible en `VPS_IP:8080`); ArgoCD instalado en K3s. En prod: módulo `helm-cicd` aplicado sobre K3s en Oracle Cloud OCI.
0. **Ejecución automatizada (recomendado)**
   - El script `.claude/scripts/setup-cicd-pipeline.sh` unifica todos los pasos de esta etapa en secciones ejecutables. Cada sección es una función autocontenida que valida prerequisitos, ejecuta comandos, verifica resultados y reporta variables pendientes.
   - Invocación: `bash .claude/scripts/setup-cicd-pipeline.sh -P <nombre-proyecto> -S <svc1,svc2,...> --vps-ip <VPS_IP> [-F <frontend>]` (por defecto ejecuta todas las secciones en orden; editar `main()` para control manual).
   - Secciones: 0 (Shared Library) → 1 (Imagen controller → Gitea registry) → 2 (Bootstrap cluster K3s) → 3 (JCasC → verificar pod Jenkins en K3s) → 4 (Jobs Jenkins) → 5 (Bootstrap ArgoCD) → 6 (Verificación pipeline).
   - **En local el script es completamente autónomo: no requiere intervención manual.** La Sección 3 **verifica que el pod Jenkins esté en `Running` en el namespace `cicd`** y autocompleta `SONAR_URL`/`SONAR_TOKEN`, `GITOPS_GIT_USERNAME`/`GITOPS_GIT_TOKEN` con `gitea-admin`/`gitea-admin`, y lee el token de Vault desde `vault-init.json` para la credencial `vault-token`; la Sección 4 **crea los jobs** en el controller vía `/scriptText` y **crea los webhooks en Gitea** (push + pull_request) apuntando a `http://VPS_IP:8080`; la Sección 6 verifica jobs y webhooks. Slack (`SLACK_TEAM`/`SLACK_TOKEN`) es **opcional en local** (`notify` hace fallback a `echo`) y obligatorio solo en prod. **No hay variables Vercel** en ningún ambiente.
   - Los pasos siguientes documentan lo que cada sección del script realiza; pueden ejecutarse manualmente o delegarse al script unificado.
3. **Paso 1: Generar la Shared Library**
   - Comando directo: `bash .claude/scripts/jenkins-shared-library-builder.sh -P <nombre-proyecto> -o jenkins-shared-library`
   - Comando vía script unificado: `bash .claude/scripts/setup-cicd-pipeline.sh -P <nombre-proyecto> -S <svc1,svc2,...> [-F <frontend>]` (Sección 0)
   - Árbol de directorios generado: `vars/` (11 steps), `src/org/[proyecto]/PipelineDefaults.groovy`, `resources/org/[proyecto]/podBackend.yaml`, `podFrontend.yaml` y `podScalaBatch.yaml`, `bootstrap/jenkins-agent-rbac.yaml`, `docker/` (Dockerfile + plugins.txt + jenkins.yaml JCasC)
   - Tabla de steps de `vars/`: nombre del archivo → stage del pipeline que invoca → descripción. Incluir `buildScalaBatchJob.groovy` (batch Spark: `sbt clean test` + `sbt "entryPoints/assembly"`) junto a `buildBackendService.groovy` (Maven). Los steps `runQualityGates` y `runSecurityScans` aceptan `projectType: 'sbt'` para usar `sbt sonarScan` y `sbt dependencyCheckAggregate` respectivamente (default `'maven'`). El step `notify` trata Slack como **opcional**: si `SLACK_TEAM` está vacío (caso dev) registra el resultado en el log y no falla el build
   - Lista de plugins del controller (`docker/plugins.txt`) — incluir `multibranch-scan-webhook-trigger` (habilita el endpoint `/multibranch-webhook-trigger/invoke?token=<job>` que dispara el escaneo del multibranch desde el webhook de Gitea)
   - **En dev** `jenkins-shared-library-builder.sh` **crea el repo `[proyecto]/jenkins-shared-library` en Gitea** (en `http://VPS_IP:3000/[proyecto]/`) **y hace push automático de `main`** con `gitea-admin:gitea-admin`; no hay `git push` manual. La URL que usa Jenkins como `SHARED_LIBRARY_REPO` es `http://VPS_IP:3000/[proyecto]/jenkins-shared-library.git`.
4. **Paso 2: Construir y publicar la imagen del controller**
   - **local (VPS):** `docker build` de la imagen `[proyecto]-jenkins:latest` + push al **Gitea Package Registry** (`VPS_IP:3000/[proyecto]/[proyecto]-jenkins:latest`). Jenkins corre como pod K3s en namespace `cicd`; el pod se actualiza con `kubectl rollout restart deployment/jenkins -n cicd`. En prod se repite el mismo proceso contra el K3s de Oracle Cloud OCI.
5. **Paso 3: Bootstrap del cluster (namespace + ServiceAccount)**
   - prod (K3s en Oracle Cloud OCI): sustituir `<JENKINS_AGENT_ROLE_ARN>` con el output Terraform correspondiente y aplicar `kubectl apply -f jenkins-shared-library/bootstrap/jenkins-agent-rbac.yaml`.
   - **local (K3s en VPS, sin IRSA)**: `kubectl --kubeconfig ~/.kube/config-<proyecto>-local apply -f terraform/environments/argocd-bootstrap/jenkins-agent-rbac-local.yaml` (namespace `jenkins` + SA `jenkins-agent` + Role/RoleBinding para smoke tests).
   - Verificación: `kubectl get namespace jenkins` y `kubectl get serviceaccount jenkins-agent -n jenkins`
6. **Paso 4: Proveer variables de entorno y credenciales al controller (JCasC)**
   - Tabla de variables de entorno inyectadas al controller: `GITEA_REGISTRY` (en local = `VPS_IP:3000/[proyecto]`), `K3S_API_SERVER` (en local = `https://VPS_IP:6443`), `K3S_CLUSTER_NAME` (en local = `k3s-[proyecto]-local`), **`REGISTRY_INSECURE`** (local=`true`: Kaniko/Trivy contra registry HTTP Gitea), **`SMOKE_USE_INCLUSTER`** (local=`true`: smoke tests in-cluster), `JENKINS_URL` (`http://VPS_IP:8080`), `JENKINS_TUNNEL` (`VPS_IP:50000`), `VAULT_ADDR` (`http://vault.secrets.svc.cluster.local:8200`), `SHARED_LIBRARY_REPO`, `SONAR_URL`, `SLACK_TEAM`, `GITOPS_GIT_USERNAME`, `GITOPS_GIT_TOKEN`; fuente de cada variable. En prod `REGISTRY_INSECURE`/`SMOKE_USE_INCLUSTER` quedan en `false`. **No hay variables `VERCEL_*`, `ECR_*`, `COGNITO_*` ni `AWS_REGION`** (no se usa AWS en ningún ambiente).
   - **Auto-relleno en local:** `SONAR_URL`/`SONAR_TOKEN` se leen desde el pod SonarQube en K3s; `GITOPS_GIT_USERNAME`/`GITOPS_GIT_TOKEN` toman por defecto `gitea-admin`/`gitea-admin`; `vault-token` se lee de `vault-init.json`; `SLACK_TEAM`/`SLACK_TOKEN` son **opcionales**.
   - Tabla de credenciales gestionadas por el JCasC: `sonar-token`, `slack-token` (opcional en local), `k3s-kubeconfig` (en local = `~/.kube/config-<proyecto>-local`), `gitea-registry-credentials` (en local = `gitea-admin`/`gitea-admin`), `gitops-git-credentials`, `vault-token` (root token leído de `vault-init.json`).
7. **Paso 5: Crear los jobs de pipeline en Jenkins y los webhooks de Gitea**
   - Tipo de job: Multibranch Pipeline; cada job recibe un trigger del plugin `multibranch-scan-webhook-trigger` con `token=<repo>`
   - Tabla de jobs a crear: job name → repositorio → `SERVICE_NAME` por defecto
   - Configuración de cada job: Branch Sources, Build Configuration, Scan Triggers (webhook + periódico)
   - **En dev (automático):** la Sección 4 aplica el script Groovy de jobs en el controller vía `/scriptText` (auth anónima = admin, con crumb + cookie) y luego **crea un webhook por cada repo de la org en Gitea** (eventos `push` + `pull_request`) apuntando a `http://VPS_IP:8080/multibranch-webhook-trigger/invoke?token=<repo>` (idempotente: omite los que ya existen; excluye `jenkins-shared-library`). No hay configuración manual de jobs ni de webhooks en dev.
   - **En prod (manual):** se aplica el script Groovy con `JENKINS_TOKEN` vía REST API (o `Manage Jenkins → Script Console`) y se configuran los webhooks en Gitea del VPS prod con los eventos `push` y `pull_request`.
8. **Paso 6: Bootstrap de ArgoCD (ApplicationSet por servicio)**
   - Comandos: `kubectl apply -f terraform/environments/argocd-bootstrap/` (en local, anteponer `--kubeconfig ~/.kube/config-<proyecto>-local`). Se genera para ambos entornos.
   - Indicar que el `ApplicationSet` usa un **Git generator** sobre el repo `<proyecto>-helm-charts` en Gitea (`http://VPS_IP:3000/[proyecto]/<proyecto>-helm-charts`), auto-descubriendo charts en `charts/*`; `maven_hexagonal_scaffold.py` añade el chart de cada servicio a ese repo automáticamente.
   - Tabla de política de sync por ambiente: `dev`/`staging` → automated (prune + selfHeal); `prod` → sync manual en UI de ArgoCD
   - Verificación: `kubectl get applications -n argocd` (o `argocd app list`)
9. **Verificación del pipeline completo**
   - Hacer un commit trivial en el primer microservicio (el que no tiene dependencias externas)
   - Checklist de stages que deben aparecer como exitosos en Jenkins
   - Verificar que el app en ArgoCD queda en estado `Synced` tras el pipeline
10. **Criterios de Aceptación** — lista de verificación. En local, los criterios que `setup-cicd-pipeline.sh` resuelve de forma automática (push de la shared library a Gitea, credenciales Jenkins con `SONAR_*`/`GITOPS_*`/`vault-token` autocompletados, pod Jenkins en `Running`, jobs multibranch creados, webhooks de Gitea creados) deben marcarse como ✓ automáticos; quedan como pendientes manuales el commit trivial de verificación end-to-end y el estado `Synced` en ArgoCD. En prod estos pasos son manuales (□).

### Reglas para el documento de CI/CD

- Derivar los nombres de los jobs exactamente de la lista de microservicios identificados en el roadmap.
- La tabla de variables de entorno del JCasC debe listar todas las variables que usa `docker/jenkins.yaml`; no omitir ninguna (incluir `SLACK_TEAM`).
- El diagrama ASCII del flujo CI/CD (sección Objetivo) debe mostrar la frontera CI→CD claramente: Jenkins escribe en Git, ArgoCD lee de Git.
- Indicar explícitamente que el frontend **despliega como pod en K3s** (Ingress Traefik) — **no a Vercel**; ArgoCD gestiona el frontend igual que los microservicios.
- El paso de bootstrap de ArgoCD debe ser posterior a que el cluster esté disponible: K3s está en el VPS (Etapa 0) en ambos entornos (`local` y `prod`).
- Distinguir claramente el flujo **local (totalmente automatizado por `setup-cicd-pipeline.sh`)** del flujo **prod (manual)**: en local Jenkins corre como pod K3s en namespace `cicd`, los jobs se crean vía `/scriptText`, los webhooks se crean en Gitea, Slack es opcional, las credenciales Sonar/GitOps/Vault se autocompletan; en prod se requiere `JENKINS_TOKEN` y configuración manual de webhooks en el SCM.

---

## Etapa 3 — DEV-[proyecto]-03-ms-[servicio].md (uno por microservicio)

Título H1: `# Etapa 3 — Microservicio: [Nombre del Servicio]`

Secciones en orden exacto:

1. **Contexto y Responsabilidad**
   - Bounded context que implementa
   - Responsabilidad principal
   - Dependencias de otros microservicios (REST entrante y saliente)
   - Dependencias de infraestructura (BD, Kafka topics)
2. **Prerrequisitos**
   - Etapas anteriores que deben estar completas
   - Servicios que deben estar corriendo
3. **Ciclo de Desarrollo Incremental en K3s VPS dev**
   - Explicar que con la Etapa 2b completada, cada commit que pasa el pipeline CI despliega automáticamente el microservicio en el cluster K3s del VPS vía ArgoCD, sin necesidad de terminar la implementación completa.
   - Tabla de condición mínima para el primer despliegue: contexto Spring arranca sin errores (`Started ...Application in X seconds`), `/actuator/health/readiness` responde `UP` (`readinessProbe` del chart Helm pasa), secret `secret/<proyecto>/local/<servicio>` existe en Vault (K3s namespace `secrets`).
   - Indicar que esta condición se cumple con el esqueleto generado por el scaffold más la configuración del `application.yml`; no requiere ningún caso de uso implementado.
   - Diagrama ASCII del ciclo por caso de uso: `Implementar caso de uso → mvn test (local) → git push → Jenkins pipeline → push Gitea registry → bumpImageTag → ArgoCD sync → K3s VPS → endpoint disponible`
   - Indicar que cada caso de uso que se implementa y pushea queda disponible en K3s VPS sin intervención manual.
   > **Cada capa se implementa bajo TDD (Red-Green-Refactor): la prueba descrita en la Sección 8 para esa capa se escribe y se ve fallar ANTES de implementar el código de producción.** Las secciones 4 a 7 describen QUÉ implementar; la prueba que precede a cada elemento está especificada en la Sección 8.
4. **Capa de Dominio (`domain`)** — _test-first: la prueba de cada invariante/regla precede a su implementación_
   - Entidades a implementar (derivadas del schema.sql y el diseño): nombre, campos clave, reglas de negocio
   - Value Objects relevantes
   - Eventos de dominio (nombre del evento, payload mínimo)
   - Interfaces de puertos secundarios (repository interfaces, messaging ports): firma de los métodos
   - Reglas de dominio a validar (invariantes)
5. **Capa de Aplicación (`application`)** — _test-first: el test del caso de uso (puertos mockeados) precede al use case_
   - Tabla de casos de uso: nombre del use case, descripción, puerto primario que expone, puerto secundario que consume
   - DTOs de entrada y salida por caso de uso
   - Flujo de orquestación para los casos de uso más importantes
6. **Capa de Infraestructura (`infrastructure`)** — _test-first: el test con Testcontainers precede al adaptador_
   - Adaptadores R2DBC: tablas que gestiona, operaciones a implementar
   - Productores Kafka: tópicos, estructura del evento, cuándo se publica
   - Consumidores Kafka (si aplica): tópicos que consume, lógica de procesamiento
   - Clientes REST (WebClient): servicios externos a llamar, endpoints, contrato esperado
   - Configuración de Spring Security para este servicio
7. **API REST (`rest-api`)** — _test-first: el test con WebTestClient (contrato HTTP) precede al endpoint_
   - Tabla de endpoints: método, ruta, descripción, request body, response, códigos HTTP
   - Referencia a la especificación OpenAPI para el contrato completo
   - Configuración de rutas en Router Functions o `@RestController`
8. **Especificación TDD por Capa (Red-Green-Refactor)**
   - Encabezar la sección recordando la regla: cada prueba se escribe y se ve **fallar (Red)** antes de escribir el código de producción que la hace **pasar (Green)**, seguido de **Refactor**. Los tipos reactivos se verifican con **StepVerifier**, no con `block()`.
   - **Dominio**: tabla con nombre de la clase de test, método de test, invariante/regla que valida, y el elemento de la Sección 4 que esta prueba precede
   - **Aplicación**: tabla con clase de test, método de test, escenario (happy path + cada caso de error), puertos secundarios mockeados con Mockito, y el use case de la Sección 5 que precede
   - **Infraestructura**: pruebas de adaptadores con Testcontainers (PostgreSQL o MongoDB real); clase de test, método, operación que valida, y el adaptador de la Sección 6 que precede
   - **REST**: pruebas de contrato con WebTestClient; clase de test, método, endpoint y status/body esperado que precede al elemento de la Sección 7
   - Tabla de cobertura mínima esperada por capa (umbral verificable; p. ej. dominio ≥ 90%, aplicación ≥ 85%)
9. **Criterios de Aceptación** — lista de verificación. Incluir como criterios de TDD: cada elemento de cada capa tuvo su prueba escrita primero (Red) y luego pasó (Green); `mvn test` finaliza en verde; la cobertura por capa cumple los umbrales declarados; no hay caso de uso ni rama de error sin prueba.

### Reglas para los documentos de microservicio

- Derivar las entidades exactamente de las tablas asignadas a ese bounded context en `docs/design/database/SDD-[proyecto]-schema.sql`.
- Derivar los endpoints exactamente de los paths del bounded context en `docs/design/api/SDD-[proyecto]-openapi.yaml`.
- Derivar las dependencias REST del diseño de flujos técnicos en `SDD-[proyecto]-design.md`.
- Los tópicos Kafka deben seguir el patrón `[proyecto].[bounded-context].[evento]` (ej: `[proyecto].originacion.solicitud-radicada`).
- El orden de implementación dentro del documento es **test-first por capa** (TDD Red-Green-Refactor): dominio → aplicación → infraestructura → rest-api, y dentro de cada capa la prueba se escribe y se ve fallar antes del código de producción. No se documenta una fase de "pruebas al final": las pruebas conducen la implementación de cada capa.
- Indicar explícitamente el orden de microservicios a implementar en el roadmap según dependencias (los servicios sin dependencias externas primero).

### Reglas para el documento del `integration-service` (capa de integración + orquestador de saga)

Generar `DEV-[proyecto]-03-ms-integration-service.md` solo si el diseño definió capa de integración dedicada u orquestación de saga. Mantiene la estructura de Etapa 3 con estas particularidades:

- **Scaffolding:** referenciar el scaffolder dedicado `.claude/templates/integration_service_scaffold.py` (no `maven_hexagonal_scaffold.py`); el comando se documenta en la Etapa 2 (`02-scaffold.md`) vía la bandera `--integration-service` de `scaffold-all-services.sh`. El scaffold genera automáticamente `db/integration-service/changelog/00001_initial_schema.yaml` con el DDL exacto de `saga_instance` y `saga_step_log` (no es placeholder: estas tablas son infraestructura de saga, siempre iguales). El prefijo de BD proviene del mismo `--pg-db-prefix` que se pasa a `init-databases.sh` e `init-databases.sh`; si se omite, usa el `--org`.
- **Capa de dominio:** puertos `<Sistema>Gateway` (uno por sistema externo) y `SagaCoordinatorPort`, todos reactivos (`Mono`/`Flux`), sin tipos de Camel ni LRA.
- **Capa de aplicación:** un `SagaOrchestratorUseCase` por flujo de saga; define la secuencia de pasos y sus compensaciones invocando puertos mockeables.
- **Capa de infraestructura:** adaptadores Camel (`camel-rest-consumer`) que implementan los `*Gateway` con rutas Camel (ACL, reintentos, circuit breaker Resilience4j); adaptador `saga-camel` que implementa `SagaCoordinatorPort` con Camel Saga EIP + cliente Narayana LRA; persistencia R2DBC del estado de saga (`saga_instance`, `saga_step_log`); productor Kafka de comandos y consumidor de respuestas de participantes.
- **TDD (Sección 8):** el adaptador Camel se prueba con **WireMock** + `camel-test-spring-junit5` + StepVerifier (incluyendo escenarios de timeout/error para validar la resiliencia); la saga se prueba con happy path y con fallo que dispara compensaciones en orden inverso. Tipos reactivos siempre con StepVerifier.
- **Prerrequisitos:** coordinador Narayana LRA corriendo (Etapa 0) y los participantes con sus endpoints/consumidores de compensación disponibles (o dobles de prueba).

### Reglas para servicios de dominio que **participan** en una saga

En el documento de cada microservicio participante, añadir:

- En la **capa de infraestructura**: módulo `outbox` (escritura del evento atómica con el cambio de BD en la misma transacción R2DBC + relay que publica a Kafka) y tabla `processed_message` para idempotencia. Las tablas `outbox` y `processed_message` se generan vía el changelog Liquibase `00003_outbox.yaml` en el repo `<proyecto>-migrations` de Gitea (producido por el scaffold con `--outbox`).
- En la **capa rest-api** (o consumidor Kafka): el/los **endpoint(s)/consumidor(es) de compensación** idempotentes que el orquestador invoca para revertir el paso.
- En la **Sección 8 (TDD)**: prueba del outbox con Testcontainers (atomicidad + publicación única) y prueba de idempotencia (la reentrega no produce doble efecto); prueba de contrato del endpoint de compensación con WebTestClient.
- En los **criterios de aceptación**: el servicio publica eventos vía outbox (no dual-write) y sus compensaciones son idempotentes.

### Reglas para los documentos de reportería (solo si el diseño incluye el subsistema de Reportería)

Si el diseño técnico declara reportería, generar documentos dedicados (no usan `maven_hexagonal_scaffold.py`):

**`DEV-[proyecto]-03-ms-projection-service.md` (Projection Service, Spring Boot)** — estructura de Etapa 3 con:
- **Scaffolding:** generado con `maven_hexagonal_scaffold.py` vía `--backend reporting-projection-service:postgres:kafka-consumer:<puerto>`. Conecta a `<pg-prefix>_readmodel` (detectado automáticamente por `create-all-secrets-vault.sh` por el patrón de nombre `*projection*`).
- **Responsabilidad:** consumir eventos de dominio de todos los microservicios desde Kafka y proyectar tablas desnormalizadas en `<pg-prefix>_readmodel` (PostgreSQL). **Es el único escritor de la BD read model.** Los demás servicios solo leen.
- **Capas hexagonales:** dominio: puertos `EventProjectionPort` (por tipo de evento) y repositorios R2DBC; aplicación: un use case por proyección (`ProjectCustomerCreated`, `ProjectOrderCreated`, etc.); infraestructura: Kafka consumer (entry-point), adaptadores R2DBC que escriben en las tablas desnormalizadas (`report_sales`, `report_customers`, etc.).
- **Tablas del read model:** derivar del diseño — p. ej. `report_sales(customer_id, customer_name, order_id, order_total, payment_amount, payment_date)`; la estructura refleja exactamente qué necesita MS1 para sus queries de extracción.
- **TDD:** prueba de proyección con Testcontainers PostgreSQL (evento Kafka → fila en tabla desnormalizada); idempotencia (reentrega no duplica fila); cada proyector con happy path y caso de error. Umbrales ≥ 85%.
- **Criterios:** evento recibido → fila presente en `<prefix>_readmodel`; reentrega idempotente; `mvn test` verde.

**`DEV-[proyecto]-03-ms-report-etl-service.md` (ETL unificado, Spark Scala)** — estructura de Etapa 3 con:
- **Scaffolding:** `.claude/templates/scala_hexagonal_scaffold.py --report-role extraction --source jdbc --pg-db <pg-prefix> --report-types <lista> --org <proyecto> --schedule "<cron>"` (documentado en `02-scaffold.md` vía `--report-extraction <svc>:jdbc:<topic-out>` + `--report-types <lista>` + `--report-schedule` de `scaffold-all-services.sh`). Con CQRS la fuente **siempre es `--source jdbc`** (lee el read model PostgreSQL `<pg-prefix>_readmodel`); `--source mongo` solo para proyectos sin CQRS con fuente MongoDB directa. `--pg-db` deriva: la URL JDBC de lectura como `<prefix>_readmodel` y la BD propia del ETL como `<prefix>_reporting` (contiene `report_schema_catalog`). El scaffold genera automáticamente `db/<svc>/changelog/00001_initial_schema.yaml` con el DDL de `report_schema_catalog`.
- **Capas hexagonales (Spark, ETL unificado):** dominio `ReportSchema`/`ColumnSpec`/`ReportType`/`ReportParquetGenerated` + puertos `SourceDataPort`/`ParquetStorePort`/`EventBusPort`; aplicación `ExtractReportUseCase` (valida esquema + transforma vía Factory + publica evento) + `ReportTransformerFactory` + un `ReportTransformer` por tipo (DR-10); infraestructura **`SparkJdbcSourceAdapter`** (lee `<prefix>_readmodel`), `SparkS3ParquetAdapter`, `KafkaEventPublisher`.
- **TDD (Sección 8):** validación de esquema (columnas faltantes/tipos/integridad → fallo), factory (`reportType` conocido→transformer / desconocido→`UnsupportedReportTypeException`), adaptador S3/MinIO-parquet round-trip (`testcontainers-minio`), **adaptador JDBC con Testcontainers PostgreSQL** (levanta `<prefix>_readmodel` en test con datos de fixture), publicación de `ReportParquetGenerated` con embedded Kafka. Umbrales: dominio/use cases ≥ 85%, adaptadores ≥ 80%.
- **Despliegue K8s:** `helm/<service>/templates/cronjob.yaml` (CronJob, no Deployment); ArgoCD sincroniza el CronJob; Jenkins **no ejecuta smoke tests** (sin endpoint HTTP). El CI termina en `bumpImageTag`.
- **Criterios de aceptación:** `sbt compile` y `sbt assembly` verdes; validación fallida ⇒ `report.etl.failed` sin parquet; lectura del read model exitosa vía JDBC; `ReportParquetGenerated` publicado (un evento por formato).

**`DEV-[proyecto]-06-reporting-serverless.md` (capa de formatos)** — OpenFaaS via Helm en K3s:
- **Scaffolding:** `.claude/templates/report_lambdas_scaffold.py --org <proyecto> --kafka-topic report.processed --image-registry <registry>` (vía `--report-formats`). Genera: función OpenFaaS `report-format-consumer` (python3-http), `stack.yml` faas-cli, Helm values para `openfaas/openfaas` y `openfaas/kafka-connector`, script de secrets K8s y `deploy.sh`.
- **TDD:** función de formato (parquet→archivo válido en `output/` con pytest + MinIO del K3s), handler OpenFaaS (evento `ReportParquetGenerated` → genera archivo en MinIO), enrutamiento por campo `format` del evento (anotación `topic:` en stack.yml).
- **Despliegue:** `helm upgrade --install openfaas openfaas/openfaas` + `helm upgrade --install kafka-connector openfaas/kafka-connector` en namespace `openfaas` del K3s; función desplegada con `faas-cli deploy`; `ENABLE_REPORTING_SERVERLESS` para omitir.

**En el Documento Maestro (roadmap):** añadir al **Mapa de Microservicios** las columnas **"Tipo de reporte"** y **"Formatos"** para los servicios de reportería; MS1/MS2 son *jobs batch* (no servicios REST), con dependencia MS1→MS2 vía `report.extracted` y MS2→serverless vía `report.processed`.

**En `DEV-[proyecto]-05-tests.md`:** añadir el **E2E de reportería**: (a) camino feliz — ETL unificado lee fuente → valida → transforma → parquet en MinIO → publica `ReportParquetGenerated` → OpenFaaS Function genera 3 formatos en `output/`; (b) validación fallida (columna faltante ⇒ `report.etl.failed`, sin parquet ni evento). Ejecutado con MinIO + Kafka (K3s del VPS) + OpenFaaS desplegado via Helm en K3s.

---

## Etapa 4 — DEV-[proyecto]-04-fe-[feature].md (uno por feature frontend)

Título H1: `# Etapa 4 — Frontend: Feature [Nombre del Feature]`

Secciones en orden exacto:

1. **Contexto y Objetivo**
   - Descripción del feature y su propósito para el usuario
   - Roles de usuario que acceden a este feature
   - Bounded contexts del backend que consume
2. **Prerrequisitos**
   - Microservicios backend que deben estar corriendo
   - Etapas previas completadas
3. **Rutas y Páginas**
   - Tabla de rutas: path, tipo de ruta (public/protected), componente de página, descripción
   - Indicar si es SSR, ISR o CSR según el diseño
   > **Todos los artefactos del feature se construyen bajo TDD (Red-Green-Refactor): la prueba Vitest descrita en la Sección 9 se escribe y se ve fallar ANTES de implementar el schema, hook o componente correspondiente.** El flujo E2E (Sección 10) se describe antes de integrar el feature (ATDD) y se valida al final.
4. **Componentes** — _test-first: el test de render/interacción (RTL) precede al componente_
   - Tabla de componentes: nombre, tipo (Server Component / Client Component), responsabilidad
   - Para componentes de formulario: campos, validaciones Zod, comportamiento de submit
   - Para componentes de listado/tabla: columnas, paginación, filtros
5. **Integración con API (TanStack Query)** — _test-first: el test del hook con MSW precede al hook_
   - Tabla de hooks: nombre del hook, endpoint que llama, tipo (useQuery / useMutation), descripción
   - Estrategia de caché: staleTime, gcTime, invalidaciones
6. **Estado Global (Zustand)** — _test-first: el test de acciones/estado precede al slice_
   - Nombre del slice, estado que maneja, acciones
   - Solo si el feature requiere estado compartido entre componentes
7. **Esquemas de Validación (Zod)** — _test-first: el test de validación (inputs válidos/inválidos) precede al schema_
   - Schemas a definir con sus campos y reglas de validación
8. **Autenticación y Autorización**
   - Roles que pueden acceder (RBAC)
   - Protección de rutas con NextAuth.js middleware
   - Manejo del JWT en las llamadas a la API
9. **Especificación TDD — Pruebas Unitarias (Vitest)**
   - Encabezar la sección recordando la regla: cada prueba se escribe y se ve **fallar (Red)** antes de implementar el artefacto que la hace **pasar (Green)**, seguido de **Refactor**.
   - **Schemas Zod**: tabla con nombre del archivo de test, caso (input válido / cada input inválido) y el schema de la Sección 7 que precede
   - **Hooks**: tabla con archivo de test, escenario (loading / success / error) mockeado con MSW, y el hook de la Sección 5 que precede
   - **Componentes**: tabla con archivo de test (React Testing Library), interacción/estado que valida, y el componente de la Sección 4 que precede
   - **Slices Zustand** (si aplica): test de acciones que precede al slice de la Sección 6
   - Umbral de cobertura mínima del feature (verificable)
10. **Pruebas E2E (Playwright, ATDD)**
    - Flujos principales a cubrir con Playwright, descritos **antes** de integrar el feature
    - Tabla: nombre del test, flujo descrito, precondiciones
11. **Criterios de Aceptación** — lista de verificación. Incluir como criterios de TDD: cada schema, hook y componente tuvo su prueba escrita primero (Red) y luego pasó (Green); `npm run test` finaliza en verde; la cobertura del feature cumple el umbral declarado; los flujos E2E de la Sección 10 pasan en Playwright.

### Segmentación de features frontend

El número y nombre de los features frontend se determina leyendo el diseño técnico. La segmentación base sugerida es:

- **auth** — Login, registro, recuperación de contraseña, callback OAuth2 con Keycloak (rutas públicas)
- **clientes** — Gestión de clientes: perfil, documentos, codeudores (rutas protegidas: cliente + oficial)
- **originacion** — Solicitudes de crédito: radicar, consultar estado, revisión manual (rutas protegidas: cliente + oficial)
- **simulador** — Simulación de crédito, tabla de amortización (puede ser pública o protegida)
- **ciclovida** — Estado del crédito activo, pagos, abonos, liquidación anticipada (rutas protegidas: cliente + oficial)
- **reportes** — Dashboards de cartera, originación (rutas protegidas: gerente + auditor)
- **configuracion** — Productos, reglas, tasas (rutas protegidas: administrador)
- **auditoria** — Trazabilidad de eventos (rutas protegidas: auditor + cumplimiento)

Ajustar esta segmentación según lo que indiquen los bounded contexts y el diseño real del sistema leído.

---

## Etapa 5 — DEV-[proyecto]-05-tests.md

Título H1: `# Etapa 5 — Pruebas de Integración, E2E, Estrés y Carga`

Secciones en orden exacto:

1. **Objetivo** — describir la cobertura de pruebas de esta etapa y qué riesgos mitiga.
2. **Prerrequisitos** — todos los microservicios y el frontend deben estar corriendo como pods en el cluster K3s local.
3. **Pruebas de Integración**
   - Estrategia: contrato entre microservicios (Spring Cloud Contract o pruebas de API directas)
   - Tabla de escenarios de integración: servicio productor → servicio consumidor → flujo a verificar
   - Herramienta: Testcontainers + JUnit 5 (backend), ambiente local completo
   - Flujos críticos de integración: autenticación → originación → ciclo de vida, eventos Kafka entre servicios
   - **Contract tests de sistemas externos (si hay `integration-service`):** validar las rutas Camel de `integration-service` contra los sistemas externos simulados con **WireMock** (respuestas válidas, errores y timeouts para ejercitar el circuit breaker Resilience4j). Tabla: sistema externo → ruta Camel → escenario (éxito/error/timeout) → resultado esperado.
   - **Saga (si hay orquestación):** verificar la saga completa (happy path) coordinada por `integration-service` y la **saga compensada** provocando el fallo de un participante, comprobando que se ejecutan las compensaciones de los pasos previos en orden inverso y que las compensaciones son idempotentes (reentrega no duplica efecto). Verificar también la publicación de eventos vía outbox (no dual-write).
4. **Pruebas E2E**
   - Herramienta: Playwright (frontend) + Supertest/REST Assured (backend directo)
   - Tabla de flujos E2E: nombre, descripción, actores, precondiciones, pasos, resultado esperado
   - Flujos mínimos obligatorios:
     - Registro y autenticación de usuario
     - Solicitud de crédito completa (cliente → evaluación → aprobación)
     - Registro de pago
     - Generación de reporte de cartera
5. **Pruebas de Estrés**
   - Herramienta: k6
   - Escenarios: ramp-up hasta punto de quiebre por servicio crítico
   - Servicios a estresar: originacion-service, clientes-service, ciclovida-service
   - Métricas a capturar: latencia P95/P99, tasa de error, throughput
6. **Pruebas de Carga**
   - Herramienta: k6
   - Escenarios: carga sostenida representativa del uso normal
   - Tabla: escenario → VUs → duración → umbral de aceptación (P95 < X ms, error rate < Y%)
7. **Verificación E2E de Observabilidad**
   - Verificar que el stack de observabilidad instalado en Etapa 0c está integrado correctamente con los microservicios desplegados:
   - Tabla de escenarios de observabilidad E2E:

     | Escenario | Herramienta | Precondición | Resultado esperado |
     |---|---|---|---|
     | Traza end-to-end generada | Grafana Explore (datasource Tempo, `http://VPS_IP:3001`) | Request HTTP al endpoint de un microservicio | Traza visible con spans de todos los servicios involucrados; `traceId` correlacionado |
     | Métrica scrapeada | Prometheus (`http://VPS_IP:9090`) | Microservicio en `Running` | `http_server_requests_seconds_count` con la etiqueta `application=<servicio>` aparece en Prometheus |
     | Log estructurado con traceId | Grafana Loki (`http://VPS_IP:3001`) | Request HTTP generada | Log en JSON con `traceId` y `spanId` coincidentes con la traza en Tempo |
     | Prometheus scrapea todos los servicios | Prometheus Status > Targets | Todos los microservicios en `Running` | Todos los targets en estado `UP`; ninguno en `DOWN` |

   - Indicar que en prod la verificación es equivalente: mismos endpoints (Grafana Tempo, Prometheus, Loki) en el K3s del VPS Oracle Cloud OCI.
8. **Configuración del Ambiente de Pruebas**
   - Variables de entorno específicas para el ambiente de test
   - Comandos para levantar todos los servicios en modo test (K3s local con pods en `Running`)
   - Seeders de datos de prueba requeridos
9. **Criterios de Aceptación** — lista de verificación final de la etapa de desarrollo. Incluir criterios de observabilidad: traza E2E visible en Grafana Tempo, métrica en Prometheus, log JSON con `traceId` en Grafana Loki.

---

# PROCESO DE GENERACIÓN

## Paso 1 — Leer los documentos de Diseño Técnico

Antes de generar cualquier documento, lee todos los artefactos del diseño técnico:

```
docs/design/SDD-[proyecto]-system.md
docs/design/SDD-[proyecto]-design.md
docs/design/SDD-[proyecto]-infrastructure.md
docs/design/api/SDD-[proyecto]-openapi.yaml
docs/design/database/SDD-[proyecto]-schema.sql
docs/design/database/SDD-[proyecto]-collections.js
```

Si el usuario proporcionó una ruta alternativa como argumento, úsala como punto de partida. Si no, busca en `docs/design/`.

## Paso 2 — Extraer información clave

### Del documento `system.md`:
- Nombre del proyecto (para nombrar los archivos de salida)
- Lista de microservicios: nombre, bounded context, base de datos, mensajería
- Stack tecnológico: versiones de Spring Boot, Java, Next.js
- Diagrama de comunicación entre servicios (qué servicio llama a cuál via REST)

### Del documento `design.md`:
- Tablas del bounded context en PostgreSQL (para asignar propietario a cada tabla)
- Colecciones MongoDB y su bounded context
- Flujos técnicos principales (para los escenarios de integración y E2E)
- Endpoints por bounded context (tabla resumen de la sección Diseño de APIs)

### Del documento `infrastructure.md`:
- Configuración de ambientes (`local` usa K3s en QEMU/KVM; `prod` usa K3s en Oracle Cloud OCI)
- Puertos y endpoints del VPS (derivados de los outputs de `base-infrastructure-builder.sh`)
- Variables de entorno requeridas

### Del archivo `openapi.yaml`:
- Endpoints completos por tag/bounded context
- Schemas de request/response
- Security schemes (JWT Bearer)

### Del archivo `schema.sql`:
- Tablas agrupadas por bounded context (por los comentarios `--`)
- Columnas y constraints de cada tabla
- Relaciones entre tablas

### Del archivo `collections.js`:
- Colecciones de MongoDB y su estructura
- Índices definidos

## Paso 3 — Determinar el orden de microservicios

Analiza las dependencias REST entre microservicios para establecer el orden de implementación:
- Los servicios sin dependencias de otros servicios van primero
- Los servicios con pocas dependencias van después
- Los servicios que dependen de muchos otros van al final
- Los servicios de auditoría y reportes (consumidores Kafka puros) van al final

Documenta este orden en el roadmap y en el prerrequisito de cada documento de microservicio.

## Paso 4 — Determinar la segmentación del frontend

Analiza los bounded contexts, los roles de usuario y los flujos del sistema para determinar los features del frontend. Usa la segmentación sugerida en la sección anterior como base, y ajústala si el diseño indica algo diferente.

## Paso 5 — Generar los documentos

Genera los documentos en este orden:

1. Primero el roadmap (`DEV-[proyecto]-roadmap.md`) — necesita tener la visión completa antes de generarse; incluir la fila de Etapa 2b en la tabla de secuencia de etapas, posicionada entre la Etapa 2 (scaffold) y la Etapa 3a (primer microservicio), con dependencia `Etapa 2 + infra Jenkins/ArgoCD (Etapa 0)` y esfuerzo estimado de 1 día; incluir también la fila de Etapa 0c, posicionada entre la Etapa 0 (infraestructura) y la Etapa 1 (bases de datos), con dependencia `Etapa 0 completa` y esfuerzo estimado de 0.5 días
2. Luego las etapas 0, 0c y 1 y 2 (infraestructura, observabilidad, bases de datos, scaffolding)
3. Luego la etapa 2b (configuración del pipeline CI/CD) — va antes de los microservicios para que cada commit de las etapas 3 y 4 sea validado automáticamente
4. Luego los documentos de microservicios en el orden de implementación determinado en el Paso 3
5. Luego los documentos de features frontend en orden de dependencia (auth primero, siempre)
6. Finalmente el documento de pruebas

## Paso 6 — Crear el directorio de salida

Antes de escribir los archivos, verifica que el directorio `docs/development/` existe. Si no existe, créalo.

---

# REGLAS IMPORTANTES

- **Parámetros mandatorios por script y template** — todos los scripts `.sh` de `.claude/scripts/` que generan o configuran recursos del proyecto reciben el nombre del proyecto vía `-P <nombre-proyecto>` (obligatorio, sin valor por defecto). Los templates Python de `.claude/templates/` reciben el nombre del componente vía `-n <nombre>` (obligatorio) y el slug del proyecto vía `--org <nombre-proyecto>` (debe coincidir con el `-P` pasado a los scripts). **Nunca omitir estos parámetros en los comandos documentados en los planes de desarrollo.**

  | Script / Template | Parámetro proyecto | Parámetro nombre componente | Otros parámetros clave | Obligatorio |
  |---|---|---|---|---|
  | `base-infrastructure-builder.sh` | `--project <nombre-proyecto>` | — | `--vm-ip <VPS_IP>` (requerido); `--pg-prefix <prefix>` (requerido); `--mongo-prefix <prefix>` (requerido); `--env local\|prod`; `--no-kong`, `--no-minio`, `--no-lra`, `--no-wiremock`, `--no-loki`, `--no-tempo` | Sí |
  | `jenkins-shared-library-builder.sh` | `-P <nombre-proyecto>` | — | — | Sí |
  | `setup-cicd-pipeline.sh` | `-P <nombre-proyecto>` | — | `-S <svc1,svc2,...>` (backends, obligatorio); `--vm-ip <VPS_IP>` (obligatorio); `-F <frontend>` (opcional) | Sí |
  | `scaffold-all-services.sh` | `-P <nombre-proyecto>` | `--vm-ip <VPS_IP>` | `-p <pg-prefix> -m <mongo-prefix>` (Database-per-Service); `--report-schedule "<cron>"` | Sí |
  | `init-databases.sh` | `-P <nombre-proyecto>` | `--vm-ip <VPS_IP>` | `-p <pg-prefix> -m <mongo-prefix>` (prefijos de BD; crea `<prefix>_<svc_slug>` en PostgreSQL K3s pod) | Sí |
  | `create-all-secrets-vault.sh` | `-P <nombre-proyecto>` | `--vm-ip <VPS_IP>` | `--pg-prefix <prefix>` `--mongo-prefix <prefix>` (Database-per-Service; endpoints K3s internos; escribe en Vault KV v2) | Sí |
  | `run-liquibase-migrations.sh` | `-P <nombre-proyecto>` | `--vm-ip <VPS_IP>` | `-p <pg-prefix>` `-u <usuario>` `-w <clave>`; `--gitea-clone` (clona `<proyecto>-migrations` de Gitea); `--db-dir <ruta>` (local); `--service <svc>`; `--action update\|rollback\|status\|validate` | Sí |
  | `maven_hexagonal_scaffold.py` | `--org <nombre-proyecto>` | `-n <nombre-servicio>` | `--pg-db <prefix>` `--mongo-db <prefix>` (Database-per-Service; leído por `create-all-secrets-vault.sh`) | `-n` y `--org` sí |
  | `scala_hexagonal_scaffold.py` | `--org <nombre-proyecto>` | `--service-name <nombre>` | `--schedule "<cron>"` (CronJob K8s); `--report-role extraction\|processing`; `--pg-db <prefix>` (`--source jdbc` → `<prefix>_readmodel`; `extraction` → genera también `<prefix>_reporting` con `report_schema_catalog`); `--migrations-dir <ruta>` (default `db/`) | `--org` sí |
  | `integration_service_scaffold.py` | `--org <nombre-proyecto>` | `-n integration-service` | `--pg-db-prefix <prefix>` (deriva BD `<prefix>_integration_service`; si se omite usa `--org`); `--migrations-dir <ruta>` (default `db/`); `--external-systems "nombre=BC-XX,..."` `--saga-flows <flujo1,...>` | `--org` sí |
  | `nextjs_feature_scaffold.py` | `--org <nombre-proyecto>` | `-n <nombre-proyecto-fe>` | — | `-n` sí |

- **TDD es obligatorio y transversal** (ver sección "ESTRATEGIA DE PRUEBAS — TDD"). Todo documento de microservicio (Etapa 3) y de feature frontend (Etapa 4) debe presentar la implementación como **test-first** (Red-Green-Refactor): la prueba precede al código de producción en cada capa/artefacto. No describir una "fase de pruebas al final"; las pruebas conducen cada capa. Los criterios de aceptación de esos documentos deben incluir la verificación de que cada elemento tuvo su prueba escrita primero, que la suite está en verde y que se cumplen los umbrales de cobertura. Backend: JUnit 5 + Mockito + StepVerifier + Testcontainers + WebTestClient; los tipos reactivos se verifican con StepVerifier, nunca con `block()`. Frontend: Vitest + React Testing Library + MSW (unitario) y Playwright bajo ATDD (E2E).
- NO incluir loops o comandos bash con nombres de servicios o proyectos hardcodeados (ej: `for service in servicio-a servicio-b ...`). En su lugar, referenciar los scripts genéricos de `.claude/scripts/` que usan `find *-service` o `find *-project` para descubrir los componentes dinámicamente: `scaffold-all-services.sh` (generar scaffolding — recibe **`-P <nombre-proyecto>`** y **`--vm-ip <VPS_IP>`** obligatorios más `--backend nombre:db:messaging:puerto`, `--frontend nombre`, `--bc-tags servicio=BC-XX`, los **cuatro parámetros de BD** `-p <pg-prefix> -m <mongo-prefix> -u <usuario> -w <clave>` y, para servicios Spark, `--report-schedule "<cron>"`), `init-databases.sh` (patrón **Database-per-Service**: crea BDs aisladas en **PostgreSQL 16 pod K3s** (`postgresql.data.svc.cluster.local:5432`) y MongoDB 7 pod K3s (`mongo.data.svc.cluster.local:27017`); recibe **`-P`** y **`--vm-ip`** más los cuatro parámetros de BD), `run-liquibase-migrations.sh` (aplica changelogs Liquibase contra PostgreSQL K3s; recibe **`-P`** más `-p <pg-prefix>`, `-u <usuario>`, `-w <clave>`; usa `--gitea-clone` para clonar automáticamente el repo `<proyecto>-migrations` desde Gitea, `--db-dir <ruta>` para apuntar a un clon local, o sin ninguno lee `db/*-service/changelog/` local; opcionalmente `--service <svc>` y `--action update|rollback|status|validate`), `compile-services.sh` (compilar backend), `verify-frontend.sh` (verificar frontend), `create-all-secrets-vault.sh` (crear secrets en **HashiCorp Vault** con **Database-per-Service** — endpoints K3s internos; recibe **`-P`** y **`--vm-ip`** más `--pg-prefix` y `--mongo-prefix`; invocado por `scaffold-all-services.sh`), `setup-cicd-pipeline.sh` (configurar el pipeline CI/CD completo — recibe **`-P <nombre-proyecto>`**, **`-S <svc1,svc2,...>`** y **`--vm-ip <VPS_IP>`** obligatorios, **`-F <frontend>`** opcional; en local es totalmente autónomo: verifica pod Jenkins en K3s, autocompleta `SONAR_*`/`GITOPS_*`/`vault-token`, crea jobs multibranch y webhooks en Gitea, Slack es opcional, **sin variables Vercel ni ECR**). Si el proceso que se quiere documentar no tiene aún un script genérico, describir el paso como instrucción narrativa, no como loop con nombres fijos.
- NO generar código de aplicación dentro de los documentos de plan. Los documentos describen QUÉ implementar y cómo estructurarlo, no contienen implementaciones completas.
- SÍ incluir fragmentos de código ilustrativos (firmas de métodos, ejemplos de configuración, comandos exactos) cuando sea necesario para claridad.
- Las rutas de archivos en comandos deben ser relativas al directorio raíz del repositorio.
- Los comandos de scaffold deben derivarse del diseño: si un servicio usa Kafka, incluir el flag `-m kafka-producer` o `-m kafka-consumer` según corresponda; si usa PostgreSQL, `-d postgres`; si usa MongoDB, `-d mongo`. Incluir siempre el flag `-p <puerto>` con el puerto local asignado al servicio (derivado del diseño de infraestructura o del mapa de puertos del roadmap) — el default del script es `8080` pero cada microservicio debe tener un puerto distinto para poder correr simultáneamente en local.
- El documento de roadmap debe ser navegable: los nombres de los documentos en la tabla de etapas deben ser enlaces relativos a los archivos generados.
- Cada documento de microservicio debe ser completamente autónomo para que un desarrollador diferente pueda tomarlo y ejecutarlo.
- Los criterios de aceptación deben ser verificables objetivamente (no "la aplicación funciona", sino "el endpoint GET /clientes/{id} retorna 200 con el schema esperado").
- Las pruebas unitarias descritas deben ser concretas: nombre de la clase de test, nombre del método, escenario que valida.
- El ambiente objetivo es **VPS Ubuntu 26.04 LTS con K3s + Terraform + Helm** — entornos `local` (QEMU/KVM) y `prod` (Oracle Cloud OCI); no AWS, no EKS, no systemd para servicios del framework. Todos los comandos deben apuntar a `VPS_IP:*` (reemplazar con la IP real del VPS). Los servicios del framework (PostgreSQL, MongoDB, Kafka, Gitea, Jenkins, ArgoCD, Keycloak, Vault, Kong, MinIO, WireMock, LRA, observabilidad) corren como pods K3s instalados por Terraform + Helm; el registry de imágenes es el **Gitea Package Registry** en local y **OCIR (Oracle Container Registry)** en prod; el frontend despliega como pod K3s (no a Vercel); los secrets se gestionan con **HashiCorp Vault** (no floci, no AWS Secrets Manager). No mencionar floci, Cognito, ECR, RDS ni servicios systemd en los documentos generados.

# EXPECTATIVAS DE CALIDAD

Los documentos deben:
- ser técnicamente precisos y coherentes con el diseño aprobado,
- ser accionables sin necesidad de consultar otros documentos,
- cubrir todos los componentes identificados en el diseño técnico sin omisiones,
- tener criterios de aceptación que realmente validen lo que dice el diseño,
- incluir pruebas que protejan los invariantes de dominio y los contratos de API.

# EXPECTATIVA PROFESIONAL

El resultado debe parecer escrito por:
- un Staff Engineer con experiencia en arquitectura hexagonal y Spring WebFlux,
- un Technical Lead con experiencia en Next.js y arquitectura feature-based,
- un QA Architect con experiencia en estrategias de pruebas para sistemas distribuidos.

# REQUERIMIENTOS DE SALIDA

- Genera contenido Markdown limpio para todos los documentos.
- No envuelvas la salida en bloques de código salvo fragmentos técnicos internos.
- Mantén Markdown correctamente estructurado en cada archivo.
- Guarda los documentos usando la herramienta Write en `docs/development/`.
- Al finalizar, informa al usuario todas las rutas donde fueron guardados los documentos.
- Indica cuántos documentos de microservicio y cuántos de frontend feature fueron generados.

---

# ENTRADA

## Argumentos soportados

La skill acepta un argumento posicional opcional:

- **Argumento 1 (opcional):** ruta a la carpeta o a un archivo del Diseño Técnico. Si se omite, busca en `docs/design/`.

Ejemplos de invocación:

```
/development-plan
/development-plan docs/design/
/development-plan docs/design/SDD-proyecto-system.md
```

---

Si el argumento proporcionado es una ruta alternativa: $0

Usa esa ruta en lugar de la ruta por defecto.
