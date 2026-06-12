# SDLC Framework SaaS

Framework de automatización de las etapas del ciclo de vida del desarrollo de software (SDLC) mediante skills de Claude Code. Cada etapa produce un documento Markdown profesional que sirve como entrada para la siguiente.

---

## Flujo General

```
Requerimiento del cliente
        │
        ▼
[Paso 1] Diligenciar input-template.md      →  requerimiento/<archivo>.md
        │
        ▼
[Paso 2] /plan-pid                           →  docs/planning/PID-<proyecto>.md
        │
        ▼
[Paso 3] /requirements-srs                  →  docs/requirements/SRS-<proyecto>.md
        │
        ▼
[Paso 4] Diligenciar input-adc-template.md  →  docs/planning/ADC-<proyecto>.md
        │
        ▼
[Paso 5] /strategic-design-sdd              →  docs/strategic-design/SDD-<proyecto>-domain.md
                                                docs/strategic-design/SDD-<proyecto>-security.md
                                                docs/strategic-design/SDD-<proyecto>-architecture.md
        │
        ▼
[Paso 6] /technical-design-sdd              →  docs/design/SDD-<proyecto>-system.md
                                                docs/design/SDD-<proyecto>-design.md
                                                docs/design/SDD-<proyecto>-infrastructure.md
                                                docs/design/diagrams/SDD-<proyecto>-c4-context.mmd
                                                docs/design/diagrams/SDD-<proyecto>-c4-container.mmd
                                                docs/design/api/SDD-<proyecto>-openapi.yaml
                                                docs/design/database/SDD-<proyecto>-schema.sql
        │
        ▼
[Paso 7] /development-plan                  →  docs/development/DEV-<proyecto>-roadmap.md
                                                docs/development/DEV-<proyecto>-00-infrastructure.md
                                                docs/development/DEV-<proyecto>-0c-observability.md
                                                docs/development/DEV-<proyecto>-01-databases.md
                                                docs/development/DEV-<proyecto>-02-scaffold.md
                                                docs/development/DEV-<proyecto>-02b-cicd.md
                                                docs/development/DEV-<proyecto>-03-ms-<servicio>.md
                                                docs/development/DEV-<proyecto>-04-fe-<feature>.md
                                                docs/development/DEV-<proyecto>-05-tests.md
        │
        ▼
[Paso 8] /testing-plan                      →  docs/testing/QA-<proyecto>-plan.md
                                                docs/testing/QA-<proyecto>-acceptance.md
                                                docs/testing/QA-<proyecto>-e2e.md
                                                docs/testing/QA-<proyecto>-performance.md
```

---

## Paso 1 — Captura del Requerimiento del Cliente

**Objetivo:** documentar la información del cliente antes de iniciar cualquier etapa SDLC.

### Instrucciones

1. Abre la plantilla de entrada:

   ```
   .claude/formatos/input-template.md
   ```

2. Completa todos los campos marcados con `*` (obligatorios). Los opcionales pueden dejarse en blanco; las skills los inferirán del contexto.

3. Guarda el archivo completado en el directorio `requerimiento/` con un nombre descriptivo:

   ```
   requerimiento/<nombre-proyecto>.md
   ```

### Campos principales del template

| Sección | Descripción |
|---------|-------------|
| Identificación del Proyecto | Nombre, tipo, dominio, sponsor, PM, duración |
| Problema de Negocio | Situación actual, problemas operacionales, impacto |
| Objetivos | General y específicos |
| Alcance | Incluido y excluido |
| Stakeholders | Tabla de actores y responsabilidades |
| Requerimientos de Alto Nivel | Funcionales y no funcionales |
| Supuestos y Restricciones | Supuestos del proyecto y limitaciones conocidas |
| Presupuesto Estimado | Total y categorías |
| Riesgos Conocidos | Lista inicial de riesgos |

---

## Paso 2 — Etapa SDLC: Planeación

**Skill:** `/plan-pid`  
**Entrada:** documento generado en el Paso 1  
**Salida:** `docs/planning/PID-<nombre-proyecto>.md`

### Instrucciones

Invoca la skill pasando como argumento el contenido del documento de requerimiento:

```
/plan-pid <ruta o contenido de requerimiento/<nombre-proyecto>.md>
```

### Qué genera

Un **Project Initiation Document (PID)** profesional con las siguientes secciones:

1. Resumen Ejecutivo
2. Descripción General del Proyecto
3. Problema de Negocio
4. Objetivos del Proyecto
5. Alcance
6. Stakeholders
7. Requerimientos de Alto Nivel
8. Supuestos y Restricciones
9. Análisis de Viabilidad
10. Evaluación Inicial de Riesgos
11. Cronograma de Alto Nivel
12. Estimación Inicial de Costos
13. Criterios de Éxito
14. Recomendación y Próximos Pasos

### Notas

- Los campos que no puedan derivarse del requerimiento serán inferidos y marcados con `[inferido]`.
- El documento queda listo para revisión por stakeholders y para alimentar la siguiente etapa.

---

## Paso 3 — Etapa SDLC: Análisis de Requerimientos

**Skill:** `/requirements-srs`  
**Entrada:** PID generado en el Paso 2 (buscado automáticamente en `docs/planning/`)  
**Salida:** `docs/requirements/SRS-<nombre-proyecto>.md`

### Instrucciones

Invoca la skill sin argumentos para que lea automáticamente el PID disponible en `docs/planning/`:

```
/requirements-srs
```

O pasa la ruta explícita al PID si tienes varios proyectos:

```
/requirements-srs docs/planning/PID-<nombre-proyecto>.md
```

### Qué genera

Un **Software Requirements Specification (SRS)** profesional con las siguientes secciones:

1. Introducción
2. Descripción General del Sistema
3. Actores del Sistema
4. Requerimientos Funcionales (`RF-001`, `RF-002`…)
5. Requerimientos No Funcionales (`RNF-001`, `RNF-002`…)
6. Reglas de Negocio (`RN-001`, `RN-002`…)
7. Casos de Uso Principales (`CU-001`, `CU-002`…)
8. Restricciones Técnicas
9. Supuestos y Dependencias
10. Criterios de Aceptación
11. Glosario

### Notas

- El SRS se construye a partir del PID; no es necesario reprocesar el requerimiento original.
- Cada requerimiento funcional tiene ID único y criterios de aceptación verificables.
- El documento queda listo para pasar a la etapa de Diseño Estratégico.

---

## Paso 4 — Contexto Arquitectónico (ADC)

**Objetivo:** capturar decisiones tecnológicas, restricciones y drivers de arquitectura antes de ejecutar el diseño estratégico. El ADC enriquece el SDD con información que no proviene del análisis funcional.

### Instrucciones

1. Abre la plantilla ADC:

   ```
   .claude/formatos/input-adc-template.md
   ```

2. Completa los campos marcados con `*` (obligatorios). Los opcionales permiten mayor precisión en el SDD; si se omiten, la skill infiere valores desde el SRS.

3. Guarda el archivo completado en `docs/planning/`:

   ```
   docs/planning/ADC-<nombre-proyecto>.md
   ```

### Campos principales del ADC

| Sección | Descripción |
|---------|-------------|
| Contexto Tecnológico | Stack mandatorio/permitido/excluido por capa |
| Infraestructura y Despliegue | Cloud provider, modelo de servicio, contenedores |
| Estilo Arquitectónico | Monolito / microservicios / serverless / event-driven |
| Atributos de Calidad y SLAs | Disponibilidad, latencia, throughput, RTO/RPO |
| Escala y Crecimiento | Usuarios esperados y volumen de datos por año |
| Compliance y Regulaciones | GDPR, HIPAA, PCI-DSS, normativas locales |
| Integraciones | Sistemas legados, APIs de terceros, estrategia Saga |
| Equipo y Capacidad | Tamaño, perfil, experiencia con el estilo elegido |
| Presupuesto de Infraestructura | Costo mensual y restricciones de licencias |
| Reportería | Solo si el sistema genera reportes PDF/XLS/CSV |

### Notas

- El ADC es **opcional** para `/strategic-design-sdd`; sin él, el SDD se basa únicamente en el SRS.
- Cuando se provee, el ADC tiene **precedencia** sobre lo inferido del SRS: sus decisiones son restricciones del proyecto, no sugerencias.

---

## Paso 5 — Etapa SDLC: Diseño Estratégico

**Skill:** `/strategic-design-sdd`  
**Entrada:** SRS generado en el Paso 3 + ADC generado en el Paso 4 (opcional)  
**Salida:** tres documentos en `docs/strategic-design/`

### Instrucciones

Sin argumentos (usa automáticamente el SRS de `docs/requirements/` sin ADC):

```
/strategic-design-sdd
```

Con SRS explícito:

```
/strategic-design-sdd docs/requirements/SRS-<nombre-proyecto>.md
```

Con SRS y ADC:

```
/strategic-design-sdd docs/requirements/SRS-<nombre-proyecto>.md docs/planning/ADC-<nombre-proyecto>.md
```

### Qué genera

Tres documentos complementarios que conforman el **Strategic Design Document (SDD)**:

#### `SDD-<proyecto>-domain.md` — Dominio y Comportamiento

1. Introducción
2. Visión del Dominio
3. Ubiquitous Language
4. Bounded Contexts
5. Context Map
6. Modelos de Dominio
7. Eventos de Dominio (`DE-001`, `DE-002`…)
8. Workflows de Negocio
9. Criterios de Aceptación — ATDD (`AC-001`…)
10. Escenarios BDD (formato Gherkin)

#### `SDD-<proyecto>-security.md` — Seguridad

1. Modelo de Seguridad (principios, identidad, autorización, datos sensibles)
2. Threat Modeling (tabla STRIDE: `TH-001`…)
3. Trust Boundaries (zonas de confianza y flujos que las cruzan)

#### `SDD-<proyecto>-architecture.md` — Estrategia Arquitectónica

1. Drivers Arquitectónicos (atributos de calidad, restricciones, cross-cutting concerns)
2. Decisiones Estratégicas (`DS-001`, `DS-002`…)
3. Riesgos y Tradeoffs
4. Recomendación y Próximos Pasos

### Notas

- Los escenarios BDD incluyen obligatoriamente camino feliz **y** escenarios de error.
- Si el ADC declara CQRS, el SDD incorpora las decisiones encadenadas de segregación write/read, Projection Service y read model relacional.
- Si el ADC declara reportería, el SDD materializa el subsistema ETL Spark + capa serverless de formatos.
- El SDD queda listo para iniciar la etapa de Diseño Técnico del Sistema.

---

## Paso 6 — Etapa SDLC: Diseño Técnico del Sistema

**Skill:** `/technical-design-sdd`  
**Entrada:** documentos del Diseño Estratégico generados en el Paso 5 (buscados automáticamente en `docs/strategic-design/`)  
**Salida:** tres documentos `.md` + cuatro artefactos independientes en `docs/design/`

### Instrucciones

Sin argumentos (lee automáticamente los SDD de `docs/strategic-design/`):

```
/technical-design-sdd
```

Con ruta explícita:

```
/technical-design-sdd docs/strategic-design/
/technical-design-sdd docs/strategic-design/SDD-<nombre-proyecto>-architecture.md
```

### Qué genera

Tres documentos técnicos complementarios y cuatro artefactos independientes:

#### `SDD-<proyecto>-system.md` — Arquitectura del Sistema

1. Introducción
2. Arquitectura General + diagramas C4 (contexto y contenedores en Mermaid)
3. Stack Tecnológico — K3s, Terraform + provider Helm, Keycloak, HashiCorp Vault, Kong Gateway, Gitea, Jenkins, ArgoCD, MinIO
4. Componentes del Sistema
5. Diseño de Módulos

#### `SDD-<proyecto>-design.md` — Diseño Técnico

1. Diseño de APIs (referencia a `openapi.yaml`)
2. Diseño de Persistencia — patrón Database-per-Service; changelogs Liquibase en repo `<proyecto>-migrations`; `init-databases.sh`
3. Flujos Técnicos Principales (incluyendo flujos de Saga con Camel + Narayana LRA si aplica)
4. Diseño de Seguridad Técnica
5. Especificación de Pruebas ATDD (trazabilidad AC-xxx → prueba técnica)

#### `SDD-<proyecto>-infrastructure.md` — Infraestructura y Gobernanza

1. Infraestructura y Deployment — `base-infrastructure-builder.sh` genera `terraform/`, instala K3s y ejecuta `terraform apply` con provider Helm
2. Observabilidad y Monitoreo — kube-prometheus-stack + Loki + Promtail + Grafana Tempo
3. Consideraciones No Funcionales
4. Decisiones Técnicas (ADR) — Database-per-Service, Camel, Saga, Outbox, Vault
5. Riesgos Técnicos
6. Recomendación y Próximos Pasos — secuencia de scripts de aprovisionamiento

#### Artefactos independientes

| Artefacto | Ruta |
|-----------|------|
| Diagrama C4 Contexto (Mermaid) | `docs/design/diagrams/SDD-<proyecto>-c4-context.mmd` |
| Diagrama C4 Contenedores (Mermaid) | `docs/design/diagrams/SDD-<proyecto>-c4-container.mmd` |
| Especificación OpenAPI 3.0 | `docs/design/api/SDD-<proyecto>-openapi.yaml` |
| Modelo de datos SQL (DDL) | `docs/design/database/SDD-<proyecto>-schema.sql` |
| Modelo MongoDB (colecciones) | `docs/design/database/SDD-<proyecto>-collections.js` |

### Notas

- El stack del framework es fijo: K3s + Terraform + Helm (ambos entornos `local` y `prod`); sin EKS, sin AWS Cognito, sin floci.
- Si el ADC declara CQRS, se generan decisiones encadenadas: Projection Service (Spring Boot reactivo) + `<prefix>_readmodel` (PostgreSQL) + `report-etl-service` (Spark batch).
- Si el ADC declara integración con sistemas externos, el diagrama C4 incluye el `integration-service` (Apache Camel) entre los microservicios y los sistemas externos.
- El `schema.sql` usa comentarios `-- BC-XX:` para delimitar tablas por microservicio; cada bloque es el input del changelog Liquibase `00001_initial_schema.yaml` del repo `<proyecto>-migrations`.

---

## Paso 7 — Etapa SDLC: Implementación

**Skill:** `/development-plan`  
**Entrada:** documentos del Diseño Técnico generados en el Paso 6 (buscados automáticamente en `docs/design/`)  
**Salida:** conjunto de planes de desarrollo en `docs/development/`

### Instrucciones

Sin argumentos (lee automáticamente los artefactos de `docs/design/`):

```
/development-plan
```

Con ruta explícita:

```
/development-plan docs/design/
/development-plan docs/design/SDD-<nombre-proyecto>-system.md
```

### Qué genera

Un **roadmap maestro** y planes de desarrollo detallados por etapa, en el siguiente orden:

| Documento | Etapa | Descripción |
|-----------|-------|-------------|
| `DEV-<proyecto>-roadmap.md` | Roadmap | Índice maestro, secuencia de etapas, mapa de microservicios y features |
| `DEV-<proyecto>-00-infrastructure.md` | Etapa 0 | K3s + Terraform + Helm: `base-infrastructure-builder.sh` genera `terraform/`, instala K3s, deploya todo con provider Helm |
| `DEV-<proyecto>-0c-observability.md` | Etapa 0c | Verificación del stack de observabilidad instalado en Etapa 0: Prometheus, Grafana, Loki, Promtail, Grafana Tempo (OTEL → `tempo.observability.svc.cluster.local:4317`) |
| `DEV-<proyecto>-01-databases.md` | Etapa 1 | BDs aisladas por servicio con `init-databases.sh`; changelogs Liquibase via `run-liquibase-migrations.sh` |
| `DEV-<proyecto>-02-scaffold.md` | Etapa 2 | Scaffolding con `scaffold-all-services.sh`; secrets en HashiCorp Vault con `create-all-secrets-vault.sh` |
| `DEV-<proyecto>-02b-cicd.md` | Etapa 2b | Pipeline CI/CD: Jenkins (pod K3s) + ArgoCD (Git generator sobre `<org>-helm-charts`) |
| `DEV-<proyecto>-03-ms-<servicio>.md` | Etapa 3 | Un documento por microservicio (TDD capa a capa: dominio → aplicación → infraestructura → rest-api) |
| `DEV-<proyecto>-04-fe-<feature>.md` | Etapa 4 | Un documento por feature frontend (TDD: schemas Zod → hooks TanStack → componentes → E2E Playwright) |
| `DEV-<proyecto>-05-tests.md` | Etapa 5 | Pruebas de integración y contrato entre servicios; saga (happy path y compensación); WireMock para sistemas externos |

### Ambiente objetivo

Todos los documentos generados apuntan al ambiente K3s del VPS:

| Componente | Endpoint | Namespace K3s |
|-----------|----------|---------------|
| Gitea (registry + SCM) | `http://VPS_IP:3000` | `cicd` |
| Jenkins | `http://VPS_IP:8080` | `cicd` |
| ArgoCD | `http://VPS_IP:8081` | `cicd` |
| Keycloak | `http://VPS_IP:8082` | `identity` |
| HashiCorp Vault | `http://VPS_IP:8200` | `secrets` |
| Kong Gateway (proxy) | `http://VPS_IP:8000` | `gateway` |
| MinIO | `http://VPS_IP:9000` | `infra` |
| Prometheus | `http://VPS_IP:9090` | `observability` |
| Grafana | `http://VPS_IP:3001` | `observability` |

### Separación de responsabilidades en pruebas

| Nivel | Tipo | Responsable | Skill / Etapa |
|---|---|---|---|
| Unitarias (TDD) | Por capa: dominio, aplicación, infraestructura, REST | Desarrolladores | Etapas 3 y 4 de `/development-plan` |
| Integración | Contratos entre servicios, Kafka, saga, WireMock | Desarrolladores | Etapa 5 de `/development-plan` |
| Aceptación (ATDD/BDD) | Criterios AC-xxx del SDD materializados en Cucumber | QA | `/testing-plan` |
| E2E | Flujos completos de usuario con Playwright y REST Assured | QA | `/testing-plan` |
| Carga y Estrés | k6 contra los servicios críticos en K3s VPS | QA / Performance | `/testing-plan` |

### Notas

- **TDD obligatorio y transversal**: ningún componente se implementa sin una prueba previa (Red-Green-Refactor). Backend: JUnit 5 + StepVerifier + Testcontainers + WebTestClient. Frontend: Vitest + RTL + MSW + Playwright.
- Los microservicios usan Spring Boot reactivo (WebFlux / R2DBC); sus `application.yml` leen configuración desde Vault (`spring.config.import: optional:vault://…`).
- La autenticación usa **Keycloak** (OAuth2/OIDC); el frontend apunta a `KEYCLOAK_URL` y las APIs se exponen vía **Kong Gateway**.
- Los Helm charts de cada servicio se gestionan en el repo `<org>-helm-charts` en Gitea; ArgoCD los auto-descubre con un Git generator.
- Entornos: `local` (VM QEMU/KVM) y `prod` (Oracle Cloud OCI); sin EKS, sin floci, sin AWS Cognito.

---

## Paso 8 — Etapa SDLC: Testing QA

**Skill:** `/testing-plan`  
**Entrada:** Strategic Design (`docs/strategic-design/`) + Development Plan (`docs/development/`)  
**Salida:** cuatro documentos en `docs/testing/`

### Instrucciones

Sin argumentos (lee automáticamente desde `docs/strategic-design/` y `docs/development/`):

```
/testing-plan
```

Con rutas explícitas:

```
/testing-plan docs/strategic-design/
/testing-plan docs/strategic-design/ docs/development/
```

### Qué genera

| Documento | Descripción |
|-----------|-------------|
| `QA-<proyecto>-plan.md` | Plan maestro: pirámide de pruebas, herramientas, stages Jenkins (`runAcceptanceTests`, `runE2ETests`, `runPerformanceTests`), tabla de trazabilidad AC-xxx → test, Definición de Done QA |
| `QA-<proyecto>-acceptance.md` | Pruebas de aceptación ATDD/BDD: materializa los criterios AC-xxx y escenarios Gherkin del `/strategic-design-sdd` en suites Cucumber (Java + REST Assured para API, Playwright para UI) |
| `QA-<proyecto>-e2e.md` | Pruebas E2E: flujos de usuario completos con Playwright (Page Object Model) y REST Assured contra Kong proxy; incluye checklist de verificación de observabilidad E2E (Grafana Tempo, Prometheus, Loki) |
| `QA-<proyecto>-performance.md` | Pruebas de rendimiento: carga sostenida y estrés con k6; scripts concretos por servicio, thresholds derivados de los SLAs del SDD, correlación con Grafana/Prometheus, gate manual en Jenkins |

### Fuentes del plan de pruebas

| Artefacto fuente | Qué aporta al plan QA |
|---|---|
| `SDD-<proyecto>-domain.md §9` | Criterios de aceptación AC-xxx (éxito y error) → `acceptance.md` |
| `SDD-<proyecto>-domain.md §10` | Escenarios BDD Gherkin → archivos `.feature` en `qa/acceptance/` |
| `SDD-<proyecto>-domain.md §8` | Workflows de negocio → flujos E2E Playwright en `qa/e2e/` |
| `SDD-<proyecto>-architecture.md §1` | SLAs y atributos de calidad → thresholds k6 en `qa/performance/` |
| `SDD-<proyecto>-security.md §1` | Tabla de roles → usuarios de prueba en Keycloak |
| `DEV-<proyecto>-roadmap.md` | Mapa de microservicios y puertos → servicios candidatos a pruebas de rendimiento |
| `DEV-<proyecto>-00-infrastructure.md` | VPS_IP y endpoints concretos → `BASE_URL`, `KEYCLOAK_URL`, `GRAFANA_URL` |

### Herramientas QA integradas

| Tipo | Herramienta | Integración |
|---|---|---|
| Aceptación / BDD | Cucumber 7 (Java) + REST Assured 5 | Stage `runAcceptanceTests` en Jenkins Shared Library |
| Aceptación UI | `@cucumber/cucumber` + Playwright | Stage `runAcceptanceTests` en Jenkins Shared Library |
| E2E Frontend | Playwright (TypeScript) + Page Object Model | Stage `runE2ETests` en Jenkins (paralelo con API) |
| E2E Backend | REST Assured (Java) | Stage `runE2ETests` en Jenkins (paralelo con Playwright) |
| Mocking externos | WireMock (pod K3s, namespace `infra`) | Usado en aceptación y E2E; no mocks en memoria |
| Carga y Estrés | k6 + Prometheus Remote Write | Stage `runPerformanceTests` (manual gate en Jenkins) |
| Observabilidad E2E | Grafana Tempo + Prometheus + Loki | Checklist post-E2E; resultados k6 visibles en Grafana |

### Notas

- Los criterios ATDD (AC-xxx) y los escenarios BDD se extraen **exactamente** del `/strategic-design-sdd` — no se inventan criterios nuevos en esta etapa.
- Las pruebas de rendimiento apuntan siempre a **Kong proxy** (`VPS_IP:8000`), nunca directamente a los puertos de los microservicios.
- El stage `runPerformanceTests` usa un `input` step en Jenkins (aprobación manual) para evitar interferir con otros pipelines que usen el mismo ambiente K3s.
- Las pruebas de estrés se ejecutan **solo en el ambiente local** (K3s VPS QEMU/KVM). Nunca contra producción sin autorización.

---

## Estructura de Directorios

```
sdlc-framework-saas/
├── requerimiento/                  # Paso 1: requerimientos diligenciados por el cliente
├── docs/
│   ├── planning/                   # Pasos 2 y 4: PIDs y ADCs del proyecto
│   ├── requirements/               # Paso 3: SRS generados por /requirements-srs
│   ├── strategic-design/           # Paso 5: SDD generados por /strategic-design-sdd
│   │   ├── SDD-<proyecto>-domain.md
│   │   ├── SDD-<proyecto>-security.md
│   │   └── SDD-<proyecto>-architecture.md
│   ├── design/                     # Paso 6: SDD técnicos generados por /technical-design-sdd
│   │   ├── SDD-<proyecto>-system.md
│   │   ├── SDD-<proyecto>-design.md
│   │   ├── SDD-<proyecto>-infrastructure.md
│   │   ├── diagrams/
│   │   │   ├── SDD-<proyecto>-c4-context.mmd
│   │   │   └── SDD-<proyecto>-c4-container.mmd
│   │   ├── api/
│   │   │   └── SDD-<proyecto>-openapi.yaml
│   │   └── database/
│   │       ├── SDD-<proyecto>-schema.sql
│   │       └── SDD-<proyecto>-collections.js
│   ├── development/                # Paso 7: planes generados por /development-plan
│   │   ├── DEV-<proyecto>-roadmap.md
│   │   ├── DEV-<proyecto>-00-infrastructure.md
│   │   ├── DEV-<proyecto>-0c-observability.md
│   │   ├── DEV-<proyecto>-01-databases.md
│   │   ├── DEV-<proyecto>-02-scaffold.md
│   │   ├── DEV-<proyecto>-02b-cicd.md
│   │   ├── DEV-<proyecto>-03-ms-<servicio>.md
│   │   ├── DEV-<proyecto>-04-fe-<feature>.md
│   │   └── DEV-<proyecto>-05-tests.md
│   └── testing/                    # Paso 8: plan QA generado por /testing-plan
│       ├── QA-<proyecto>-plan.md
│       ├── QA-<proyecto>-acceptance.md
│       ├── QA-<proyecto>-e2e.md
│       └── QA-<proyecto>-performance.md
└── .claude/
    ├── formatos/
    │   ├── input-template.md           # Plantilla de captura del requerimiento (Paso 1)
    │   └── input-adc-template.md       # Plantilla de contexto arquitectónico (Paso 4)
    ├── scripts/                        # Scripts de automatización de infraestructura
    │   ├── base-infrastructure-builder.sh   # K3s + Terraform + Helm
    │   ├── init-databases.sh               # Database-per-Service (PostgreSQL/MongoDB K3s)
    │   ├── create-all-secrets-vault.sh     # Secrets en HashiCorp Vault
    │   ├── run-liquibase-migrations.sh     # Migraciones Liquibase standalone
    │   ├── scaffold-all-services.sh        # Scaffolding de microservicios y frontend
    │   ├── setup-cicd-pipeline.sh          # Jenkins + ArgoCD pipeline
    │   ├── jenkins-shared-library-builder.sh
    │   └── init-dev-environment.sh         # Verificación del ambiente
    ├── templates/                      # Scaffolders de proyectos
    │   ├── maven_hexagonal_scaffold.py     # Spring Boot hexagonal (Maven)
    │   ├── scala_hexagonal_scaffold.py     # Spark/Scala hexagonal (sbt)
    │   ├── integration_service_scaffold.py # Apache Camel + Saga
    │   ├── nextjs_feature_scaffold.py      # Next.js feature-based
    │   └── report_lambdas_scaffold.py      # Lambdas de formatos PDF/XLS/CSV
    └── skills/
        ├── plan-pid/                   # Skill de planeación
        ├── requirements-srs/           # Skill de análisis de requerimientos
        ├── strategic-design-sdd/       # Skill de diseño estratégico
        ├── technical-design-sdd/       # Skill de diseño técnico
        ├── development-plan/           # Skill de plan de implementación
        ├── testing-plan/               # Skill de plan de pruebas QA
        └── observability-plan/         # Skill de plan de observabilidad
```

---

## Etapas del SDLC Implementadas

| # | Etapa | Skill | Salida principal | Estado |
|---|-------|-------|-----------------|--------|
| 1 | Captura de requerimiento | — (template manual) | `requerimiento/<proyecto>.md` | Disponible |
| 2 | Planeación | `/plan-pid` | `docs/planning/PID-<proyecto>.md` | Disponible |
| 3 | Análisis de Requerimientos | `/requirements-srs` | `docs/requirements/SRS-<proyecto>.md` | Disponible |
| 4 | Contexto Arquitectónico | — (template manual ADC) | `docs/planning/ADC-<proyecto>.md` | Disponible |
| 5 | Diseño Estratégico | `/strategic-design-sdd` | `docs/strategic-design/SDD-<proyecto>-*.md` (×3) | Disponible |
| 6 | Diseño Técnico del Sistema | `/technical-design-sdd` | `docs/design/SDD-<proyecto>-*.md` (×3) + artefactos | Disponible |
| 7 | Implementación | `/development-plan` | `docs/development/DEV-<proyecto>-*.md` (roadmap + etapas) | Disponible |
| 8 | Testing QA | `/testing-plan` | `docs/testing/QA-<proyecto>-*.md` (×4) | Disponible |
| 9 | Despliegue | — | — | Próximamente |
| 10 | Mantenimiento | — | — | Próximamente |
