# Shortify — URL shortener

A minimal URL shortener built with FastAPI + PostgreSQL.
Used as a learning vehicle for the Shortify DevOps project.

## Phase 1: run locally

### Prerequisites
- Docker + Docker Compose installed
- That's it

### Start the stack

```bash
docker compose up --build
```

First run takes ~1 min (downloads images, builds the app layer).
Subsequent runs are fast.

### Verify it works

```bash
# 1. Health check
curl http://localhost:8000/health

# 2. Shorten a URL
curl -X POST http://localhost:8000/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.google.com"}'

# 3. Use the short code from step 2 (e.g. "aB3xYz")
curl -L http://localhost:8000/aB3xYz

# 4. Metrics
curl http://localhost:8000/metrics
```

### Tear down

```bash
# Stop containers (keeps DB data)
docker compose down

# Stop + wipe DB volume (clean slate)
docker compose down -v
```

## Project structure

```
shortify/
├── app/
│   ├── __init__.py
│   ├── main.py        # FastAPI routes
│   ├── models.py      # SQLAlchemy model (links table)
│   └── database.py    # DB connection + session
├── Dockerfile         # Multi-stage, non-root user
├── docker-compose.yml # App + Postgres for local dev
├── requirements.txt
└── README.md
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check — returns `{"status":"ok"}` |
| GET | `/metrics` | Total link count |
| POST | `/shorten` | Create a short URL |
| GET | `/{code}` | Redirect to original URL |
