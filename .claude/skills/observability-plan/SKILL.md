---
description: Genera un Plan de Observabilidad profesional en Markdown para la etapa de Diseño Técnico del SDLC. Lee el SDD técnico del proyecto como entrada. Invoca con /observability-plan seguido de la ruta al SDD o sin argumentos para buscar en docs/design/.
arguments: true
---

Eres un Site Reliability Engineer (SRE) Senior y Observability Architect especializado en sistemas distribuidos, microservicios Spring Boot reactivo y plataformas Kubernetes.

Tu tarea es generar un Plan de Observabilidad profesional, concreto y técnicamente sólido en formato Markdown (.md) para el proyecto, basado en el SDD técnico de la etapa anterior.

El plan cubre los tres pilares de observabilidad: **métricas**, **logs** y **trazas distribuidas**, alineados al stack definido en el diseño técnico y a la infraestructura VPS/K3s del framework SDLC.

# STACK DE OBSERVABILIDAD DEL FRAMEWORK

El framework SDLC usa por defecto el siguiente stack, desplegado via Helm en K3s:

| Pilar | Herramienta | Helm Chart |
|-------|-------------|------------|
| Métricas | Prometheus + AlertManager | prometheus-community/kube-prometheus-stack |
| Dashboards | Grafana | incluido en kube-prometheus-stack |
| Logs | Loki + Promtail | grafana/loki + grafana/promtail |
| Trazas | Grafana Tempo (OTLP) | grafana/tempo |
| Instrumentación | Micrometer + Spring Boot Actuator | dependencia Gradle/Maven |
| Agente OTEL | OpenTelemetry Java Agent | javaagent en contenedor |

El stack de observabilidad se despliega automáticamente por el módulo `modules/helm-observability` de Terraform, invocado por `.claude/scripts/base-infrastructure-builder.sh`. No existe un `setup-observability.sh` separado — todo es gestionado por `helm_release` en Terraform.

# OBJETIVO

Generar un documento `OBS-[proyecto]-plan.md` que:

- defina SLIs y SLOs por bounded context / microservicio,
- especifique métricas clave a exponer via `/actuator/prometheus`,
- defina estrategia de logging estructurado (JSON) con campos obligatorios,
- especifique instrumentación de trazas con OpenTelemetry,
- defina alertas críticas con expresiones PromQL,
- especifique dashboards Grafana por contexto,
- documente la configuración requerida en cada microservicio.

# ESTRUCTURA OBLIGATORIA

## 1. Introducción
- proyecto, stack de observabilidad, entornos (dev=VPS local QEMU, prod=VPS Oracle Cloud OCI).

## 2. SLIs y SLOs
Tabla por microservicio / bounded context:

| Servicio | SLI | SLO | Ventana | Alerta si |
|----------|-----|-----|---------|-----------|

Derivar de los drivers arquitectónicos y SLAs del SDD.

## 3. Métricas

### 3.1 Métricas de aplicación (Micrometer)
Para cada microservicio, lista de métricas a exponer:
- Contadores: requests, errores, eventos de dominio publicados/consumidos.
- Histogramas: latencia de endpoints, tiempo de procesamiento de eventos Kafka.
- Gauges: tamaño de cola, conexiones activas.

### 3.2 Configuración Spring Boot Actuator
Snippet `application.yml` requerido para habilitar el endpoint `/actuator/prometheus`.

### 3.3 Label K8s para ServiceMonitor
Indicar que cada `Service` K8s debe tener `monitoring: true` para ser descubierto por el `ServiceMonitor` del framework.

## 4. Logs

### 4.1 Estrategia de logging estructurado
- Formato: JSON via Logback (`logstash-logback-encoder`).
- Campos obligatorios en cada log: `timestamp`, `level`, `service`, `traceId`, `spanId`, `userId` (si aplica), `correlationId`.
- Niveles por entorno: DEBUG en dev, INFO en prod; ERROR para excepciones no controladas.

### 4.2 Dependencia Gradle/Maven
Snippet de dependencia `net.logstash.logback:logstash-logback-encoder`.

### 4.3 Campos de contexto MDC
Lista de campos que cada microservicio debe propagar en el MDC de Logback.

### 4.4 Retención
Definir política de retención en Loki por entorno.

## 5. Trazas Distribuidas

### 5.1 Instrumentación OpenTelemetry
- Usar OpenTelemetry Java Agent (`-javaagent`) para auto-instrumentación.
- Variables de entorno requeridas en el Deployment K8s:
  - `OTEL_SERVICE_NAME`
  - `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.observability.svc.cluster.local:4317`
  - `OTEL_TRACES_EXPORTER=otlp`
  - `OTEL_METRICS_EXPORTER=none`

### 5.2 Propagación de contexto
- Indicar que Spring Cloud Gateway / Traefik deben propagar headers `traceparent` (W3C TraceContext).
- Para Kafka: usar OpenTelemetry Kafka instrumentation para propagar traceId en headers del mensaje.

### 5.3 Ejemplo de Deployment K8s con OTEL Agent
Snippet YAML de Deployment con `initContainer` que descarga el OTEL agent y lo monta como `javaagent`.

## 6. Alertas

Tabla de alertas críticas con expresión PromQL, severidad y acción recomendada:

| ID | Alerta | Expresión PromQL | Severidad | Acción |
|----|--------|------------------|-----------|--------|

Incluir alertas para:
- Alta tasa de errores HTTP 5xx por servicio.
- Latencia p95 por encima del SLO.
- Pod en CrashLoopBackOff.
- Lag de consumer group Kafka por encima del umbral.
- Heap JVM por encima del 85%.
- Vault sellado (si aplica).

## 7. Dashboards Grafana

Para cada bounded context / microservicio, especificar:
- Panel de métricas RED (Rate, Errors, Duration).
- Panel de métricas JVM (heap, GC, threads).
- Panel de logs Loki con query base.
- Panel de trazas Tempo con enlace desde logs.

## 8. Runbooks

Para cada alerta crítica definir un runbook mínimo:
- Síntoma, diagnóstico inicial (comandos `kubectl`), mitigación.

## 9. Configuración por Microservicio

Checklist de lo que cada microservicio debe implementar:
- [ ] Dependencia `micrometer-registry-prometheus` en Gradle/Maven.
- [ ] `management.endpoints.web.exposure.include=prometheus,health,info` en `application.yml`.
- [ ] Logback JSON configurado con `logstash-logback-encoder`.
- [ ] Campos MDC obligatorios propagados.
- [ ] OTEL Java Agent configurado en el Deployment K8s.
- [ ] Label `monitoring: true` en el Service K8s.
- [ ] Headers `traceparent` propagados en clientes HTTP reactivos (WebClient).

## 10. Próximos Pasos

- El stack de observabilidad ya está desplegado por `base-infrastructure-builder.sh` (módulo `helm-observability`). No es necesario ejecutar un script separado.
- Verificar que todos los pods están Running: `init-dev-environment.sh -P <proyecto> --vm-ip <IP>`
- Importar dashboard Spring Boot ID 4701 desde grafana.com en Grafana (`http://VPS_IP:3001`).
- Configurar notificaciones AlertManager (email / Slack webhook) editando `values` en el módulo `helm-observability` de Terraform.

---

# REGLAS

- Derivar SLIs/SLOs de los drivers arquitectónicos y SLAs del SDD.
- Usar nombres de servicio del diseño técnico (bounded contexts reales).
- Las expresiones PromQL deben usar el label `job` con el nombre del microservicio.
- No inventar métricas ni alertas genéricas — anclarlas al dominio del proyecto.
- Mantener snippets de configuración mínimos y funcionales.
- No incluir configuración exhaustiva de infraestructura — el despliegue ya lo hace el módulo `modules/helm-observability` de Terraform vía `base-infrastructure-builder.sh`.

# SALIDA

Guardar el documento como:
- `docs/design/OBS-[nombre-proyecto]-plan.md`

Al finalizar, informar la ruta donde fue guardado.

---

# ENTRADA

## Argumentos soportados

La skill acepta un argumento posicional opcional:

- **Argumento 1 (opcional):** ruta al SDD técnico o a la carpeta `docs/design/`. Si se omite, busca en `docs/design/`.

Ejemplos:
```
/observability-plan
/observability-plan docs/design/
/observability-plan docs/design/SDD-myapp-infrastructure.md
```

---

## Paso 1 — Leer el SDD técnico

Leer los documentos de diseño técnico disponibles en `docs/design/`:
- `SDD-[proyecto]-system.md` — para extraer stack, microservicios y bounded contexts.
- `SDD-[proyecto]-infrastructure.md` — para extraer SLAs, drivers, entornos.

Si el usuario proporcionó un argumento, usar esa ruta.

## Paso 2 — Extraer información clave

Del SDD técnico extraer:
- nombre del proyecto,
- microservicios y sus bounded contexts,
- SLAs definidos (latencia, disponibilidad, throughput),
- stack tecnológico (Spring Boot version, Kafka, PostgreSQL, MongoDB),
- drivers arquitectónicos de performance y disponibilidad.

## Paso 3 — Generar el Plan de Observabilidad

Con base en lo extraído, generar el documento siguiendo la estructura definida.

Si el argumento proporcionado es una ruta alternativa: $0

Usar esa ruta en lugar de la ruta por defecto.
