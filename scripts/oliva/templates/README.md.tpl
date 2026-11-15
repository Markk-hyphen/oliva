# {{APP_NAME}}

<!-- What this app does, in two or three lines. -->

Built on [Oliva](https://github.com/Markk-hyphen/oliva) {{OLIVA_VERSION}}.

## Run it

```bash
./oliva env init              # creates .env with generated secrets (only what is missing)
docker compose up -d --wait
./oliva doctor
```

| Service | URL (dev) |
|---|---|
| Frontend | http://localhost:3000 |
| Backend | http://localhost/health · your routes go under `/api` |
| Mercure hub | http://localhost/.well-known/mercure |
| Database | localhost:5432 |

## Work on it

```bash
docker compose exec backend bin/console make:entity
docker compose exec backend bin/console make:migration
docker compose exec backend bin/console doctrine:migrations:migrate
./oliva verify                # everything CI checks, before you push
```

## Keep it current

```bash
./oliva sync check            # did Oliva move ahead?
./oliva sync start            # bring it in
```

How the framework works, deploys and updates: `docs/oliva/`.
