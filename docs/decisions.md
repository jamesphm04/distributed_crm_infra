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
