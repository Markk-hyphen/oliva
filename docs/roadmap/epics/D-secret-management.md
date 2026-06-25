# Epic D — Manejo de secretos

> **Estado:** 💡 idea · **Versión destino:** sin asignar (candidato v2.x) ·
> **Origen:** sesión 2026-06, fix `DATABASE_URL` → `.env.backend` (commit del
> deploy de finanzas-ong con infra compartida).

## Problema

Oliva hoy **no tiene estrategia de manejo de secretos**: viven en texto plano en
archivos versionados (`.env.backend` trae `APP_SECRET`, `JWT_PASSPHRASE`, claves
Mercure; `.env.example` los placeholders). Funciona, pero arrastra dos costos:

1. **Duplicación de credenciales (footgun de standalone).** En modo standalone,
   `DATABASE_URL` (en `.env.backend`) y `POSTGRES_USER/PASSWORD/DB` (en `.env`,
   porque se interpolan en `docker-compose.yml`) describen **el mismo Postgres**:
   son la misma password escrita dos veces, en dos archivos, que deben coincidir
   a mano. En infra compartida la asimetría se invierte (`DATABASE_URL` es la
   fuente única y `POSTGRES_*` quedan inertes), pero el riesgo de desincronizar
   sigue ahí mientras la credencial esté duplicada.
2. **Secretos en claro en el repo.** No es solo la DB: todos los secretos del
   backend están commiteados. Para 1-3 apps en un VPS propio es tolerable; deja
   de serlo apenas haya colaboradores, CI con secretos reales, o rotación.

El fix de la sesión 2026-06 (mover `DATABASE_URL` a `.env.backend`, matar la
`BACKEND_DATABASE_URL` muerta, documentar la regla de coincidencia) **resolvió
la confusión**, no la duplicación. Eso es lo que este epic ataca de fondo.

## Visión

Adoptar **una** estrategia de secretos cuando el dolor lo justifique — no
construir maquinaria bespoke antes de tiempo. La tecnología para esto ya existe;
la decisión es *cuál* y *cuándo*, no *inventarla*. Opciones, de barata a robusta:

| Opción | Qué resuelve | Costo / encaje |
|---|---|---|
| **B (tactical) — derivar `DATABASE_URL` de `POSTGRES_*`** por interpolación en el `environment:` del backend (`docker-compose.yml`), y que el overlay shared-infra la pise | Solo la duplicación standalone de la DB | Barato, cero deps nuevas. No toca el resto de secretos. Tapa un agujero, no la categoría |
| **Docker Compose secrets** (`secrets:` + archivos montados, convención `*_FILE`) | Saca *todos* los secretos de env/imágenes a archivos fuera del repo | Medio. Symfony necesita un bootstrap chico para leer `*_FILE` |
| **Symfony Secrets vault** (`secrets:set`, vault encriptado en `config/secrets/`, una `SYMFONY_DECRYPTION_SECRET` en runtime) | Encripta *todo*, versionable encriptado, una sola llave que manejar | Medio. **Encaje nativo** — Oliva ES Symfony. Candidato fuerte |
| **Manager externo** (Vault / Doppler / Infisical / SOPS) | Centraliza secretos multi-app/multi-entorno con rotación y auditoría | Alto. Overkill para 1-3 apps; recién a escala o con equipo |

## Decisión pendiente (no cerrar antes de tiempo)

- **¿Vale B como paso intermedio, o se salta directo a una solución de
  categoría?** B arregla un solo síntoma; si la próxima necesidad real es "no
  quiero secretos en el repo", B no aporta y conviene ir directo a Symfony
  Secrets / Docker secrets.
- **Disparador para tomarlo en serio:** primer colaborador externo, CI con
  secretos de prod reales, o necesidad de rotar credenciales sin redeploy manual.
  Mientras sea Marcos solo en su VPS, la duplicación documentada es tolerable.

## Slices candidatos

- [ ] (tactical, opcional) Derivar `DATABASE_URL` de `POSTGRES_*` por
  interpolación en standalone; verificar que el overlay shared-infra la pisa.
- [ ] Evaluar Symfony Secrets vault como estrategia de fondo (PoC: mover
  `APP_SECRET`/`JWT_PASSPHRASE` al vault, una llave de runtime).
- [ ] Decidir si `.env.backend` deja de versionarse (pasar a `.env.backend.example`
  + archivo real gitignored, como ya se hace con `.env`).

> **Scope guard:** no empezar hasta que aparezca el disparador. El fix de la
> sesión 2026-06 ya dejó el sistema *correcto y documentado*; esto es robustez,
> no corrección. No mezclar con el Eje A (instalación).
