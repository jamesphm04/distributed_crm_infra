# Learning gaps

Topics James found hard in step and phase quizzes, kept so they can be revisited later.
Each entry says where it came up, what was missed, and the short correct answer.
When a later quiz answers it correctly, move it to **Resolved** with the date.

## Open

### Ownership and disposal of long-lived clients

- **Came up:** Phase 8, quiz on Steps 1–5.
- **Missed:** who creates, owns and disposes a shared client (`ServiceBusSender`, `ConnectionMultiplexer`), and why a singleton owns it for the app's lifetime.
- **Short answer:** whoever creates an `IDisposable`/`IAsyncDisposable` disposes it; DI disposes what it created; one client per app lifetime, never one per request.

### Check where the result is recorded, not the log

- **Came up:** Phase 8, quiz on Steps 1–5.
- **Missed:** verifying an outcome from a log line instead of from the source of truth.
- **Short answer:** a log says what the code *thought* happened; the database row, `__EFMigrationsHistory`, or the queue is what actually happened. Check there.

### Compose project name and container ownership

- **Came up:** Phase 8, quiz on Steps 6–8 (Q4).
- **Missed:** why `docker compose down` must run before renaming the project.
- **Short answer:** Compose finds "its" containers by the project label, not by name. After a rename, `down` finds nothing and leaves the old containers running; with fixed `container_name`s, the next `up` fails with a container name conflict.

### PID 1, signals and tini

- **Came up:** Phase 8, quiz on Steps 6–8 (Q6).
- **Missed:** why a crashing .NET app hung at 100% CPU as PID 1, and what tini changes.
- **Short answer:** the kernel ignores a signal that PID 1 sends itself unless it installed a handler, so `abort()`'s SIGABRT never kills it. tini is PID 1 and runs the app as a child, so the crash kills the app, tini exits with its code (134 = 128 + SIGABRT 6), and the platform restarts the container.

### Root spans and parent spans

- **Came up:** Phase 8, Step 9 (telemetry primer, Q2). Needed three re-explanations.
- **Missed:** why the outbox poll's SQL became a separate one-span trace every second.
- **Short answer:** a span joins whatever span is current (`Activity.Current`). Background work with no current span makes each of its spans a new root, so a new trace. Filtering on `Activity.Current is not null` keeps only SQL that is part of a bigger operation.

### Context propagation across an async boundary

- **Came up:** Phase 8, Step 9 (telemetry primer, Q3). Answered that the worker would share the API request's trace automatically.
- **Missed:** a trace only continues across a hop if something carries the trace context.
- **Short answer:** HTTP headers and Service Bus message properties carry `traceparent` automatically; a database row (the outbox) does not unless it has a column for it. Step 11 adds `outbox_messages.trace_parent` for exactly this.

### Why what-if marks some resources "unsupported"

- **Came up:** Phase 9, Step 6 quiz (Q1), and again in the Step 8 quiz (Q1). Didn't know why the count stayed the same after adding resources that reference no app identity.
- **Missed:** "unsupported" means what-if can't calculate a resource's ID before the deploy runs.
- **Short answer:** every unsupported item is a role or access assignment for an app identity, whose principal ID only exists once the identity is created during the real deploy. The Postgres resources use no app identity, and its Entra admin uses `deployer()`, which is James, who already exists, so what-if can show all four.

### Finding a failed request with telemetry

- **Came up:** Phase 8, phase quiz (Q3). Didn't know where to start; expected the trace to hold the request payload.
- **Missed:** how to get from "this request is stuck" to its trace, and that bodies aren't recorded.
- **Short answer:** spans and logs carry IDs, not payloads (bodies can hold personal data and are large). Search the request's ID in **Structured logs**, open the row's trace link, and read the red spans: the exception on each `approval-api RequestDecision` span and the final `dead-lettering` log say why it stopped.

## Partly understood (worth a quick re-check)

- **Why `.dockerignore` matters** (Phase 8, Steps 6–8 Q1): named cache invalidation, missed host paths in `obj/project.assets.json` and secrets (`.env`) ending up in an image layer.
- **Fail fast at startup** (Phase 8, Steps 6–8 Q5): named "know immediately", missed that a crashing new revision never takes traffic while start-then-fail breaks live users.
- **Cache-aside in a trace** (Phase 8, Step 9 Q1): said the trace "doesn't involve SQL"; the reason is that a Redis hit returns before Postgres is ever called.
- **Privileged ports and non-root containers** (Phase 8, Steps 6–8 Q2): needed the explanation that ports below 1024 need root, so .NET images listen on 8080.
- **Migrations as a separate job** (Phase 8, phase quiz Q2): named the race between replicas; missed that the old version keeps serving while the new one starts (so the schema must work for both), that a failed migration should stop the pipeline before deploy instead of crash-looping replicas, and that the app then never needs permission to change the schema.
- **Daily ingestion cap trade-off** (Phase 9, Step 2 Q2): named "0.5 GB a day limit"; missed that it bounds the bill (at most 0.5 GB/day can be charged) and that everything above it is dropped until the daily reset, so you lose visibility exactly when something is going wrong.
- **Implicit dependencies in Bicep** (Phase 9, Step 2 Q3): answered "it depends"; the mechanism is that referencing another resource's property (`logAnalytics.id`) makes Bicep generate the `dependsOn` itself, so the referenced resource is created first.
- **Deterministic role assignment names** (Phase 9, Step 3 Q2): said a random GUID "is not idempotent"; missed the concrete failure: the second deploy tries to add the same principal + role + scope under a new name and Azure rejects it with `RoleAssignmentExists`.
- **How a managed identity signs in** (Phase 9, Step 3 Q3): said "use its principal ID"; the flow is that the app is attached to its identity (by resource ID), asks Entra ID for a short-lived token as that identity, and the registry checks the token against the AcrPull assignment. No password is stored anywhere.
- **Secret values never go in Bicep** (Phase 9, Step 4 Q3): not answered; a value written in a template lands in the public repo and in Azure's deployment history, which anyone with read access to the resource group can open. Values are set separately (`az keyvault secret set`, later the pipeline).
- **Case-sensitive patterns** (Phase 8, Steps 6–8 Q3): needed the explanation that Docker matches `.dockerignore` case-sensitively while macOS filenames are not.

## Resolved

None yet.
