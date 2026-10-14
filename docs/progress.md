# Progress

Phase numbers match the ordered learning goals in `CLAUDE.md`. Last updated 2026-10-13.

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

## Phase 5 — Docker + docker-compose for local dev — partially done

- Backing services (Postgres, Redis, RabbitMQ) run via `docker-compose.yml` at the section root.
- The app containers themselves (`distributed_crm_be`, `distributed_crm_worker`, `distributed_crm_fe`) are not yet containerized — currently run via `dotnet run` / local dev servers only.

## Phase 6 — AWS EC2 deployment — not started

## Phase 7 — Load testing (k6/Locust) — not started

## Other repos

- `distributed_crm_fe` — default Vite scaffold only, no app code.

## Git state

- `distributed_crm_be`: first commit made 2026-09-20 (`9a4d86c`), covers everything through Phase 4's producer side. Pushed to GitHub.
- `distributed_crm_worker`: first commit made 2026-10-13 (`d12e17e`), covers the full consumer side of Phase 4. Pushed to GitHub.
- `distributed_crm_fe`: never committed. Deliberately left as-is — no app code yet.
