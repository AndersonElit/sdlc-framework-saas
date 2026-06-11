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

## Estructura de Directorios

```
sdlc-framework-saas/
├── requerimiento/                  # Paso 1: requerimientos diligenciados por el cliente
├── docs/
│   ├── planning/                   # Paso 2 y 4: PIDs y ADCs del proyecto
│   ├── requirements/               # Paso 3: SRS generados por /requirements-srs
│   └── strategic-design/           # Paso 5: SDD generados por /strategic-design-sdd
│       ├── SDD-<proyecto>-domain.md
│       ├── SDD-<proyecto>-security.md
│       └── SDD-<proyecto>-architecture.md
└── .claude/
    ├── formatos/
    │   ├── input-template.md           # Plantilla de captura del requerimiento (Paso 1)
    │   └── input-adc-template.md       # Plantilla de contexto arquitectónico (Paso 4)
    └── skills/
        ├── plan-pid/                   # Skill de planeación
        ├── requirements-srs/           # Skill de análisis de requerimientos
        └── strategic-design-sdd/       # Skill de diseño estratégico
```

---

## Etapas del SDLC Implementadas

| # | Etapa | Skill | Estado |
|---|-------|-------|--------|
| 1 | Captura de requerimiento | — (template manual) | Disponible |
| 2 | Planeación | `/plan-pid` | Disponible |
| 3 | Análisis de Requerimientos | `/requirements-srs` | Disponible |
| 4 | Contexto Arquitectónico | — (template manual ADC) | Disponible |
| 5 | Diseño Estratégico | `/strategic-design-sdd` | Disponible |
| 6 | Diseño Técnico del Sistema | — | Próximamente |
| 7 | Desarrollo | — | Próximamente |
| 8 | Pruebas | — | Próximamente |
| 9 | Despliegue | — | Próximamente |
| 10 | Mantenimiento | — | Próximamente |
