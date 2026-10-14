# Architecture

Snapshot of how the system is actually built today.
For *why* the non-obvious choices were made, see [`decisions.md`](decisions.md).

## Repos and backing services

```
distributed_crm_be       ASP.NET Core API — Clean Architecture (Domain/Application/Infrastructure/Api), MVC controllers
distributed_crm_worker   ASP.NET Core Worker Service — consumes the queue, calls a simulated flaky third-party API
distributed_crm_fe       React + TypeScript (Vite), linted with Oxlint

Postgres   — system of record: `return_requests`, plus `outbox_messages`
Redis      — idempotency store + read-through cache
RabbitMQ   — async handoff from API to worker, with a retry/DLX topology
```

All three backing services, plus `be` and `worker`, run via `docker-compose.yml` in this repo. Port mappings are in `setup.md`.

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

Every endpoint requires `Authorization: Bearer <Google ID token>` from an allowlisted email — see "Authentication" below.

| Endpoint | Notes |
|---|---|
| `POST /api/return-requests` | Requires `Idempotency-Key` header. Creates the record and an `outbox_messages` row in one transaction; the outbox relay publishes the `created` event to RabbitMQ. |
| `GET /api/return-requests/{id}` | Cache-aside read through Redis. |
| `GET /api/return-requests?page=&pageSize=` | Paginated list, no caching. |
| `POST /api/return-requests/{id}/cancel` | Optimistic concurrency (`xmin` token) + state-machine guard, both map to `409`. |

Clean Architecture layering: `Domain` has zero external dependencies; `Application` defines the ports (`IReturnRequestRepository`, `IUnitOfWork`, `IIdempotencyStore`, `IReturnRequestCache`, `IReturnRequestQueue`) and the use-case handlers; `Infrastructure` implements those ports against Postgres/Redis/RabbitMQ; `Api` wires DI, handles authentication/authorization, and exposes controllers.

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
- The allowlist policy is both the default and the fallback authorization policy, so any endpoint without `[AllowAnonymous]` is protected. Only the dev OpenAPI document is anonymous.
- Config: `GoogleAuth:ClientId` and `GoogleAuth:AllowedEmails` (validated at startup). Values come from user secrets or `distributed_crm_infra/.env`, never from git.
- `worker` has no auth — it never receives HTTP requests.

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

## Queue + retry topology (RabbitMQ)

`RabbitMqReturnRequestQueue` implements `IReturnRequestQueue`, published to by the outbox relay (`OutboxPublisherBackgroundService`); `ReturnRequestConsumer` in `distributed_crm_worker` consumes. Phase 7 replaces this with Azure Service Bus.

Three-exchange retry/DLX pattern (avoids needing the delayed-message-exchange plugin):

```
API publish ("created")
        │
        ▼
Exchange: return-requests ────▶ Queue: return-requests.process  ◄── worker consumes here
                                          │
                              success ◄───┴───▶ failure (nack, requeue:false)
                                │                       │
                               ack                x-dead-letter-exchange
                                                  = return-requests.retry
                                                          │
                                                          ▼
                                          Exchange: return-requests.retry
                                                          │
                                                          ▼
                                          Queue: return-requests.retry
                                          (no consumer — waits out x-message-ttl = 30s)
                                                          │
                                          TTL expires → x-dead-letter-exchange
                                          = return-requests (loops back to top)


  After N failed attempts (checked via the x-death header — not automatic):
                                          Exchange: return-requests.dlx
                                                          │
                                                          ▼
                                          Queue: return-requests.dlq
                                          (terminal — no consumer, no TTL, human inspects)
```

Message payload is just `{ returnRequestId }` — the worker re-fetches current state from Postgres rather than trusting a possibly-stale embedded payload.

Topology is declared idempotently by `RabbitMqReturnRequestQueue.DeclareTopologyAsync`, called once at API startup (forced via `app.Services.GetRequiredService<IConnection>()` right after `builder.Build()`, since `AddSingleton` alone is lazy and won't run the factory until something resolves it). The worker declares the same topology independently at its own startup.

## `distributed_crm_worker` — current state

Built: `ReturnRequestConsumer` subscribes to `return-requests.process`, `ProcessReturnRequestHandler` calls the simulated approval API, commits the new status to Postgres before acking, and invalidates `be`'s `returnrequest:{id}` cache key. Per `decisions.md`, it shares no code with the API's Domain/Application projects.

## `distributed_crm_fe` — current state

Default Vite + React + TypeScript scaffold only. No app code written yet.
