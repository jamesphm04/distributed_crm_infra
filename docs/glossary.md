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

## Redis

**Redis** — an in-memory data store, running as its own separate server/container. Clients connect to it over the network, the same way they connect to a database — it is not embedded in the application process.

**`IConnectionMultiplexer`** (StackExchange.Redis) — the central connection object to Redis. Meant to be a long-lived singleton, reused across the whole app, because it's thread-safe and the underlying connection is expensive to set up.

**`SET NX`** — Redis's "set if not exists" command. Used here as the atomic primitive behind the idempotency claim: the first caller to `SET NX` a given key wins the claim; everyone else's `SET NX` fails, telling them someone else got there first.

## RabbitMQ

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
