# Oliva

A full-stack web application boilerplate — decoupled backend and frontend, fully containerized, production-ready out of the box.

![PHP](https://img.shields.io/badge/PHP-Symfony%207-black?style=flat-square&logo=symfony)
![FrankenPHP](https://img.shields.io/badge/Runtime-FrankenPHP-5C2D91?style=flat-square)
![Vite](https://img.shields.io/badge/Frontend-Vite-646CFF?style=flat-square&logo=vite&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/Database-PostgreSQL%2015-336791?style=flat-square&logo=postgresql&logoColor=white)
![Docker](https://img.shields.io/badge/Infrastructure-Docker%20Compose-2496ED?style=flat-square&logo=docker&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

---

## Stack

| Layer | Technology |
|---|---|
| Backend | Symfony 7 · FrankenPHP (worker mode) · Caddy · JWT Auth |
| Frontend | Vite · Vanilla JS · Bootstrap 5 · Swiper · SweetAlert2 |
| Database | PostgreSQL 15 |
| Infrastructure | Docker Compose · Bridge Network · Multi-stage builds |

---

## Getting started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with Compose v2.10+

### Development

```bash
git clone https://github.com/Markk-hyphen/oliva.git
cd oliva
cp .env.example .env
# fill in your values in .env, .env.backend, .env.frontend
docker compose up
```

| Service | URL |
|---|---|
| Frontend | http://localhost:3000 |
| Backend API | http://localhost:80/api |
| Database | localhost:5432 |

Hot reload is enabled — changes to `backend/src` and `frontend/src` reflect instantly without rebuilding.

### Production

```bash
# Build production images
docker compose -f docker-compose.yml -f docker-compose.prod.yml build

# Start
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

The frontend is served by Caddy on **http://localhost**. The backend and database are internal — never directly reachable from outside.

---

## Project structure

```
oliva/
├── backend/          # Symfony 7 app (FrankenPHP + Caddy)
│   ├── src/
│   ├── config/
│   └── frankenphp/   # Caddy and PHP runtime config
├── frontend/         # Vite app
│   ├── src/
│   └── Caddyfile     # Production static file server config
├── docker-compose.yml
├── docker-compose.override.yml   # Dev overrides (auto-applied)
├── docker-compose.prod.yml       # Production overrides
├── .env.example
├── .env.backend
└── .env.frontend
```

---

## Environment variables

Copy `.env.example` to `.env` and fill in your values. Key variables:

| Variable | Description |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Database credentials |
| `APP_SECRET` | Symfony secret key |
| `JWT_PASSPHRASE` | JWT signing passphrase |
| `SERVER_NAME` | Domain name (default: `localhost`) |
| `APP_ENV` | `development` or `production` |

---

## Architecture

```
Browser
  │  HTTP
  ▼
Frontend (Caddy · Vite)
  │  /api/*
  ▼
Backend (FrankenPHP · Symfony)
  │  SQL
  ▼
PostgreSQL
```

The frontend proxies all `/api/*` requests to the backend over the internal Docker bridge network. The backend is never exposed on a public port in production.

---

## License

MIT
