# Architecture

Snapshot of how the system is actually built today.
For *why* the non-obvious choices were made, see [`decisions.md`](decisions.md).

## Repos and backing services

```
distributed_crm_be       ASP.NET Core API — Clean Architecture (Domain/Application/Infrastructure/Api), MVC controllers
distributed_crm_worker   .NET background worker on an ASP.NET Core host (health endpoints only) — consumes the queue, calls a simulated flaky third-party API
distributed_crm_fe       React + TypeScript (Vite), linted with Oxlint

Postgres   — system of record: `return_requests`, plus `outbox_messages`
Redis      — idempotency store + read-through cache
Service Bus — async handoff from API to worker (Azure Service Bus; the official emulator locally), with scheduled retries and a dead-letter queue
```

All three backing services (plus the emulator's private SQL Edge container), `be`, `worker` and the Aspire dashboard run via `docker-compose.yml` in this repo. Port mappings are in `setup.md`.

## Domain

Single entity: `ReturnRequest`.

```
Pending ──MarkProcessing()──▶ Processing ──MarkApproved()──▶ Approved
   │                              │
   └──────────Cancel()────────────┴──MarkRejected()──▶ Rejected
                                   │
                                   ▼
                              Cancelled
```

`Cancel()` is only valid from `Pending` or `Processing`. Every transition is guarded in the entity itself (`DistributedCrm.Domain/Entities/ReturnRequest.cs`) — invalid transitions throw `InvalidStatusTransitionException`, which the API maps to `409 Conflict`.

Fields: `Id` (GUID v7), `OrderReference`, `CustomerEmail`, `Item`, `Reason`, `Status`, `CreatedAt`, `UpdatedAt`.

## API surface (`distributed_crm_be`)

Every endpoint except `/health/*` requires `Authorization: Bearer <Google ID token>` from an allowlisted email — see "Authentication" below.

| Endpoint | Notes |
|---|---|
| `POST /api/return-requests` | Requires `Idempotency-Key` header. Creates the record and an `outbox_messages` row in one transaction; the outbox relay publishes the `created` event to Service Bus. |
| `GET /api/return-requests/{id}` | Cache-aside read through Redis. |
| `GET /api/return-requests?page=&pageSize=` | Paginated list, no caching. |
| `POST /api/return-requests/{id}/cancel` | Optimistic concurrency (`xmin` token) + state-machine guard, both map to `409`. |
| `GET /health/live` | Anonymous. No checks: `200 Healthy` while the process can serve HTTP. |
| `GET /health/ready` | Anonymous. Postgres, Redis and Service Bus: `200 Healthy` or `503 Unhealthy`. |

Clean Architecture layering: `Domain` has zero external dependencies; `Application` defines the ports (`IReturnRequestRepository`, `IUnitOfWork`, `IIdempotencyStore`, `IReturnRequestCache`, `IReturnRequestQueue`) and the use-case handlers; `Infrastructure` implements those ports against Postgres/Redis/Service Bus; `Api` wires DI, handles authentication/authorization, and exposes controllers.

## Authentication (Google ID tokens)

The API is a JWT bearer resource server; Google is the identity provider. There's no login endpoint and no `users` table.

```
client ──(Sign in with Google / OAuth Playground)──▶ Google ──▶ ID token (JWT, ~1h)
client ──Authorization: Bearer <ID token>──▶ be
   UseAuthentication   JwtBearer: signature (Google JWKS), iss, aud = client ID, exp   ── fail ─▶ 401
   UseAuthorization    policy: authenticated + AllowedEmailRequirement               ── fail ─▶ 403
                         AllowedEmailHandler: email_verified && email ∈ GoogleAuth:AllowedEmails
   controller
```

- Code lives in `DistributedCrm.Api/Authentication/` (`GoogleAuthOptions`, `AllowedEmailRequirement`, `AllowedEmailHandler`) and is wired in `Program.cs`. Domain, Application and Infrastructure have no auth code.
- The allowlist policy is both the default and the fallback authorization policy, so any endpoint without `[AllowAnonymous]` is protected. Only the health endpoints and the dev OpenAPI document are anonymous.
- Config: `GoogleAuth:ClientId` and `GoogleAuth:AllowedEmails` (validated at startup). Values come from user secrets or `distributed_crm_infra/.env`, never from git.
- `worker` has no auth — its only HTTP endpoints are the anonymous health probes.

## Health, proxies and migrations

```
Container Apps ingress ──HTTPS terminated, X-Forwarded-For/-Proto added──▶ be :8080
   UseForwardedHeaders   restores the client's scheme + IP (any proxy trusted, ForwardLimit 1)
   UseAuthentication / UseAuthorization
   controllers           /api/return-requests…
   health checks         /health/live  → no checks
                         /health/ready → postgres (AddDbContextCheck), redis (ping), servicebus (peek)   5 s cap each
```

- Health-check classes live in `DistributedCrm.Infrastructure/HealthChecks/`; registration and endpoint mapping are in `Program.cs`. The responses carry only `Healthy`/`Unhealthy`; failures are logged with the exception.
- There is no `UseHttpsRedirection`: HTTPS is enforced at the ingress.
- `worker` exposes the same `/health/live` and `/health/ready` (same three checks, its own copies of the check classes) on port 8080, and nothing else. It has no auth and no forwarded headers; Container Apps will reach it only from its own probes.
- **Migrations** never run inside the app. The `be` Dockerfile's `migrations-script` stage generates `dotnet ef migrations script --idempotent`; its `migrate` stage is `postgres:17` + that script, run with `psql -v ON_ERROR_STOP=1` and configured by `PG*` environment variables. In Compose it is a one-shot job that `be` and `worker` wait for (`service_completed_successfully`).

## Configuration and containers

- **Config is environment variables only.** Connection strings come from `ConnectionStrings__DistributedCrm`, `ConnectionStrings__Redis` and `ConnectionStrings__ServiceBus`; `be` also needs `GoogleAuth__ClientId` and `GoogleAuth__AllowedEmails__0`. Each app reads them through `GetRequiredConnectionString` (`Configuration/ConfigurationExtensions.cs`) or validated options before the host is built, so a missing value stops startup with its name.
- **EF tools** use `DistributedCrmDbContextFactory` (`IDesignTimeDbContextFactory` in `be` Infrastructure), so `dotnet ef` needs no connection string and never runs `Program.cs`.
- **Images.** Both are multi-stage: `sdk:10.0` builds, `aspnet:10.0` runs. The runtime stage runs as the non-root `app` user (UID 1654), listens on 8080, and starts as `tini -- dotnet <app>.dll`, so `tini` is PID 1 and the app is its child. `.dockerignore` keeps `bin/`, `obj/`, `.git/` and `.env` out of the build context. `be`'s Dockerfile has two more stages, `migrations-script` and `migrate`.
- **Compose project** is pinned as `distributed_crm`, so images are `distributed_crm-be`, `distributed_crm-worker` and `distributed_crm-migrate`, and the network is `distributed_crm_default`.

## Telemetry (OpenTelemetry)

```
be, worker ──OTLP gRPC (OTEL_EXPORTER_OTLP_ENDPOINT)──▶ Aspire dashboard (local, in memory)  /  Application Insights (Phase 9+)
             traces + metrics + logs, service.name = distributed-crm-be | distributed-crm-worker
```

- Each app wires OpenTelemetry in one place, `Telemetry/TelemetryExtensions.AddTelemetry()` in its host project; the two copies differ only in service name and instrumentation list.
- **Traces** come from library instrumentation (ASP.NET Core, HttpClient in `be`, Npgsql, StackExchange.Redis, the Service Bus SDK) plus the `DistributedCrm.Infrastructure` `ActivitySource` in each repo's Infrastructure (`Telemetry/InfrastructureTelemetry.cs`), which is plain `System.Diagnostics` so Infrastructure has no OpenTelemetry dependency.
- **Metrics:** ASP.NET Core, HttpClient (`be`), runtime and Npgsql. **Logs:** every `ILogger` record, carrying the current trace ID.
- **Not traced:** `/health/*` requests (and so their checks' child spans), SQL commands and batches with no current span (the outbox poll), and `be`'s physical connection opens.

**One trace from the API to the worker:**

```
POST /api/return-requests (be)
  INSERT return_requests + outbox_messages (trace_parent = Activity.Current.Id)
  ┊ ~1 s, background loop
  outbox relay ReturnRequestCreated (be; parent restored from trace_parent with ActivityContext.TryParse)
    Message (Service Bus producer span; its ID travels in Diagnostic-Id)
      ServiceBusProcessor.ProcessMessage (worker, one per attempt; failed attempts marked as errors)
        SQL, Redis UNLINK, approval-api RequestDecision (hand-written client span), Schedule/Complete/DeadLetter
    ServiceBusSender.Send
    UPDATE outbox_messages
```

HTTP and Service Bus propagate trace context by themselves; the outbox table needs its `trace_parent` column, or the relay would start a new trace.
Scheduled retries copy the original message's properties, so every attempt and the final dead-letter stay in the same trace.

## Statelessness

The API tier holds no in-process state that matters across requests — every instance reads/writes the same Postgres and Redis. Verified live by running two instances on different ports (`5214`/`5215`) against one shared stack and confirming identical responses and shared idempotency/cache behavior from both. See `decisions.md` for what this specifically ruled out.

## Idempotency (Redis)

`RedisIdempotencyStore` implements `IIdempotencyStore` using a claim-then-finalize flow:

1. `TryClaimAsync` atomically claims the `Idempotency-Key` with `SET NX` and an `"IN_PROGRESS"` marker (24h TTL).
2. If the claim succeeds, the caller does the real work (create the `ReturnRequest` row), then calls `StoreResultAsync` to overwrite the marker with the full serialized response.
3. If the key is already `"IN_PROGRESS"`, the caller gets `IdempotencyClaimStatus.InProgress` → API returns `409`.
4. If the key already holds a finished response, the caller gets it back directly (`IdempotencyClaimStatus.Completed`) — the create is never re-run.

Key format: `idempotency:{key}`.

## Read cache (Redis)

`RedisReturnRequestCache` implements `IReturnRequestCache`, used only by `GetReturnRequestByIdHandler`:

- **Cache-aside**: check cache → miss falls through to Postgres → populate cache.
- **TTL**: 5 minutes, as a safety net.
- **Explicit invalidation**: `CancelReturnRequestHandler` calls `InvalidateAsync` right after `SaveChangesAsync` — so a cancel is immediately visible to every instance, not just after the TTL expires.

Key format: `returnrequest:{id}`.

## Queue + retry design (Azure Service Bus)

One queue, `return-requests`, in namespace `sbemulatorns` locally.
It is defined **outside** the apps — `servicebus/Config.json` in this repo for the emulator, Bicep in Azure (Phase 9) — and neither app declares topology.
The queue name is the one coupling point between `be` and `worker`.

Queue settings (emulator values; Azure differs where the emulator caps them):

| Setting | Value | Why |
|---|---|---|
| `LockDuration` | 1 min | A received message is hidden from other consumers until completed or the lock expires; the SDK renews it while processing. |
| `MaxDeliveryCount` | 5 | Crash safety net: a message whose lock keeps getting lost (worker crash) is dead-lettered automatically. |
| `DefaultMessageTimeToLive` | 1 h (emulator max; 14 d in Azure) | How long a message may wait. |
| `DeadLetteringOnMessageExpiration` | true | An expired message goes to the DLQ instead of vanishing. |
| `RequiresDuplicateDetection` | true, 5 min window (emulator max; 10 min in Azure) | Repeated `MessageId`s are dropped. |

**Producer (`be`):** `ServiceBusReturnRequestQueue` implements `IReturnRequestQueue`, called by the outbox relay (`OutboxPublisherBackgroundService`).
Each message is `{"returnRequestId": "..."}` with `MessageId = return-request-created:{id}`, `Subject = ReturnRequestCreated`, `ContentType = application/json`.
The deterministic `MessageId` means an outbox re-send after a crash is dropped by duplicate detection.

**Consumer (`worker`):** `ReturnRequestConsumer` runs a `ServiceBusProcessor` (`MaxConcurrentCalls = 1`, `AutoCompleteMessages = false`):

```
receive (locked)
  ├─ malformed body / empty id ──────────────────────▶ DeadLetter("MalformedPayload")
  ├─ handler succeeds / concurrency conflict ────────▶ Complete (after the Postgres commit)
  └─ handler throws
       ├─ retry-count < 3 ─▶ Schedule copy at now+30s (retry-count+1, MessageId …:retry-N), then Complete original
       └─ retry-count = 3 ─▶ DeadLetter("MaxRetriesExceeded", error message)

worker crashes / lock lost ─▶ Service Bus redelivers; after MaxDeliveryCount (5) it dead-letters on its own
```

The dead-letter queue is the queue's built-in `$DeadLetterQueue` subqueue — terminal, nothing consumes it, a human inspects it.
Scheduling happens before completing, so a crash in between causes one extra attempt (tolerated by the handler's status guards and `xmin`), never a lost message.

**Connections:** both apps register `ServiceBusClient` via `AddAzureClients(...AddServiceBusClient(connectionString))`.
The client connects lazily and retries on its own, so there is no startup retry loop; Phase 10 switches to `AddServiceBusClientWithNamespace` + managed identity.

Phase 4's RabbitMQ three-exchange retry/DLX topology is gone from the code; see `decisions.md` and `progress.md` for how it worked and how it maps onto this design.

## Azure environment (Bicep, `infra/`)

Written in Phase 9 and checked with build, validate and what-if; first real deploy is the Phase 9 rehearsal.
`infra/main.bicep` runs at subscription scope, creates `rg-dcrm-dev`, and calls one module per area with `scope: rg`.
`infra/main.bicepparam` holds the values (region `australiaeast`, workload `dcrm`, environment `dev`, tags); no secret values live in either file.
`infra/deploy.sh plan|up|down` wraps it: `plan` is a what-if, `up` creates or updates a deployment stack (`dcrm-dev`, `--action-on-unmanage deleteAll`), `down` deletes everything the stack owns and purges the soft-deleted Key Vault.

| Module | Resources | Access |
|---|---|---|
| `monitoring` | Log Analytics workspace (`PerGB2018`, 30 days, 0.5 GB/day cap) and workspace-based Application Insights | — |
| `identities` | user-assigned managed identities `id-dcrm-be-dev`, `id-dcrm-worker-dev` | — |
| `registry` | Container Registry Basic, admin user off | AcrPull for both apps |
| `keyvault` | Key Vault Standard, RBAC mode, 7-day soft delete, no purge protection | Secrets User for both apps; Secrets Officer for the deployer |
| `servicebus` | Standard namespace (local auth off) and the `return-requests` queue, settings identical to `servicebus/Config.json` | Data Sender for both apps, Data Receiver for the worker, scoped to the queue |
| `postgres` | Flexible Server B1ms, Postgres 17, 32 GB, Entra-only auth, `distributed_crm` database, "Azure services" firewall rule | the deployer is the Entra admin; app roles are created by the migrate step |
| `redis` | Managed Redis Balanced B0, no HA, TLS on 10000, access keys off, `NoEviction` | Entra access policy assignments for both apps |
| `containerapps-env` | Container Apps environment (Consumption profile only), logs to the workspace through a diagnostic setting | — |

Globally unique names (registry, vault, Service Bus, Postgres, Redis) end in `uniqueString(resourceGroup().id)`, so they are the same on every rebuild of the same resource group.
Every permission is granted to a principal ID (a GUID), never a name; role assignment names come from `guid(scope, principal, role)`, so redeploys find the same assignment.

## `distributed_crm_worker` — current state

Built: `ReturnRequestConsumer` (a hosted service on a `WebApplication` host that maps only the health endpoints) processes `return-requests` (see above), `ProcessReturnRequestHandler` calls the simulated approval API, commits the new status to Postgres before acking, and invalidates `be`'s `returnrequest:{id}` cache key. It exports traces, metrics and logs as `distributed-crm-worker` (see Telemetry). Per `decisions.md`, it shares no code with the API's Domain/Application projects.

## `distributed_crm_fe` — current state

Default Vite + React + TypeScript scaffold only. No app code written yet.
