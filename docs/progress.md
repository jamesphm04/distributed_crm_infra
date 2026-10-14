# Progress

Phase numbers match the ordered learning goals in `CLAUDE.md`. Last updated 2026-10-14.

## Phase 1 — Schema + API contract — done, verified end-to-end

- `distributed_crm_be`: full Clean Architecture, all 4 `ReturnRequest` endpoints working.
- Postgres schema migrated (snake_case columns, `CHECK` constraint on status, `xmin` concurrency token).

## Phase 2 — Stateless API layer, connection-pooled Postgres — done, verified end-to-end

- Ran two `dotnet run` instances (`:5214`, `:5215`) against one shared Postgres and confirmed identical responses from both — proves no in-process state is load-bearing.
- Deliberately reproduced the failure mode first: the original `InMemoryIdempotencyStore` (a per-instance `ConcurrentDictionary`) let the same `Idempotency-Key` create two separate rows when hit on two different instances. This bug drove Phase 3.

## Phase 3 — Redis cache + invalidation — done, verified end-to-end

- `RedisIdempotencyStore` replaces the in-memory stub — atomic claim-then-finalize via `SET NX`, closing the cross-instance race.
- `RedisReturnRequestCache` — cache-aside read-through for `GetById`, 5-minute TTL, explicit invalidation on cancel.
- Verified live: cancelled a record on instance A, immediately read it from instance B, got fresh `Cancelled` data (not a stale cached `Pending` copy).
- See `decisions.md` for the reasoning behind both.

## Phase 4 — RabbitMQ + worker, retry/failure handling — done, verified end-to-end

- `RabbitMqReturnRequestQueue` (producer side) replaces `NullReturnRequestQueue`.
- Three-exchange retry/DLX topology, declared from both the API and the worker (idempotent, matching names/arguments on both sides).
- `distributed_crm_worker` fully built: Domain + Application + Infrastructure, a `ReturnRequestConsumer` that subscribes to `return-requests.process`, commits to Postgres before acking, and reads the `x-death` header to decide retry (`nack`, routed via the queue's dead-letter-exchange argument) vs. give-up (explicit publish straight to the DLX once `MaxRetries` is exceeded).
- `SimulatedApprovalApiClient` — randomized latency (200–1500ms) and failure rate (default 30%), configurable via `SimulatedApprovalApi` in `appsettings`.
- `xmin` optimistic concurrency (`DbUpdateConcurrencyException`) is caught and acked without retrying — a stale decision isn't worth re-running.
- Verified live against real Postgres + RabbitMQ:
  - Happy path: `Pending` → `Approved` in ~1.2s.
  - Failure path: forced `FailureRate` to `1.0`, watched a message cycle `process` → `retry` (sits with 0 consumers for the 30s TTL, confirmed via the management API) → `process` → ... 3 times, then land in `return-requests.dlq`. The `ReturnRequest` row correctly stayed at `Processing`, never forced into a false final state.
- **Bug found and fixed during live testing:** the producer serializes `{"returnRequestId": ...}` (camelCase), but the worker's `JsonSerializer.Deserialize` was case-sensitive by default, silently binding to `Guid.Empty` instead of throwing. Every message was being acked away as a no-op `NotFound` against the wrong id — a real record would sit in `Pending` forever with no error anywhere. Fixed by deserializing with `PropertyNameCaseInsensitive = true`. See `decisions.md`.

## Phase 5 — Docker + docker-compose for local dev — done, verified end-to-end

- `distributed_crm_be` and `distributed_crm_worker` each got a multi-stage `Dockerfile` (SDK stage restores/publishes, slim `aspnet`/`runtime` stage runs the published output only).
- `docker-compose.yml` (now living in this repo, see "Repo split" below) builds both app images and wires them onto the same Compose network as `postgres`/`redis`/`rabbitmq`, using service names instead of `localhost` for inter-service connections.
- Added `healthcheck:` blocks to `postgres`/`redis`/`rabbitmq` and changed `be`/`worker`'s `depends_on` to `condition: service_healthy`, so the app containers wait for real readiness, not just container start.
  - First healthcheck for RabbitMQ (`rabbitmq-diagnostics ping`) was insufficient — it reported healthy based on Erlang node liveness, before the AMQP listener on 5672 was actually bound. Confirmed via timestamps: `be` started 2+ seconds before RabbitMQ's listener bound. Fixed by switching to `rabbitmq-diagnostics check_port_connectivity`, which checks the actual listener ports.
- **Resilience, not just startup ordering:** `depends_on`/healthchecks are a Compose-only, local-dev convenience — they don't exist in real orchestrators (ECS, Kubernetes) and don't protect against a dependency restarting *after* the app is already running. Added defense-in-depth directly in the apps instead:
  - RabbitMQ connection: wrapped the initial `CreateConnectionAsync` in a retry loop with exponential backoff (1s → 2s → 4s ... capped at 30s, max 10 attempts), in both `be` and `worker`.
  - Postgres via EF Core: added `npgsqlOptions.EnableRetryOnFailure(maxRetryCount: 5)` to both DbContext registrations — previously any transient DB blip was an unhandled exception.
  - Both repos' RabbitMQ host was previously hardcoded to `"localhost"` in `Program.cs` — made configurable via a new `RabbitMq:Host` config key (default `"localhost"`, overridden to `rabbitmq` via Compose `environment:`), matching how Postgres/Redis connection strings already worked.
- **Security incident found and fixed during live testing:** `docker-compose.yml`'s `ports:` entries (`"5672:5672"` etc., no host IP given) bind to `0.0.0.0` — every network interface on the host, not just loopback. On James's Mac, that includes active Tailscale VPN tunnel interfaces. A RabbitMQ queue was found with two consumers instead of one; the second connection's peer address (`167.82.48.223`) matched neither James's Tailscale address nor his real public IP, confirming it was not one of his own devices. Default `guest`/`guest` credentials were reachable through a non-loopback path, bypassing RabbitMQ's own loopback-only restriction on the `guest` user. **Fixed by binding every published port explicitly to `127.0.0.1`** (e.g. `"127.0.0.1:5672:5672"`) in all four services (`postgres`, `redis`, `rabbitmq`, `be`) — verified via `lsof` that every listening socket is loopback-only afterward.
- Verified live end-to-end, fully containerized: created a return request via the containerized `be`, watched the containerized `worker` process it via the containerized Postgres/RabbitMQ, landed on `Approved`.

## Pre-deployment hardening — done, verified end-to-end

A full code review of both `be` and `worker`, requested before moving on to Phase 6, surfaced 7 real bugs.
All 7 were fixed and re-verified live against the containerized stack.

1. **`GetById` could serve a stale cached status for up to 5 minutes.**
   `worker` writes `Processing`/`Approved`/`Rejected` straight to Postgres and never invalidated `be`'s Redis cache.
   Fixed by adding `IReturnRequestCacheInvalidator`/`RedisReturnRequestCacheInvalidator` to `worker`, called right after every `SaveChangesAsync` in `ProcessReturnRequestHandler`.
   It shares no code with `be` — just the same Redis key format (`returnrequest:{id}`), documented as the one coupling point between the two repos.
   Verified live via `redis-cli monitor`: the worker's `UNLINK` fires within ~150ms of each commit.

2. **The create path wasn't atomic — a `ReturnRequest` row could get stuck at `Pending` forever.**
   `CreateReturnRequestHandler` committed the row, then published to RabbitMQ as a separate step; if the publish failed, the row was orphaned with no recovery path.
   Fixed with a transactional outbox: a new `outbox_messages` table (`OutboxMessage`/`OutboxStore`/`IOutboxStore`) is written in the *same* `SaveChangesAsync` as the `ReturnRequest` insert, so both commit atomically.
   A new `OutboxPublisherBackgroundService` polls unprocessed rows every second and does the actual publish, retrying indefinitely until it succeeds — the event's fate is durable in Postgres the moment the HTTP request returns.
   See `decisions.md`.

3. **A malformed message payload could wedge the entire queue.**
   `JsonSerializer.Deserialize` in `ReturnRequestConsumer` wasn't inside the try/catch; with `prefetchCount: 1`, an unhandled deserialize failure would leave the message unacked and stall every message behind it.
   Fixed by moving the deserialize into a try/catch and routing a null/malformed payload straight to the DLQ (no retry — a bad payload will never fix itself).

4. **No input validation on create.** Added `[Required]`/`[MaxLength]`/`[EmailAddress]` to `CreateReturnRequestRequest`, matching the DB's actual column limits, so an over-length field is a clean `400` instead of an unhandled `500` from Postgres.

5. **Unbounded pagination.** Added `[Range(1, int.MaxValue)]` on `page` and `[Range(1, 100)]` on `pageSize` in `ReturnRequestsController.List` — previously `page=0` threw a negative-`OFFSET` exception and `pageSize` had no upper bound at all.

6. **Redis had no startup resilience, unlike RabbitMQ and Postgres.** `be`'s `ConnectionMultiplexer.Connect` was a single blocking call with no retry.
   Fixed in both `be` and (newly, for fix 1) `worker` using `ConfigurationOptions.AbortOnConnectFail = false` — the idiomatic StackExchange.Redis fix, which keeps retrying in the background instead of throwing at startup.

7. **Idempotency keys could get stuck `IN_PROGRESS` for 24h on a crash.**
   Mostly resolved as a side effect of fix 2: the window between the DB commit and `StoreResultAsync` no longer includes a network call to an external broker, just two local calls, so the crash window is much smaller.
   Residual risk accepted rather than engineered further — not worth a bigger fix for a learning project.

**Also added:** structured logging in `ReturnRequestConsumer` — a nack-to-retry now logs a `warn` with the exception and return-request id, exhausting retries to the DLQ logs an `error`, and a malformed payload logs a `warn`. Previously all three were silent.

**Verified live:** created several return requests against the rebuilt containerized stack; confirmed cache invalidation via `redis-cli monitor`, confirmed the outbox relay publishing via `be` logs, and confirmed the new consumer logging fires correctly on the simulated API's real ~30% failure rate (nack → retry → self-heal, no DLQ involvement).

## Phase 6 — Azure deployment — not started

- Switched from AWS EC2 + ALB to Azure on 2026-10-14, to match where the WCP portal plans to host.
- Postgres moves from a self-hosted container to Azure Database for PostgreSQL Flexible Server for this phase; Redis, RabbitMQ, and the app containers stay self-hosted on VMs.

## Phase 7 — Load testing (k6/Locust) — not started

## Other repos

- `distributed_crm_fe` — default Vite scaffold only, no app code.

## Repo split: `distributed_crm_infra`

- `docker-compose.yml` and `docs/` used to live loose in the `distributed_crm/` section folder, which was never itself a git repo — meaning neither was version-controlled anywhere.
- Both moved into a new, dedicated repo, `distributed_crm_infra`, sibling to `be`/`worker`/`fe`. It holds no application code — just local-dev orchestration and the cross-repo docs that don't belong to any single service.
- `docker-compose.yml`'s `build:` paths updated to `../distributed_crm_be` / `../distributed_crm_worker`; the Postgres volume got an explicit `name: distributed_crm_distributed-crm-pgdata` pin so moving folders didn't silently orphan the existing data volume (verified: test data survived the move).
- `CLAUDE.md` deliberately stayed at the `distributed_crm/` section root rather than moving into `distributed_crm_infra` — it's discovered by Claude Code walking up from whatever repo you're working in, and moving it into a sibling repo would likely break that.

## Git state

- `distributed_crm_be`: first commit made 2026-09-20 (`9a4d86c`), covers everything through Phase 4's producer side. Pushed to GitHub.
- `distributed_crm_worker`: first commit made 2026-10-13 (`d12e17e`), covers the full consumer side of Phase 4. Pushed to GitHub.
- `distributed_crm_fe`: never committed. Deliberately left as-is — no app code yet.
- `distributed_crm_infra`: first commit made 2026-10-14, holds `docker-compose.yml` and `docs/`. Pushed to GitHub, public, under `jamesphm04`.
