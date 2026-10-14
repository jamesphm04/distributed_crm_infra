# distributed_crm — docs index

This is the orchestrator for the whole project.
It ties together the independent app repos and the backing services they share.
Start here, then follow the links below into whichever doc has what you need.

## What this project is

A learning project for scalable distributed system architecture, built one phase at a time.
The domain is deliberately small — a single `ReturnRequest` entity — so the focus stays on the infrastructure patterns, not business complexity.
See [`../../CLAUDE.md`](../../CLAUDE.md) for the project conventions and the phase roadmap. This project is a thin rehearsal of the WCP RMA & Credits portal: every component the real portal will use gets touched here first.

## The docs

- [`setup.md`](setup.md) — how to get this running on a new machine, from a clean clone to a working local stack.
- [`architecture.md`](architecture.md) — how the system is built today: the repos, the backing services, the RabbitMQ topology, the Redis caching/idempotency design, Google sign-in, the Postgres schema.
- [`decisions.md`](decisions.md) — an ADR-style log of *why* the non-obvious choices were made (claim-then-finalize idempotency, cache-aside + TTL + invalidation, the three-exchange retry/DLX pattern, why the worker doesn't share code with the API, how Google sign-in is validated).
- [`progress.md`](progress.md) — phase-by-phase status against the learning goals in `CLAUDE.md`, kept current as work lands.
- [`glossary.md`](glossary.md) — terminology introduced along the way (exchange, queue, DLX/DLQ, ack/nack, TTL, idempotency, cache-aside, JWT, JWKS, and so on), written for someone new to distributed systems.

## Where this lives

This `docs/` folder lives in the `distributed_crm_infra` repo, alongside `docker-compose.yml` — not inside any of the app repos, because it documents the system as a whole.
`CLAUDE.md` stays at the `distributed_crm/` section root so Claude Code finds it from inside any of the repos; that one file is not tracked by git.
