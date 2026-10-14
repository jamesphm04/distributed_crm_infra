# distributed_crm_infra

Local-dev orchestration and cross-repo documentation for the `distributed_crm` project.

This repo deliberately holds no application code.
It exists because `distributed_crm_be`, `distributed_crm_worker`, and `distributed_crm_fe` are independently deployed, independently versioned repos — nothing here implies they share a deploy pipeline.

## Contents

- `docker-compose.yml` — brings up the full local stack: Postgres, Redis, RabbitMQ, and the containerized `be`/`worker` apps (built from `../distributed_crm_be` and `../distributed_crm_worker`).
- `docs/` — project-wide documentation that doesn't belong to any single service: architecture, decisions, glossary, progress, setup.

## Usage

Run from this folder:

```
docker compose up -d
```

Expects to sit alongside `distributed_crm_be`, `distributed_crm_worker`, and `distributed_crm_fe` as sibling folders (see `build:` paths in `docker-compose.yml`).
