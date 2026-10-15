# Progress

Phase numbers match the ordered learning goals in `CLAUDE.md`. Last updated 2026-10-15.

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

Phases 6–15 were re-planned on 2026-10-14 so this project touches every component the WCP portal will use — see "Rehearse every WCP component" in `decisions.md`, and the roadmap in `CLAUDE.md` for what each phase covers.

## Phase 6 — Thin Google sign-in — done, verified end-to-end

- Google Cloud OAuth 2.0 client (type "Web application") created, with the OAuth Playground as its only redirect URI for now.
  Phase 11 reuses the same client and adds the Static Web Apps origin.
  The Cloud project's consent screen is Internal to the `wholesalecarparts.com.au` Workspace, so only that org's accounts can sign in.
- `distributed_crm_be` validates Google ID tokens with `AddJwtBearer`: `Authority = https://accounts.google.com` (discovery document + JWKS, refreshed automatically on key rotation), both Google issuer spellings, the client ID as the only valid audience, default expiry check.
- `AllowedEmailRequirement` + `AllowedEmailHandler` (all in `Api/Authentication/`): the token's `email` must have `email_verified: true` and be on `GoogleAuth:AllowedEmails`, case-insensitive. A denial logs a `warn` with the reason.
- One policy (authenticated + allowlisted) is both the **default** policy (what `[Authorize]` means) and the **fallback** policy (what an unannotated endpoint gets). `[Authorize]` is on `ReturnRequestsController`; the dev-only OpenAPI document is `AllowAnonymous()`.
- `GoogleAuthOptions` is bound with `ValidateDataAnnotations().ValidateOnStart()`, so a missing client ID or empty allowlist crashes the app at boot.
- Real values stay out of git (both repos are public): `dotnet user-secrets` for `dotnet run`, a gitignored `.env` in `distributed_crm_infra` for Compose (`.env.example` committed). Compose uses `${VAR:?message}`, so a missing value stops `docker compose up` immediately.
- Domain, Application, Infrastructure and `worker` are untouched — token validation is an HTTP-pipeline concern.

**Verified live** against the containerized stack:
- No token → `401`, `WWW-Authenticate: Bearer`.
- Garbage token → `401`, `WWW-Authenticate: Bearer error="invalid_token"`.
- Real Google ID token from the OAuth Playground → `200` with the list.
- Create with the token → `201` `Pending` → worker → `Approved` about 1.2s later, so the outbox → RabbitMQ → worker path is unaffected.

**Not verified live** (James chose to skip; understood conceptually): a tampered token (signature mismatch → `401`), a valid token whose email isn't allowlisted (→ `403`, the deny branch of `AllowedEmailHandler`), and an expired token (→ `401`, after `exp` + the 5-minute default clock skew).

**Log noise fixed along the way**, in both `be` and `worker`:
- `Microsoft.EntityFrameworkCore.Database.Command` raised to `Warning` — the outbox poller was logging one SQL statement per second. Verified: 0 `Executed DbCommand` lines after rebuild.
- `Gss Encryption Mode=Disable` added to every Postgres connection string — Npgsql was trying GSS/Kerberos encryption on first connect and printing `Cannot load library libgssapi_krb5.so.2` from the slim runtime image. Verified: 0 occurrences after rebuild in `be`; `worker` hadn't connected to Postgres again yet at the time of checking (same Npgsql version and keyword as `be`).
- The DataProtection "keys not persisted / no XML encryptor" warnings are left as-is on purpose — see `decisions.md`.

**Old dev data, not a bug:** seven rows stuck at `Pending`/`Processing` (ORD-2000 ×2, ORD-3000, ORD-9000, ORD-1001, ORD-FAIL-001, ORD-DOCKER-001) all predate the transactional outbox and have no `outbox_messages` row. `ORD-FAIL-001` is the deliberate Phase 4 DLQ test.

## Phase 7 — Azure Service Bus replaces RabbitMQ — done, verified end-to-end

- **Emulator in Compose:** `servicebus` (`mcr.microsoft.com/azure-messaging/servicebus-emulator:2.0.1`) plus its private storage `servicebus-sql` (`azure-sql-edge:1.0.7` — pinned because `2.0.0` is x86-only, `1.0.7` runs natively on Apple Silicon). Queue `return-requests` defined in `servicebus/Config.json`. RabbitMQ removed from Compose.
- **`be`:** `ServiceBusReturnRequestQueue` replaces `RabbitMqReturnRequestQueue` behind the unchanged `IReturnRequestQueue` port; deterministic `MessageId` for duplicate detection. Application and Domain untouched.
- **`worker`:** `ReturnRequestConsumer` rewritten on `ServiceBusProcessor`: scheduled-copy retries (30s, 3 retries), explicit dead-letter (`MaxRetriesExceeded`, `MalformedPayload`), `MaxDeliveryCount` as the crash net. `ProcessReturnRequestHandler` untouched.
- Both apps: `ServiceBusClient` via `AddAzureClients`; the hand-rolled RabbitMQ startup retry loops are deleted; `RabbitMQ.Client` removed; `Azure.*` logs at `Warning`.
- Package alignment: `be` Infrastructure's `Microsoft.Extensions.Hosting.Abstractions` 10.0.0 → 10.0.12 and `worker`'s `Microsoft.Extensions.Hosting` 10.0.5 → 10.0.12 (the Service Bus SDK's `Azure.Core` needs ≥ 10.0.10; NuGet treated the downgrade as an error).

**Verified live** against the containerized stack (requests created as `return_requests` + `outbox_messages` rows in one transaction — exactly what the API's create does — so the outbox relay, Service Bus and worker run for real; queues inspected with a throwaway SDK peek script):
- Happy path: `Pending` → `Approved` in ~1.6s.
- Failure path (`FailureRate=1.0`): attempts at +0s, +31s, +62s, +93s, then dead-lettered with `MaxRetriesExceeded` and the error text; the row correctly stayed `Processing`. Retry copies carried `retry-count` 1–3 and `MessageId` `…:retry-N`.
- Malformed payloads (`not json` and `{}`) dead-lettered immediately as `MalformedPayload`.
- Duplicate detection: two sends with the same `MessageId` (worker stopped) → one message in the queue.
- Broker outage: emulator stopped, request created → stayed `Pending`, outbox row unrelayed; emulator restarted → `Approved` ~30s later.
- Startup ordering: worker started before the emulator was ready, logged `Connection refused`, attached its receiver on its own.

**Not verified live:** `MaxDeliveryCount` dead-lettering after repeated worker crashes mid-message (needs killing the worker inside a ~1.5s window five times).
Also checked: a worker started with `dotnet run` (Development config) attached its receiver through `localhost:5672`.

**Bugs found along the way:**
- `Config.json` typos (`DeadLetteringOnMessageExpire`, `RequiresDupplicateDetection`, `RequireDetectionHistoryTimeWindow`) — caught on review and checked against the emulator's published schema before first boot.
- Emulator rejects a duplicate-detection window over 5 minutes and refuses to start (`Expected time to be less than or equal to 5m`).
- Phase 4's consumer treated `{}` as a valid message for `Guid.Empty` and acked it away as "not found"; the new consumer dead-letters it.

## Phase 8 — Deploy readiness + OpenTelemetry — done, verified end-to-end

James wrote Steps 1–6 and 9a–9c step by step, each reviewed and then verified by him against the Compose stack.
At his request the agent built Steps 7–8, 9d, 10 and 11, verified them, and showed him the result.

**Built (`be`, `worker` + `infra`):**
- **Step 1–3, health endpoints on `be`:** `/health/live` runs no checks; `/health/ready` checks Postgres (`AddDbContextCheck`), Redis (`RedisHealthCheck`, a ping through the app's multiplexer) and Service Bus (`ServiceBusQueueHealthCheck`, a peek through the app's client, registered as a singleton so it holds one receiver link). Both are `AllowAnonymous`; every check is capped at 5 seconds.
- **Step 4, forwarded headers:** `UseHttpsRedirection` removed; `UseForwardedHeaders` (`X-Forwarded-For` + `X-Forwarded-Proto`, any proxy trusted, `ForwardLimit` 1) is the first middleware.
- **Step 5, migrations as an idempotent SQL script:** `dotnet-tools.json` pins `dotnet-ef` 10.0.12. The `be` Dockerfile gained a `migrations-script` stage (`dotnet ef migrations script --idempotent`) and a `migrate` stage (`postgres:17` + the script, `psql -v ON_ERROR_STOP=1`). Compose runs `migrate` as a one-shot job; `be` and `worker` wait for `service_completed_successfully`.
- **Step 6, container hygiene:** `.dockerignore` in both repos (`bin/`, `obj/`, `.git/`, IDE folders, `.DS_Store`, `.env`); the build context dropped from ~50 MB to ~324 KB. Both runtime stages run as the image's non-root `app` user (`USER $APP_UID`). The worker Dockerfile's `FromAsCasing` warning and BOM are fixed. Compose pins `name: distributed_crm`, which ended the volume's project-label warning; images are now `distributed_crm-*`.
- **Step 7, env-only config, failing fast:** both apps read their three connection strings through `GetRequiredConnectionString` before building the host, so a missing one stops startup with the variable's name. `be` gained `DistributedCrmDbContextFactory` (design-time), so the EF tools no longer run `Program.cs` and no longer depend on `appsettings.Development.json`.
- **Step 8, worker health:** the worker moved to the Web SDK and `WebApplication`, and exposes the same `/health/live` and `/health/ready` (Postgres, Redis, Service Bus) on port 8080, published on `127.0.0.1:5216`. It has no other HTTP surface.
- **tini as PID 1:** both runtime images install `tini` and start with `ENTRYPOINT ["tini", "--", "dotnet", …]` (see Bugs found).
- **Step 9, OpenTelemetry in `be`:** `Telemetry/TelemetryExtensions.AddTelemetry()` exports traces, metrics and logs over OTLP with `UseOtlpExporter()`.
  Traces come from ASP.NET Core, HttpClient, Npgsql, StackExchange.Redis and the Service Bus SDK (`Azure.Experimental.EnableActivitySource` switch + `AddSource("Azure.Messaging.ServiceBus.*")`).
  Metrics come from ASP.NET Core, HttpClient, the runtime and Npgsql; logs go through `WithLogging`, so each record carries its trace ID.
  `service.name` is set in code (`distributed-crm-be`); the endpoint comes from `OTEL_EXPORTER_OTLP_ENDPOINT`; `Telemetry:ConsoleExporter=true` adds a console exporter.
  Noise filters: no traces for `/health/*`; Npgsql traces commands and batches only when `Activity.Current` is set; physical connection opens are not traced.
- **Aspire dashboard in Compose:** `mcr.microsoft.com/dotnet/aspire-dashboard:13.6.1`, UI on `127.0.0.1:18888`, OTLP gRPC on `127.0.0.1:4317` (so `dotnet run` needs no config), anonymous access because it is bound to localhost.
  The apps don't `depends_on` it: telemetry must never decide whether an app starts.
- **Step 10, OpenTelemetry in `worker`:** the same extension (`distributed-crm-worker`, no HttpClient instrumentation), its own `InfrastructureTelemetry` `ActivitySource`, a hand-written `approval-api RequestDecision` client span (error status and exception event on failure, `approval.decision` tag), and failed attempts marked as errors on the processor's span with a `messaging.attempt` tag.
  The worker keeps tracing physical connection opens, because nothing in it runs SQL outside a message's span.
- **Step 11, one trace from the API to the worker:** `outbox_messages.trace_parent` (nullable `varchar(55)`, migration `AddOutboxTraceParent`) stores `Activity.Current.Id` when the row is written.
  The relay parses it with `ActivityContext.TryParse` and wraps each row's send and `UPDATE` in an `outbox relay ReturnRequestCreated` span with that parent; Service Bus then carries the trace to the worker in `Diagnostic-Id`.
  Rows without a value start a new trace, as before.

**Verified live:**
- `/health/live` and `/health/ready` → `200 Healthy`; `/api/return-requests` without a token still `401`.
- Redis stopped → `/health/live` `200` in ~1 ms, `/health/ready` `503` in ~5.7 s (Redis's own 5 s command timeout), log line `Health check redis with status Unhealthy` with the exception; Redis started → `200` again without restarting the API.
- `Location` on create is `http://…` for a direct request and `https://…` with `X-Forwarded-Proto: https`.
- `migrate` exits `0` on every `docker compose up` and is a no-op against the existing database. Against a fresh empty database it created all three tables and recorded both migrations; a second run changed nothing.
- `docker compose down` then `up` under the new project name: the volume warning is gone and the existing 30 rows survived.
- `localhost:5214/health/*` and `localhost:5216/health/*` all `200 Healthy`; `id` in both containers is `uid=1654(app)`.
- An empty `ConnectionStrings__Redis` makes either app exit `134` within seconds, logging `Connection string 'Redis' is not configured. Set the ConnectionStrings__Redis environment variable.`
- EF tools report `Using DbContext factory`; the generated idempotent script is byte-identical to the one before, and `has-pending-model-changes` reports none.
- The worker still processes messages after the switch to a web host: an outbox-inserted request went through two simulated failures and scheduled retries to `Rejected`.
- `docker compose stop worker` logs `Application is shutting down...` and exits `0`; `tini` is PID 1 with `dotnet` as its child.
- `dotnet run` of the worker listens on `http://localhost:5216` in `Development`, `/health/ready` `200`.
- Telemetry in the Aspire dashboard: logs linked to their traces; a cache miss shows Redis `GET` → `SELECT` → Redis `SETEX` and a cache hit shows only Redis `GET`, which confirmed the Redis beta instrumentation works on SE.Redis 3.3.
- Idle for 5½ minutes (one full connection-pool prune cycle) plus repeated `/health/ready` calls on both apps → 0 traces.
- A real `POST /api/return-requests` (James, trace `65f7ae2…`) is one trace across both services: the POST's SQL and Redis spans, the relay span about 1 s later, then the worker's attempts.
  It hit the simulated failure twice, so two red attempts 30 s apart (each with a red approval-api span and a scheduled retry) and a successful third attempt all sit under the same POST.
  The row's `trace_parent` starts with that trace ID.
- An outbox row with a hand-written `trace_parent` continued that exact trace ID; a row without one started a new trace with the relay span as its root.
- A retried message (two failures, then `Approved`) shows all three attempts in one trace; the retry inherits the trace because the scheduled copy keeps the original's application properties.
- Final check after a full `docker compose up -d --build`: `migrate` `Exited (0)`, both apps' `/health/live` and `/health/ready` `200`, the API without a token `401`, EF reports no pending model changes, both builds 0 warnings.

**Bugs found:**
- **A crashing .NET app hung as PID 1 instead of exiting.** With the fail-fast check throwing, the container stayed `Up` with `dotnet` at ~100% CPU for over a minute. .NET ends a crash with `abort()`, which raises `SIGABRT` on itself, and the kernel drops signals with a default action for PID 1 of a PID namespace. The same image under `docker run --init` exited `134` at once. Fixed with `tini` as PID 1 in both images; in Container Apps the hang would have looked like a stuck replica instead of a crash-and-restart.
- **The EF tools only worked because of `appsettings.Development.json`.** Without a design-time factory they built the app's host to get the `DbContext`, so they needed real connection strings at design time. Found when fail-fast config made them throw.
- **`.dockerignore` had `**/.DS_store`.** Docker matches patterns case-sensitively, so it matched nothing; macOS's case-insensitive file system hid the typo.
- **`AllowedEmailHandler` logged "Denied: token has no verified email" for expired or missing tokens.** ASP.NET Core runs every handler in a policy even after `RequireAuthenticatedUser()` fails, so the handler saw an anonymous user. Found through the dashboard's log-to-trace link; the handler now ignores unauthenticated users.
- **The outbox poll made a one-span trace every second** (187 of ~200 traces in the dashboard), and the pool reopening its idle connection made a lone `CONNECT` trace every 300 s. Fixed by the Npgsql command, batch and physical-open settings above.

**Gotchas found:**
- `psql` prints only `DO` for each guarded block of the idempotent script, whether it applied a migration or skipped it — check `__EFMigrationsHistory`, not the log.
- The `UseHttpsRedirection` warning `Failed to determine the https port for redirect` was logged on every request in the container; gone with Step 4.
- The Compose project had to be brought `down` *before* setting `name:`. Compose owns containers by the `com.docker.compose.project` label, so after a rename it no longer sees the old ones; with fixed `container_name`s, the next `up` would fail on a name conflict.
- The rename left the old images (`distributed_crm_infra-be`, `-worker`, `-migrate`, and `distributed-crm-migrate`) behind; they are unused and can be removed with `docker image rm`.
- `AddService(...)` in code overrides `OTEL_SERVICE_NAME`, so the variable was removed from Compose rather than left looking meaningful.
- Redis spans reach the dashboard about 10 s after the rest of a trace, because the instrumentation drains its profiling sessions in batches.
- The Service Bus SDK's `ServiceBusReceiver.Receive` span is a root span, one per received message (not per poll). It is kept as the standard view of receive latency.
- Pasting YAML into nvim with auto-indent turned `environment:` into a list item under `ports:` (`ports.[2] is missing a target port`); use `:set paste` or `"+p`.

**Not verified here:** export to Application Insights (Phase 9 changes only the OTLP endpoint and its auth).

**Phase demos and quiz (2026-10-16):** James ran all three demos: worker exits `134` on a blank `ConnectionStrings__Redis`; with Redis stopped, `/health/live` stays `200` while `/health/ready` returns `503`; with `FailureRate=1.0`, a POST became one trace with four failed attempts and a dead-letter.
Quiz gaps logged in `learning-gaps.md`.

**Known gap, not on the roadmap yet:** a dead-lettered request stays `Processing` forever, and nothing tells anyone.
Staying `Processing` is deliberate (the worker never got a decision, so `Approved`/`Rejected` would be false), but from outside "slow" and "given up" look the same; only the dead-letter queue and the worker's error log know.
A real fix has three parts: a terminal status such as `NeedsAttention` set when the worker dead-letters (a Domain status-machine change, to be discussed first), an alert on dead-letter count or on time spent in `Processing` (fits Phase 10 or 15 once App Insights exists), and a redrive path for a human.
WCP's Pinnacle credit write-back will need the same.

## Phase 9 — Bicep infrastructure — not started

## Phase 10 — GitHub Actions pipeline + first live deploy — not started

## Phase 11 — React + Ant Design frontend on Static Web Apps — not started

## Phase 12 — Blob Storage attachment — not started

## Phase 13 — Python ingestion job — not started

## Phase 14 — Paste-a-phone-number search — not started

## Phase 15 — Load testing with k6 — not started

## Other repos

- `distributed_crm_fe` — default Vite scaffold only, no app code until Phase 11.

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
- Phase 6 changes `be`, `worker` (log level + connection string only) and `infra`.
- Phase 7 changes `be`, `worker` and `infra`.
- Phase 8 checkpoint (Steps 1–5) committed in `be` and `infra` on 2026-10-15; the phase isn't done yet.
- Phase 8 Steps 6–8 committed in `be`, `worker` and `infra` on 2026-10-15.
- Phase 8 Steps 9–11 (OpenTelemetry) committed in `be`, `worker` and `infra` on 2026-10-15, completing the phase.
