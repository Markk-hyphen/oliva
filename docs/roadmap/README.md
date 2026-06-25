# Roadmap de Oliva

Espacio de planificación y seguimiento de versiones del framework. La doc humana
del stack vive en `README.md`; la guía operativa para agentes en `CLAUDE.md`.
Acá vive **hacia dónde va Oliva y en qué orden**.

## Cómo está organizado

| Carpeta / archivo | Qué contiene |
|---|---|
| `README.md` (este) | Roadmap general: visión, criterio de versionado, mapa epics × versiones, estado global. |
| `backlog.md` | Embudo de ideas entrantes todavía no asignadas a una versión. |
| `epics/` | Planes detallados por **eje** de trabajo. Un eje es un cuerpo largo que cruza varias versiones. |
| `versions/` | Un doc por **release** (0.x / mayor): alcance, changelog, check del criterio, tag. |
| `v1/` | Registro histórico del trabajo ya cerrado en la línea v1. |

> **Dos ejes que se cruzan.** Los *epics* son el **qué/cómo** (estables, largos).
> Las *versiones* son el **cuándo** (cortes que agrupan slices de epics y se
> cierran como release con tag). Un mismo epic puede aportar a varias versiones.

## Versionado y criterio de release (semver-ish)

- **Mayor (1.0 → 2.0):** cambia *cómo se consume/instala* Oliva. Hoy el único
  major en el horizonte es v2.0 (Eje A — flags en instalación).
- **Minor (0.x):** mejoras incrementales que no rompen el modelo de consumo.

### Criterio: qué hace **oficial** a una 0.x (híbrido)

Una subversión 0.x existe como release oficial cuando cumple **todo** esto:

1. **Entregable cerrado:** cierra al menos un *slice de eje* completo y probado —
   nada de trabajo a medias.
2. **Piso de sustancia:** no se bumpea un minor por un único cambio trivial,
   aunque esté cerrado. Cosméticos/docs sueltos van pegados al próximo release.
3. **Gates:** mergeado a `main`, CI verde, **tag anotado** `vX.Y`, y entrada en
   `versions/vX.Y.md` con changelog.

> Si un cambio no llega a 1+2, no nace como versión: se acumula. El objetivo es
> que cada 0.x signifique algo, no inflar el contador.

## Estado global

| Versión | Estado | Contenido | Tag |
|---|---|---|---|
| v1.0 | ✅ released | Base reutilizable: profiles para servicios opcionales + claude-commands | `v1.0` |
| v1.1 | 🟡 planned | Eje B — modelo de upgrade de forks (slice) | — |
| v1.2 | ⚪ planned | Eje C — worker de producción | — |
| v2.0 | ⚪ planned | Eje A — flags en instalación (major) | — |

## Mapa epics × versiones

| Epic | v1.1 | v1.2 | v2.0 |
|---|---|---|---|
| **A** — flags en instalación | — | — | ●  (justifica el major) |
| **B** — modelo de upgrade de forks | ●  (slice inicial) | — | (puede seguir) |
| **C** — worker de producción | — | ● | — |
| **D** — manejo de secretos | — | — | — (sin asignar; espera disparador) |

> El mapa es vivo: cuando un epic crece o entra uno nuevo, se reasigna acá. Las
> celdas no son contratos, son la secuencia tentativa actual.

## Secuencia y razón del orden

1. **v1.1 → Eje B.** Es liviano y lo estamos *viviendo* ahora (port de v1 a
   finanzas-ong). Conviene capturar tags + criterio de port mientras está fresco.
2. **v1.2 → Eje C.** Acotado: definir el `worker` de prod (hoy solo existe en
   dev/override).
3. **v2.0 → Eje A.** El grande: que instalar/forkear Oliva pregunte qué servicios
   incluir, en vez de heredar todo y apagar con profiles. Cambia el modelo de
   instalación → amerita major.

## Cómo se agregan cosas

- **Idea nueva sin madurar** → `backlog.md`.
- **Idea que se vuelve un cuerpo de trabajo** → se promueve a `epics/<X>-<slug>.md`.
- **Cuando un slice de epic se va a cortar como release** → se crea/actualiza
  `versions/vX.Y.md` y se enlaza en el mapa de arriba.
