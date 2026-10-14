# Decisions

An ADR-style log of the non-obvious choices made so far, and why. Ordered roughly by when each was made.

## Full Clean Architecture, even though the domain is tiny

**Decision:** `distributed_crm_be` follows full Clean Architecture (Domain/Application/Infrastructure/Api, compiler-enforced project references) despite having a single entity.

**Why:** this project's stated priority is learning conventional/production-grade structure, not minimal ceremony (`CLAUDE.md`). A small domain doesn't change the target pattern.

## Idempotency: claim-then-finalize, not check-then-store

**Decision:** `RedisIdempotencyStore.TryClaimAsync` atomically claims the key (`SET NX`) with an `"IN_PROGRESS"` marker *before* doing any work, and only overwrites it with the real response *after* the work succeeds.

**Why:** a naive "check if key exists → do the work → store the result" flow still races: two concurrent requests with the same key can both pass the "check" step before either has stored anything, producing two Postgres rows despite a shared idempotency store. Claim-then-finalize closes that window because the claim itself is the atomic operation, not a separate check.

**Also ruled out:** an in-memory store (`ConcurrentDictionary` per instance) — this was the original stub, and was deliberately broken via a live two-instance test (same `Idempotency-Key` sent to two `dotnet run` processes, each with its own private dictionary) to prove why state must live in a shared external store once there's more than one API instance.

## Read cache: cache-aside + TTL + explicit invalidation (both, not either)

**Decision:** `RedisReturnRequestCache` is a lazy-loading (cache-aside) cache with a 5-minute TTL, and `CancelReturnRequestHandler` explicitly invalidates the cache entry right after the write commits.

**Why:** TTL alone tolerates a stale window (up to 5 minutes of a cancelled request still looking `Pending` to another instance); invalidation alone risks permanent staleness if some future write path forgets to invalidate. Using both is the real-world convention — verified live by cancelling on one instance and immediately reading from a second instance, confirming it returned fresh `Cancelled` data instead of a stale cached `Pending` copy.

**Why cache invalidation lives in the handler, not a repository decorator:** `CancelReturnRequestHandler` mutates the entity via `returnRequest.Cancel()` and calls `IUnitOfWork.SaveChangesAsync()` directly (EF Core change tracking) — there's no explicit repository "update" method call a decorator could hook into.

## Two Redis interfaces, not one

**Decision:** `IIdempotencyStore` and `IReturnRequestCache` are separate interfaces, even though both are Redis-backed.

**Why:** different atomicity/overwrite semantics. A cache value is always safe to overwrite or let expire. An idempotency claim must never be silently overwritten by a second writer — that's the entire point of the `NX` claim. Collapsing them into one interface would blur a distinction that matters.

## RabbitMQ: three-exchange retry/DLX pattern

**Decision:** main exchange/queue → (on failure) retry exchange/queue with a TTL → (on TTL expiry) back to main → (after N failures, tracked via the `x-death` header) explicit publish to a DLX/DLQ.

**Why:** this is the standard, plugin-free way to get delayed retries in RabbitMQ — a message TTL plus `x-dead-letter-exchange` chaining does the delay without needing the non-core delayed-message-exchange plugin. It's the enterprise-conventional answer, matching this project's stated priority of favoring the standard/well-structured approach even where a thinner one would technically work.

**Note:** the first two hops (main → retry, retry → main) are fully automatic, driven by queue arguments — no application code runs. The final hop (→ DLX after max retries) is NOT automatic; RabbitMQ has no built-in "give up after N attempts" behavior, so the worker's consumer reads the `x-death` count itself and explicitly publishes to the DLX exchange once the limit is hit (`ReturnRequestConsumer.HandleFailureAsync`). Verified live: a forced-failure message cycled through 3 retries (30s TTL each) and landed in `return-requests.dlq`, with the `ReturnRequest` row correctly left at `Processing` rather than forced to a false `Approved`/`Rejected`.

**Message payload:** just `{ returnRequestId }`, not the full entity. The worker always re-fetches current state from Postgres, avoiding stale-payload bugs if the record changes between publish and consume.

## Worker does not share code with the API

**Decision:** `distributed_crm_worker` will get its own thin data-access layer (its own EF Core mapping to the same `return_requests` table, its own copy of the status enum values) rather than a project reference to `distributed_crm_be`'s Domain/Application projects.

**Why:** these are independently deployed, independently versioned repos (`CLAUDE.md`). A cross-repo project reference would silently break that — a Domain change would force both services to rebuild/redeploy together, which defeats the point of separating them. The shared Postgres schema is the integration point between the two services, not shared C# code. This mirrors how real microservices with separate deployment lifecycles are built.

## `RabbitMQ.Client` v7 (async API), and eager singleton resolution

**Decision:** using `RabbitMQ.Client` 7.2.2's `IChannel`/`IConnection` async API (not the older `IModel`-based v6 API). The `IConnection` singleton is force-resolved right after `builder.Build()` via `app.Services.GetRequiredService<IConnection>()`.

**Why the eager resolution:** `AddSingleton` only registers a factory — it doesn't run it until something actually requests the service. Without forcing resolution, `DeclareTopologyAsync` wouldn't run until the first real publish call, meaning the app would report a clean startup even if RabbitMQ were unreachable, and a real user's first request would be the one to fail. Forcing resolution at boot makes the app fail fast on a missing dependency instead, which is the more production-appropriate failure mode.

## No `.gitignore` existed before the first commit

**Decision:** added a standard .NET `.gitignore` (`bin/`, `obj/`, `*.user`, `.idea/`, `.vscode/`, `.DS_Store`) to `distributed_crm_be` before its first-ever commit.

**Why:** the repo had never been committed, so build output and Rider IDE settings (`.idea/`, `*.DotSettings.user`) were sitting untracked alongside real source — committing them would have polluted the first commit with machine-local artifacts.

## JSON property casing must be made explicit across the producer/consumer boundary

**Decision:** the worker deserializes incoming RabbitMQ messages with `JsonSerializerOptions { PropertyNameCaseInsensitive = true }`, rather than relying on `System.Text.Json`'s default (case-sensitive) behavior.

**Why:** found live, during Phase 4 testing. The producer serializes an anonymous object (`new { returnRequestId }`), which `System.Text.Json` writes out verbatim as `"returnRequestId"` (camelCase). The consumer originally deserialized into a record with the property `ReturnRequestId` (PascalCase). Case-sensitive matching couldn't bind the field, so it silently fell back to `Guid.Empty` instead of throwing — `ProcessReturnRequestHandler` then correctly looked up "no such record," returned `NotFound`, and the consumer acked the message as if it had succeeded. The real `ReturnRequest` row was never touched and stayed `Pending` forever, with no exception, no retry, no DLQ entry — nothing to alert on. This is a sharper version of the "ack-before-work-is-verified" failure mode discussed earlier: the work wasn't even attempted, yet the message was still removed as if it had been.

**Lesson:** a cross-process JSON contract (producer and consumer are separate repos, separate serializer configurations) needs an explicit, agreed-on casing convention — ASP.NET Core's model binder hides this exact issue on the API side by defaulting to case-insensitive matching, which is why it never surfaced there.

## Startup resilience: healthchecks are a dev convenience, not a substitute for retry

**Decision:** `docker-compose.yml` gates `be`/`worker`'s startup on `depends_on: condition: service_healthy` for `postgres`/`redis`/`rabbitmq` — but the apps themselves also retry their initial RabbitMQ connection (exponential backoff, capped at 30s, max 10 attempts) and use EF Core's `EnableRetryOnFailure()` for Postgres.

**Why:** `depends_on`/healthchecks only exist in Compose, and only govern the moment a container starts — they do nothing if a dependency restarts an hour into a long-running process, and no such mechanism exists at all once this moves to a real orchestrator (ECS, Kubernetes). Since this project is meant to become a real SaaS template, the apps need to tolerate a dependency being transiently unavailable on their own, not rely on orchestration-level sequencing. Previously, a single failed `CreateConnectionAsync` call threw an unhandled exception at startup with no recovery.

**Also found along the way:** the Compose-level healthcheck for RabbitMQ (`rabbitmq-diagnostics ping`) checks Erlang node liveness, not whether the AMQP listener is actually bound — confirmed via timestamps that `be` started while RabbitMQ's TCP listener on 5672 was still ~2 seconds from binding, despite the healthcheck already reporting "healthy." Switched to `rabbitmq-diagnostics check_port_connectivity`, which checks the real listener ports. This is still just a dev-startup fix — the retry-with-backoff in the app is the actual resilience mechanism.

## Compose published ports must bind to 127.0.0.1, not 0.0.0.0

**Decision:** every `ports:` entry in `docker-compose.yml` (`postgres`, `redis`, `rabbitmq`, `be`) explicitly binds to `127.0.0.1` (e.g. `"127.0.0.1:5672:5672"`), instead of the bare `"5672:5672"` form.

**Why:** found live. `"5672:5672"` with no host IP binds to `0.0.0.0` — every network interface the host has, not just loopback. James's Mac has active Tailscale VPN tunnel interfaces (`utun0`–`utun10`), each its own network path into the machine. RabbitMQ's queue showed two consumers instead of one; the second connection's peer address (`167.82.48.223`) matched neither James's Tailscale-assigned address nor his real public IP — meaning something reached RabbitMQ's default `guest`/`guest` credentials through one of those non-loopback interfaces. RabbitMQ does restrict the `guest` user to loopback connections by default specifically to prevent "default creds reachable externally," but that check only looks at whether the connection arrived via `127.0.0.1` — a VPN tunnel interface doesn't count, so the protection never applied.

**Lesson:** for a project meant to become a real SaaS template, backing infrastructure (DB, broker) should never be bound to a public-facing or VPN-facing interface, even for local dev — bind to loopback explicitly rather than relying on "well, nobody will connect to it." This is the simplest local analogue of why real deployments put this infrastructure in a private subnet rather than exposing it directly.

## Transactional outbox for the create path, not a direct publish

**Decision:** `CreateReturnRequestHandler` no longer calls `IReturnRequestQueue` directly. It writes a row to a new `outbox_messages` table in the same `SaveChangesAsync` as the `ReturnRequest` insert. A separate `OutboxPublisherBackgroundService` polls for unprocessed rows every second and does the actual RabbitMQ publish, retrying indefinitely on failure.

**Why:** a DB write and a message-queue publish aren't one atomic operation — they're two different systems with no shared commit protocol. Found live: if the publish failed (RabbitMQ down, network blip) after the row had already committed, nothing would ever enqueue a message for it, and the row sat at `Pending` forever with no error anywhere. The transactional outbox is the standard, conventional fix: Postgres can make "real data + outbox row" atomic because they're both just inserts in one transaction; the publish itself becomes "eventually guaranteed" via the relay, not "best effort, and if it fails you're on your own."

**Also ruled out:** a retry loop wrapped around the publish call itself. This wouldn't survive a process crash between the DB commit and the publish attempt — an in-memory retry dies with the process. The outbox row surviving in Postgres is what makes the guarantee durable across crashes, not just transient network blips.

**Payload shape:** the outbox entry stores a plain `ReturnRequestId` column, not a serialized JSON blob. There's only one message type right now, so a typed column is simpler and safer than generic JSON (no case-sensitivity risk, type-checked) — a repeat of the Phase 4 camelCase/PascalCase bug isn't possible here. If a second message type is ever needed, generalize the outbox then, not preemptively.

## Worker invalidates `be`'s Redis cache directly, by key convention, not shared code

**Decision:** `worker` gets its own `IReturnRequestCacheInvalidator`/`RedisReturnRequestCacheInvalidator`, calling `KeyDeleteAsync("returnrequest:{id}")` directly against the same Redis instance, right after every status transition commits.

**Why:** found live. `be`'s `GetById` cache (`decisions.md`, "Read cache" entry above) was only ever invalidated by `CancelReturnRequestHandler` inside `be` itself — `worker` had no mechanism to invalidate it at all, so any `GetById` call made shortly before the worker finished processing would keep returning a stale cached status for up to the full 5-minute TTL. Since status polling is the primary thing a client does with this endpoint, this wasn't a cosmetic edge case.

**Why not shared code instead:** `worker` deliberately has no project reference to `be` (see "Worker does not share code with the API" above) — these are independently deployed repos. The fix keeps that boundary: `worker` only knows the cache *key format* as a convention (documented in both files), never `be`'s actual cache implementation or response shape.

## `AbortOnConnectFail = false`, not a hand-rolled retry loop, for Redis startup resilience

**Decision:** both `be` and `worker` construct their `IConnectionMultiplexer` via `ConfigurationOptions.Parse(...)` with `AbortOnConnectFail = false`, instead of wrapping `ConnectionMultiplexer.Connect` in a manual retry-with-backoff loop (the pattern used for RabbitMQ's `IConnection`).

**Why:** found live — `be`'s original Redis registration was a single blocking `ConnectionMultiplexer.Connect` call with no retry at all, the same startup-ordering gap already fixed for RabbitMQ and Postgres in Phase 5, just missed for Redis. `AbortOnConnectFail = false` is StackExchange.Redis's own idiomatic answer to this: the initial `Connect()` call won't throw even if Redis isn't reachable yet, and the multiplexer keeps retrying in the background on its own. A hand-rolled loop would just be reimplementing what the client already does correctly.

## Rehearse every WCP component, on managed Azure services

**Decision:** from Phase 6 on, this project gives every component of the WCP portal's target architecture at least one thin but real use: Google sign-in, Azure Service Bus, Container Apps, PostgreSQL Flexible Server, Managed Redis, Key Vault with managed identity, Application Insights, Container Registry, Bicep, GitHub Actions, a React + Ant Design frontend on Static Web Apps, Blob Storage, and a Python ingestion job on Container Apps Jobs.
The original Phase 6 — self-hosted Postgres/Redis/RabbitMQ containers on AWS EC2 behind an ALB — is dropped.

**Why:** this project is the rehearsal for WCP, so each component should be proven on the platform WCP will actually run on before the real build depends on it.
WCP's other apps already run on Azure, and a one-developer team shouldn't patch its own brokers and databases in production.

**Order:** local changes first (auth, Service Bus, deploy readiness), then the Azure foundation and pipeline, then each remaining component shipped through that pipeline.
Deploying early means every later component goes out the same way it will in WCP.

**What's given up:** hands-on server operations — patching VMs, running a broker yourself, configuring a load balancer by hand.
RabbitMQ's three-exchange retry/DLX topology (Phase 4) stays as completed learning; Phase 7 maps the same design onto Service Bus's built-in max delivery count, dead-letter queue, and scheduled redelivery.


## Google ID tokens validated by `AddJwtBearer`, allowlist as an authorization handler

**Decision:** the API is a plain JWT bearer resource server with Google as the authority.
Authentication (who are you?) is entirely `Microsoft.AspNetCore.Authentication.JwtBearer`; authorization (are you allowed in?) is a custom `AllowedEmailRequirement` + `AllowedEmailHandler`.
No login endpoint, no sessions, no `users` table.

**Why these specific settings:**
- **Both issuer spellings** (`https://accounts.google.com` and `accounts.google.com`) — Google documents both as valid for ID tokens.
- **Audience = our OAuth client ID** — this is what stops a Google ID token minted for any *other* app from working here.
- **`MapInboundClaims = false`** — keeps Google's claim names (`email`, `email_verified`, `sub`) instead of rewriting them to `http://schemas.xmlsoap.org/...` URIs, so the handler reads the same names you see when decoding the token.
- **`email_verified` must be `true`** — otherwise an unconfirmed Google account using someone else's address would pass the allowlist.
- **JwtBearer configured via `AddOptions<JwtBearerOptions>().Configure<IOptions<GoogleAuthOptions>>(...)`**, not a lambda inside `AddJwtBearer(...)` — the lambda runs before DI exists and would need a second, unvalidated read of `IConfiguration`.
- **The handler never calls `context.Fail()`** — not succeeding is the conventional denial; `Fail()` would veto even if another handler for the same requirement succeeded.

**Secure by default:** the same policy is both the default policy (what bare `[Authorize]` means — otherwise it would only mean "any valid Google token", i.e. any Google user in the world) and the fallback policy (applies to any endpoint with no attribute at all).
Public endpoints opt out explicitly with `AllowAnonymous` — the dev OpenAPI document now, `/health` in Phase 8.
`[Authorize]` is still on the controller so the intent is visible where the code is read.

**401 vs 403:** left to the framework. A failed policy with no authenticated user is a challenge (`401`, `WWW-Authenticate: Bearer`); with an authenticated user it's a forbid (`403`).

**Config section named `GoogleAuth`, not `Authentication`:** ASP.NET Core reads its own `Authentication:` section (`DefaultScheme`, `Schemes:Bearer:*`); mixing our keys in there would be confusing.

**Where WCP differs:** WCP additionally rejects tokens whose `hd` claim isn't its Workspace domain (one extra check in the handler), and replaces the allowlist with a `Users` table + roles (WCP ADR-006).

## Real config values never go in either public repo

**Decision:** `appsettings.json` only documents the shape of `GoogleAuth` with empty values.
Real values come from `dotnet user-secrets` (for `dotnet run`) and a gitignored `distributed_crm_infra/.env` (for Compose), with `.env.example` committed as the template.

**Why:** `distributed_crm_be` and `distributed_crm_infra` are both public on GitHub.
The client ID isn't secret, but the allowlist holds a real work email; keeping both in the same place also matches Phase 8's "all config from environment variables".
`ValidateOnStart()` plus Compose's `${VAR:?message}` make a missing value fail loudly at startup instead of turning into silent `401`/`403`s.

## `Gss Encryption Mode=Disable` on every Postgres connection string

**Decision:** every Npgsql connection string (Compose for `be` and `worker`, both `appsettings.Development.json`) ends with `Gss Encryption Mode=Disable`.

**Why:** Npgsql tries GSS/Kerberos session encryption by default on first connect, which needs the native `libgssapi_krb5` library — not present in the slim .NET runtime images.
It falls back to a normal connection, but prints `Cannot load library libgssapi_krb5.so.2` / `Error:` on every startup, which trains you to ignore errors.
Nothing here uses Kerberos (password locally; TLS + password or Entra token on Azure), so disabling it states the truth.
Installing `libgssapi-krb5-2` in the images was ruled out — it adds image size and attack surface to support a feature that's never used.

**Carry forward:** the Azure connection string built in Phase 9/10 (Bicep / Key Vault) needs the same setting.

## EF Core's per-command log raised to `Warning`

**Decision:** `Microsoft.EntityFrameworkCore.Database.Command` is set to `Warning` in both apps' `appsettings.json`.

**Why:** the outbox poller queries once a second, so at `Information` `be` logged ~86,000 SQL lines a day, burying the lines that matter (e.g. the allowlist handler's `Denied` warnings).
At `Warning`, EF still logs failed and slow commands. In Phase 10 the same noise would also be billed per GB by Application Insights.

## DataProtection startup warnings left alone

**Decision:** the "keys stored in a directory that may not be persisted" and "No XML encryptor configured" warnings from `be` are not suppressed or fixed.

**Why:** `AddAuthentication` registers ASP.NET Core DataProtection, which warms up a key ring at startup — but nothing in this API uses it.
JwtBearer validates tokens with Google's public keys, not DataProtection, and there are no cookies or antiforgery tokens.
Persisting keys to Redis/Blob would add infrastructure for nothing; silencing the category would hide the warning if something ever *does* start using DataProtection.

**Revisit if:** anything starts using DataProtection (cookie auth, antiforgery, `IDataProtector`). With 2 replicas in Phase 10, keys must then be shared (Blob Storage + Key Vault is the Azure-conventional pair), or a value protected on one replica can't be read on the other.
