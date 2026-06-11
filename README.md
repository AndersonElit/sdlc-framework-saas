# SDLC Framework SaaS

Framework de automatización de las etapas del ciclo de vida del desarrollo de software (SDLC) mediante skills de Claude Code. Cada etapa produce un documento Markdown profesional que sirve como entrada para la siguiente.

---

## Flujo General

```
Requerimiento del cliente
        │
        ▼
[Paso 1] Diligenciar input-template.md  →  requerimiento/<archivo>.md
        │
        ▼
[Paso 2] /plan-pid                       →  docs/planning/PID-<proyecto>.md
        │
        ▼
[Paso 3] /requirements-srs              →  docs/requirements/SRS-<proyecto>.md
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
- El documento queda listo para pasar a la etapa de Diseño del Sistema y Arquitectura.

---

## Estructura de Directorios

```
sdlc-framework-saas/
├── requerimiento/              # Paso 1: requerimientos diligenciados por el cliente
├── docs/
│   ├── planning/               # Paso 2: PIDs generados por /plan-pid
│   └── requirements/           # Paso 3: SRS generados por /requirements-srs
└── .claude/
    ├── formatos/
    │   ├── input-template.md       # Plantilla de captura del requerimiento
    │   └── input-adc-template.md   # Plantilla de contexto arquitectónico (ADC)
    └── skills/
        ├── plan-pid/               # Skill de planeación
        └── requirements-srs/       # Skill de análisis de requerimientos
```

---

## Etapas del SDLC Implementadas

| # | Etapa | Skill | Estado |
|---|-------|-------|--------|
| 1 | Captura de requerimiento | — (template manual) | Disponible |
| 2 | Planeación | `/plan-pid` | Disponible |
| 3 | Análisis de Requerimientos | `/requirements-srs` | Disponible |
| 4 | Diseño del Sistema y Arquitectura | `/strategic-design-sdd` | Próximamente |
| 5 | Desarrollo | — | Próximamente |
| 6 | Pruebas | — | Próximamente |
| 7 | Despliegue | — | Próximamente |
| 8 | Mantenimiento | — | Próximamente |
