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

## Service Bus retries: scheduled copy + explicit dead-letter, with `MaxDeliveryCount` as the crash net

**Decision:** on a processing failure the worker schedules a copy of the message 30s ahead (`retry-count` + 1 in its application properties) and completes the original.
After 3 retries (4 attempts, same as Phase 4) it dead-letters the message explicitly with reason `MaxRetriesExceeded`.
The queue's `MaxDeliveryCount` (5) is only the safety net for crashes and lost locks.

**Why not just abandon and let `MaxDeliveryCount` do the retries:** abandon redelivers *immediately* — no backoff, so all attempts burn through within seconds against a failing third-party API.
Scheduled messages are Service Bus's built-in way to delay, replacing Phase 4's TTL holding-pen queue.

**Why schedule-then-complete, not a transaction:** two separate calls, ordered so a crash in between causes one extra attempt (tolerated by the handler's status guards and `xmin`), never a lost message.
Service Bus transactions could make it atomic, but that's extra machinery for a failure mode that's already harmless here.

**Each retry copy gets its own `MessageId`** (`…:retry-N`) — otherwise duplicate detection would drop it as a repeat of the original.

**Malformed payloads**, including `{}` (which deserializes to `Guid.Empty` rather than failing), are dead-lettered immediately with reason `MalformedPayload`.

## Deterministic `MessageId` + duplicate detection instead of changing the outbox port

**Decision:** `be` sets `MessageId = return-request-created:{returnRequestId}` and the queue has duplicate detection on.

**Why:** the outbox relay can send twice if it crashes between `SendMessageAsync` and `MarkProcessed()`. Duplicate detection drops the repeat inside its window.
The outbox row's own id would also work, but `IReturnRequestQueue` only receives the return-request id; since there's exactly one "created" event per return request, that id is already unique per event, and the Application-layer port stays unchanged.
Verified live: two sends with the same `MessageId` both reported success, and only one message was in the queue.

## Queue topology lives outside the apps

**Decision:** neither app declares queues. The emulator reads `servicebus/Config.json`; Azure gets the same queue from Bicep (Phase 9).

**Why:** in Phase 4 both apps declared identical RabbitMQ topology at startup, which duplicated it in two repos and needed management rights at runtime.
With Service Bus, topology is infrastructure: the apps only need send/receive rights, which is also what their managed identities will be granted in Phase 9 (`Azure Service Bus Data Sender` / `Data Receiver`), not `Manage`.

**Emulator limits found by running it:** duplicate-detection window at most 5 minutes (the emulator refuses to start otherwise), message TTL at most 1 hour.
Azure gets 10 minutes and 14 days. Bicep must also set `deadLetteringOnMessageExpiration: true` and `requiresDuplicateDetection: true` — the latter can only be set when a queue is created.

## No hand-rolled connection retry for Service Bus

**Decision:** both apps register `ServiceBusClient` through `Microsoft.Extensions.Azure` (`AddAzureClients`) and rely on the SDK's lazy connect + built-in retry. The RabbitMQ retry-with-backoff loops and the forced eager resolution in both `Program.cs` files are deleted, not ported.

**Why:** same lesson as `AbortOnConnectFail = false` for Redis — use the client's own resilience instead of reimplementing it.
Verified live: the worker started ~25s before the emulator was ready, logged `Connection refused` warnings, and attached its receiver on its own once the emulator came up.
With the emulator stopped while `be` was running, a new request stayed `Pending` with its outbox row unrelayed, then went to `Approved` within ~30s of the emulator restarting — nothing lost.

**Compose consequence:** the emulator image is distroless (no shell, no `curl`), so it can't have a Docker healthcheck. `be`/`worker` use `depends_on: condition: service_started`; the apps' own retry is what actually matters (Phase 5 lesson).

## Azure SDK logs at `Warning`

**Decision:** `Azure.Core` and `Azure.Messaging.ServiceBus` are set to `Warning` in both apps.

**Why:** at `Information` the SDK logs several lines per send/receive (link creation, operation start/complete). At `Warning`, a normal create → `Approved` cycle produces zero log lines, while connection problems still show up.

## Liveness checks nothing; readiness checks every dependency

**Decision:** `/health/live` runs zero checks (`Predicate = _ => false`).
`/health/ready` runs the checks tagged `ready`: Postgres, Redis and Service Bus.

**Why:** the platform restarts a container that fails liveness, and stops routing to one that fails readiness.
A dependency check in liveness would turn a short Redis outage into every replica restarting at once, which doesn't fix Redis and adds an outage of its own.
Verified live: with Redis stopped, liveness stayed `200` and readiness went `503`, then recovered without a restart.

## Own health checks for Redis and Service Bus, through the app's own clients

**Decision:** `RedisHealthCheck` pings through the app's `IConnectionMultiplexer`; `ServiceBusQueueHealthCheck` peeks the queue through the app's `ServiceBusClient`.
Postgres uses EF Core's `AddDbContextCheck`.

**Why:** a probe should test the connection requests actually use, not a fresh one.
The `AspNetCore.HealthChecks.Redis` package is built against StackExchange.Redis 2.x (this project is on 3.3).
The Service Bus check uses peek because it needs only Listen rights; the management API would need `Manage`, which the Phase 9 identities won't have.
The Service Bus check is a DI singleton: the health-check system resolves registered instances instead of creating one per probe, so it holds one receiver link for the app's lifetime instead of leaking one per probe.

## Every health check capped at 5 seconds

**Decision:** a `PostConfigure<HealthCheckServiceOptions>` sets `Timeout = 5s` on every registration.

**Why:** the default is no timeout, and `AddDbContextCheck` has no timeout parameter.
Without a cap, a hung dependency hangs the probe, and repeated probes pile up inside the app.
The cap works by cancelling the check's `CancellationToken`, so it only shortens checks that accept one: the Redis ping doesn't, and is bounded by Redis's own 5 s timeout instead.

## Forwarded headers trusted from any proxy

**Decision:** `UseForwardedHeaders` with `XForwardedFor | XForwardedProto`, `KnownIPNetworks` and `KnownProxies` cleared, `ForwardLimit` left at 1.
`UseHttpsRedirection` is removed.

**Why:** Container Apps terminates HTTPS at its ingress and forwards plain HTTP, so without this the app sees every request as `http` from the proxy's IP: `CreatedAtAction` would build `http://` `Location` headers and the redirect middleware would redirect requests that were already HTTPS.
The ingress's address isn't known in advance, so the known-proxy lists are cleared.
That is only safe because the ingress is the only way into the container and sets these headers itself; `ForwardLimit` 1 reads only the entry the ingress appended.
If the API is ever reachable another way, this has to change.

## Migrations as an idempotent SQL script, applied by a separate job

**Decision:** `dotnet ef migrations script --idempotent` runs inside the `be` Docker build (`migrations-script` stage) and the result ships in a `postgres:17`-based `migrate` image that applies it with `psql -v ON_ERROR_STOP=1`.
Locally it's a one-shot Compose service that `be` and `worker` wait for; in Phase 10 the pipeline runs it before deploying.
`dotnet-ef` is pinned in `dotnet-tools.json`.

**Why not `Database.Migrate()` at startup:** two replicas would race, the app would need schema-change rights, and a failed migration would take the app down with it.
**Why a script over a migration bundle:** EF Core's docs recommend SQL scripts for production because the SQL can be reviewed before it runs; a bundle is an executable that can't be.
**Why idempotent:** each migration is guarded by a check against `__EFMigrationsHistory`, so the same file is safe against a database at any version, any number of times.


## `.dockerignore` in every image repo

**Decision:** both `be` and `worker` exclude `**/bin/`, `**/obj/`, `.git/`, IDE folders, `*.user`, `**/.DS_Store`, `**/.env`, the `Dockerfile` and `.dockerignore` from the build context.

**Why:** `COPY . .` copies whatever the context holds.
Host `obj/` folders carry `project.assets.json` with the Mac's absolute NuGet paths, so a container build could start from another machine's restore state.
A `.env` copied into a layer stays readable in the image even if a later layer deletes it.
Every host build also changed `bin/`, which invalidated the `COPY` layer and everything after it.
The context went from ~50 MB to ~324 KB.
Patterns are case-sensitive even on macOS's case-insensitive file system.

## Images run as the non-root `app` user

**Decision:** `USER $APP_UID` in both runtime stages, after anything that needs root (installing `tini`).

**Why:** a compromised process running as root in a container is one kernel bug away from root on the host, and can rewrite its own image's files.
Microsoft's .NET 8+ images ship the `app` user (UID 1654) and listen on 8080 by default for exactly this: ports below 1024 need root.
The migration image is left as `postgres:17`'s default user because it only runs `psql` against a remote server and exits.

## Compose project name pinned

**Decision:** `name: distributed_crm` at the top of `docker-compose.yml`.

**Why:** without it, the project name is the folder name, and Compose labels and prefixes everything with it.
The data volume was created when this file lived in `distributed_crm/`, so after the move to `distributed_crm_infra/` it warned on every `up` that it belonged to another project.
Pinning the name makes the project independent of where the repo is cloned.
The switch needs `docker compose down` first, while Compose still recognises the old containers as its own.

## Required config read at startup, not on first use

**Decision:** both apps read their connection strings through `GetRequiredConnectionString` (in each repo's `Configuration/ConfigurationExtensions.cs`) before the host is built.
A missing or blank value throws, naming the environment variable to set.

**Why:** all config comes from environment variables, so a typo in a Container Apps setting is the likely failure.
Thrown at startup, the new revision never becomes healthy and the platform keeps traffic on the old one; the log names the missing variable.
Read lazily, the app would pass liveness, take traffic, and fail user requests with an error deep inside a client library.
The two repos each have their own copy of the helper, keeping the no-shared-code rule.

## Design-time `DbContext` factory for the EF tools

**Decision:** `DistributedCrmDbContextFactory` (`IDesignTimeDbContextFactory`) in `be`'s Infrastructure builds the context with `UseNpgsql()` and no connection string, plus snake-case naming.

**Why:** without it, `dotnet ef` builds the app's host to find the `DbContext`, which runs `Program.cs`.
That only worked because `appsettings.Development.json` supplied connection strings, and it broke once startup required them.
Generating a migration or a script needs the model and the provider, not a database, so the tools should not need app config at all.
The factory must apply the same conventions as `Program.cs`, or migrations would be generated against a different model.

## The worker is a web host with only health endpoints

**Decision:** the worker uses the Web SDK, `WebApplication.CreateBuilder` and the `aspnet` runtime image, and maps only `/health/live` and `/health/ready`, with the same checks as `be`.
It has no authentication and no forwarded headers, and Container Apps will give it no external ingress.

**Why:** Container Apps' probes are HTTP or TCP; a plain Worker Service has nothing for a probe to hit.
A TCP probe would only prove a port is open, not that Postgres, Redis and Service Bus are reachable.
The alternative, a hand-rolled `HttpListener` or a file-based probe, is more code for a worse version of what ASP.NET Core already does.
The health-check classes are copied from `be`, not shared, per the no-shared-code rule.

## `tini` as PID 1 in both images

**Decision:** both runtime stages install `tini` and use `ENTRYPOINT ["tini", "--", "dotnet", "<app>.dll"]`.

**Why:** the first process in a container is PID 1, and the kernel ignores signals with a default action for PID 1 unless it installed a handler.
.NET ends an unhandled crash with `abort()`, so its `SIGABRT` was dropped and the process spun at ~100% CPU instead of exiting; verified live, and verified fixed by `docker run --init`.
`tini` makes the app an ordinary child process, exits with its exit code (`134` for an abort), forwards `SIGTERM` for graceful shutdown, and reaps zombie processes.
It is baked into the image rather than relying on `docker run --init`, because Container Apps has no equivalent option.

## OTLP to the Aspire dashboard locally, console exporter only on request

**Decision:** both apps export traces, metrics and logs with `UseOtlpExporter()`.
Locally they send to the .NET Aspire dashboard container; `Telemetry:ConsoleExporter=true` adds a console exporter for traces and metrics.

**Why:** OTLP is the vendor-neutral protocol every backend accepts, so Phase 9 changes `OTEL_EXPORTER_OTLP_ENDPOINT` (and its auth), not the instrumentation.
A console exporter alone prints one span at a time and can't show a trace as a tree across two services, which is the point of Step 11.
The dashboard is one container, keeps everything in memory, and also shows metrics and logs linked to traces.
Neither app `depends_on` it: if it is down, the exporter drops data after a timeout and the apps keep serving.

## Telemetry wiring lives in each host project; Infrastructure uses plain `ActivitySource`

**Decision:** the OpenTelemetry packages and `AddTelemetry()` are only in `DistributedCrm.Api` and `DistributedCrm.Worker`.
Spans written by our own code use a `System.Diagnostics.ActivitySource` (`InfrastructureTelemetry`, named `DistributedCrm.Infrastructure`) that the host subscribes to.

**Why:** choosing exporters and instrumentation is composition-root work, like DI.
`ActivitySource` is part of .NET itself, so Infrastructure can emit spans without depending on OpenTelemetry, which is exactly how the libraries we instrument (Npgsql, the Azure SDK) do it.
Each repo has its own copy of the extension and the source, per the no-shared-code rule.

## Service name in code, endpoint in the environment

**Decision:** `service.name` is set with `AddService(TelemetryExtensions.ServiceName)`; the export endpoint comes from the standard `OTEL_EXPORTER_OTLP_ENDPOINT` variable.

**Why:** the service name describes the code and must be identical in every environment, so App Insights' cloud role name never drifts.
The endpoint describes the environment.
`AddService` overrides `OTEL_SERVICE_NAME`, so that variable is not set anywhere, to avoid configuration that looks meaningful but isn't.

## Trace only what is part of a story

**Decision:** no traces for `/health/*`; Npgsql traces a command or batch only when `Activity.Current` is set; `be` does not trace physical connection opens.
Metrics still count everything.

**Why:** platform probes and the outbox relay's once-a-second poll produced almost all traces (187 of ~200), each a one-span trace that buries real requests and is billed per GB in Application Insights.
Filtering the ASP.NET Core request also drops the health checks' child spans, because the default sampler follows the parent's decision.
Npgsql has no filter for physical opens, and the pool reopening its idle connection made a root span every 5 minutes, so `be` turns them off; the worker keeps them, because there every open happens inside a message's span, where it explains a slow first query.
The Service Bus SDK's `ServiceBusReceiver.Receive` root span is kept: it is one per received message, not per poll, and it is the standard view of receive latency.

## The outbox stores the request's `traceparent`; the relay continues that trace

**Decision:** `outbox_messages.trace_parent` (nullable `varchar(55)`) holds `Activity.Current.Id` from the request that wrote the row.
The relay restores it with `ActivityContext.TryParse` as the parent of an `outbox relay {MessageType}` span around the send and the `UPDATE`.

**Why:** HTTP headers and Service Bus properties carry trace context automatically, but a table only carries what it has a column for, so the relay used to start a new trace for every message.
Parent-child, rather than a span link to the request, gives one trace from the click to the worker's result, and fits because each row maps to one message and the delay is about a second; links suit batch consumers and long delays.
The column is nullable so rows written before the migration (or outside any trace) still work, and the migration only adds a column, so it can run before the new image rolls out (expand first).
Application's `IOutboxStore` is unchanged: capturing the context is how Infrastructure stores the row.

## Redis instrumentation is a beta built against SE.Redis 2.x

**Decision:** `OpenTelemetry.Instrumentation.StackExchangeRedis` 1.19.0-beta.1 is used with StackExchange.Redis 3.3.0.

**Why:** it is the only Redis instrumentation for .NET; it builds and restores cleanly against 3.3 and was verified live (cache miss `GET` → `SELECT` → `SETEX`, cache hit `GET` only).
Its spans arrive about 10 s late because it drains profiling sessions in batches.

**Revisit if:** a stable release appears, or an SE.Redis upgrade stops Redis spans appearing.
