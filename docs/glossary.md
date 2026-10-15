# Glossary

Terminology introduced while building this project, written as it was actually explained along the way.

## General

**Stateless API** — an API instance that keeps no in-process data load-bearing across requests; any instance can serve any request because all real state lives in a shared external store (Postgres, Redis). What makes horizontal scaling possible.

**Idempotency** — making a repeated request (e.g. a client retrying a `POST` after a timeout) produce the same result as making it once, instead of creating duplicates. Implemented here via an `Idempotency-Key` header.

**Idempotency-Key convention** — cache the *full response*, not just an id, so a replayed request gets an exact replay (including error responses), not just a pointer to something that may have changed.

**Cache-aside (lazy-loading)** — a caching pattern: check the cache first; on a miss, fall through to the source of truth, then populate the cache for next time. Contrast with a "write-through" cache, which populates on writes rather than reads.

**TTL (time-to-live)** — how long a cached value (or a queued message) is allowed to live before it's automatically expired/removed.

**Cache invalidation** — explicitly removing/updating a cached value when the underlying data changes, instead of waiting for its TTL to expire. This project uses TTL and invalidation together: TTL as a safety net, invalidation as the primary mechanism, because neither alone is sufficient (TTL-only tolerates staleness; invalidation-only risks permanent staleness if a write path is missed).

**Thread / thread-safety** — a thread is an OS-level unit of execution; .NET's thread pool runs concurrent request handlers on multiple threads, and `await` frees a thread during I/O rather than blocking it. An object is thread-safe if it behaves correctly when multiple threads use it concurrently — this matters for anything registered as a DI singleton (like a Redis or RabbitMQ connection), since many requests can hit it at once.

**Atomic operation** — an operation that either fully happens or doesn't, with no way for another operation to observe or interleave with it halfway through. Redis's `SET NX` is atomic: "check if the key doesn't exist, then set it" happens as one indivisible step, closing races that a separate `EXISTS` + `SET` would leave open.

**Liveness probe** — a platform's periodic "is this process stuck?" request. Failing it gets the container restarted, so it must not depend on anything outside the process. Here: `/health/live`.

**Readiness probe** — a platform's periodic "can this replica serve requests right now?" request. Failing it takes the replica out of the load balancer until it passes again, without a restart. Here: `/health/ready`, which checks Postgres, Redis and Service Bus.

**Reverse proxy / TLS termination** — a server in front of the app that receives the client's HTTPS connection, decrypts it, and forwards the request to the app over plain HTTP. Container Apps' ingress (like an AWS ALB) does this.

**Forwarded headers** — `X-Forwarded-Proto` and `X-Forwarded-For`, added by a reverse proxy to carry the original scheme and client IP. `UseForwardedHeaders` reads them back into the request. Only safe to trust when the proxy is the only way in, because any client can send them too.

**Idempotent migration script** — every EF migration in one SQL file, each wrapped in a check against `__EFMigrationsHistory`, so it applies only what's missing and can run against a database at any version, any number of times.

**One-shot Compose service** — a service that runs a job and exits, like `migrate`. Others wait for it with `depends_on: condition: service_completed_successfully`, which requires exit code `0`.

## Authentication

**Authentication vs authorization** — authentication answers "who are you?" (here: a valid Google ID token); authorization answers "are you allowed to do this?" (here: is your email on the allowlist). A failure of the first is a `401`, of the second a `403`.

**OpenID Connect (OIDC)** — a standard identity layer on top of OAuth 2.0. "Sign in with Google" is OIDC: Google authenticates the user and hands the app an ID token saying who they are.

**ID token vs access token** — an ID token is a statement *about the user* ("this is james@..., verified by Google"), meant for your own app. An access token is a key for calling *Google's* APIs (Gmail, Drive). This API validates ID tokens.

**JWT (JSON Web Token)** — the format of the ID token: `base64url(header).base64url(payload).signature`. The payload is readable by anyone — it's encoded, not encrypted. What makes it trustworthy is the signature.

**Claims** — the fields in a JWT's payload: `iss` (who issued it), `aud` (which app it's for), `exp` (expiry, Unix seconds), `email`, `email_verified`, `sub` (Google's stable user id), `hd` (Workspace domain, only on Workspace accounts).

**JWKS (JSON Web Key Set)** — the public keys Google publishes for checking its tokens' signatures. Google signs with a private key only it has; anyone can verify with the public key. JwtBearer finds the JWKS through the discovery document at `https://accounts.google.com/.well-known/openid-configuration` and refreshes it when Google rotates keys.

**Bearer token** — a token that grants access to whoever presents it ("the bearer"), sent as `Authorization: Bearer <token>`. Anyone who steals it can use it until it expires, which is why tokens are short-lived and never pasted into websites or chat.

**Clock skew** — slack allowed when checking `exp`, because the issuer's and the server's clocks never agree exactly. JwtBearer's default is 5 minutes, so a token is still accepted for up to 5 minutes after its `exp`.

**Default vs fallback authorization policy** — the default policy is what a bare `[Authorize]` means; the fallback policy applies to endpoints with no authorization attribute at all. Setting the fallback makes the API secure by default: a forgotten attribute means "locked", not "open".

## Redis

**Redis** — an in-memory data store, running as its own separate server/container. Clients connect to it over the network, the same way they connect to a database — it is not embedded in the application process.

**`IConnectionMultiplexer`** (StackExchange.Redis) — the central connection object to Redis. Meant to be a long-lived singleton, reused across the whole app, because it's thread-safe and the underlying connection is expensive to set up.

**`SET NX`** — Redis's "set if not exists" command. Used here as the atomic primitive behind the idempotency claim: the first caller to `SET NX` a given key wins the claim; everyone else's `SET NX` fails, telling them someone else got there first.

## Azure Service Bus

**Namespace** — Service Bus's top-level container (its own endpoint, e.g. `sb-distributed-crm.servicebus.windows.net`); queues live inside it. The emulator always has exactly one, `sbemulatorns`.

**Lock (peek-lock)** — when a consumer receives a message it is hidden from everyone else, not deleted, until the consumer completes it or `LockDuration` runs out (then it reappears). The Service Bus equivalent of RabbitMQ's "unacked" state, but timer-based instead of connection-based.

**Complete / abandon / dead-letter** — the consumer's three verdicts: complete = done, delete it; abandon = release the lock now so it's redelivered; dead-letter = move it to the DLQ with a reason.

**Delivery count / `MaxDeliveryCount`** — how many times a message has been handed out. Each lost lock or abandon increments it; reaching `MaxDeliveryCount` dead-letters the message automatically. Here it's the crash safety net, not the retry mechanism.

**Dead-letter subqueue** — every queue has a built-in `$DeadLetterQueue`. Messages there carry a `DeadLetterReason` and `DeadLetterErrorDescription`. Replaces Phase 4's hand-built DLX + DLQ.

**Scheduled message** — a message sent with a future enqueue time; it sits invisible to receivers until then. This project's retry delay: schedule a copy 30s ahead instead of RabbitMQ's TTL holding-pen queue.

**Duplicate detection** — the queue remembers every `MessageId` it saw within a time window and silently drops repeats (the sender still gets success). Makes "send at least once" (the outbox) behave like "enqueue exactly once" within the window.

**Application properties** — custom key/value headers on a message (here `retry-count`), the equivalent of RabbitMQ message headers.

**`ServiceBusProcessor`** — the SDK's push-style consumer: it receives, renews locks, runs your handler with bounded concurrency, and reconnects on errors. You only write the per-message handler.

## RabbitMQ (Phase 4, no longer in the code)

**Message broker** — a system for transporting messages between processes (unlike a database, which stores queryable data). RabbitMQ delivers a message once and it's gone — there's no "GET a key" equivalent.

**Connection** — the actual TCP connection between the app and the RabbitMQ server. Expensive to set up, meant to be a long-lived singleton (`IConnection`).

**Channel** — a lightweight logical pipe multiplexed over a single connection. Cheap to open and close; many channels can share one connection. Used per-publish / per-consume, not shared across concurrent operations. Called "model" (`IModel`) in RabbitMQ.Client v6 and earlier — same concept, renamed in v7 (`IChannel`).

**Exchange** — the routing layer producers publish to. A producer never publishes directly to a queue; it publishes to an exchange with a routing key, and the exchange (via its bindings) decides which queue(s) actually receive the message. This decouples "who sends this" from "who receives this."

**Queue** — a durable, ordered buffer holding messages until a consumer takes them. Multiple consumers can read from one queue (RabbitMQ round-robins between them) for horizontal scaling.

**Binding** — the rule connecting an exchange to a queue: "messages with routing key X, arriving at this exchange, go into this queue."

**Routing key** — a string label attached to a published message, used by the exchange to decide where it goes. This project uses `direct` exchanges (exact routing-key match) since there's only one event type (`created`).

**Ack / nack** — how a consumer tells RabbitMQ whether it finished processing a message. `ack` = done, delete it. `nack` = failed; `requeue: false` here, so the queue's dead-letter-exchange argument takes over instead of an immediate retry.

**At-least-once delivery** — the guarantee RabbitMQ gives: a message will be delivered and processed at least once, but might be delivered more than once (e.g. the consumer finishes work but crashes before acking). This is why the worker's status-transition logic needs to be idempotent — safe to re-apply without corrupting state.

**DLX (Dead Letter Exchange)** — an ordinary exchange that RabbitMQ automatically routes a message to when that message is rejected (`nack`) or expires (TTL) from its original queue, because that queue named it via the `x-dead-letter-exchange` argument. Not a special exchange type — just a plain exchange used this way.

**DLQ (Dead Letter Queue)** — the queue bound to a DLX, where rejected/expired messages actually land. Nothing consumes it automatically — it's a terminal parking spot for a human (or an alert) to look at.

**TTL on a queue (`x-message-ttl`)** — combined with a DLX, this is how RabbitMQ does delayed retries without a special "delay" feature: a failed message sits in a holding-pen queue with no consumer until its TTL expires, then gets auto-dead-lettered back to the real queue.

**`x-death` header** — a header RabbitMQ automatically stamps on a message every time it gets dead-lettered, including a count of how many times it's bounced through a given (queue, reason) pair. Used to detect "this has failed too many times" instead of maintaining a custom counter.

**Unbounded queue** — RabbitMQ queues have no built-in message-count cap by default; they grow until the broker runs out of disk (durable messages) or RAM (transient messages), at which point publishers get blocked entirely. `x-max-length` can cap a queue explicitly; the production answer is usually monitoring queue depth and alerting rather than capping blindly.
