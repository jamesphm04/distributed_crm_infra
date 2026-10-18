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
- **Came up again:** Phase 9 phase quiz (Q2), after the live deploy: still "unsupported" with the identities existing.
- **Short answer:** every unsupported item is a role or access assignment for an app identity, whose principal ID only exists once the identity is created during the real deploy. The Postgres resources use no app identity, and its Entra admin uses `deployer()`, which is James, who already exists, so what-if can show all four.
- **Added after the live deploy:** what-if never looks up live values; it only evaluates the template. A role assignment's name is `guid(scope, principalId, role)`, and `principalId` comes from `reference()` on the identity, which is only evaluated during a real deploy. So they stay unsupported on every run, and are verified instead with `az role assignment list --assignee <principalId>`.

### Finding a failed request with telemetry

- **Came up:** Phase 8, phase quiz (Q3). Didn't know where to start; expected the trace to hold the request payload.
- **Missed:** how to get from "this request is stuck" to its trace, and that bodies aren't recorded.
- **Short answer:** spans and logs carry IDs, not payloads (bodies can hold personal data and are large). Search the request's ID in **Structured logs**, open the row's trace link, and read the red spans: the exception on each `approval-api RequestDecision` span and the final `dead-lettering` log say why it stopped.

### Why a slow failure is worse than a fast one

- **Came up:** Phase 10, Step 10.1 quiz (Q3). Didn't see what `BacklogPolicy.FailFast` changes when the catches already return 200.
- **Missed:** latency is a failure mode of its own, and under load a slow dependency spreads.
- **Short answer:** without fail-fast, each request waits 5 s for Redis before the catch runs. At 100 requests a second that is 500 requests in flight, each holding a thread and a Postgres connection, so the thread pool and the connection pool run out and even endpoints that never touch Redis start timing out. Fail-fast makes the degraded path as fast as the normal one.

## Partly understood (worth a quick re-check)

- **Immutable OIDC subjects** (Phase 10, phase quiz Q2): said GitHub sent the name and Azure compared the ID; it was the reverse: GitHub sent names with numeric IDs (`jamesphm04@153576708/distributed_crm_be@1369763321`), Azure compared against the names-only subject we had registered. IDs are safer because names can be reused: a re-created repo or a taken-over username gets a different ID and can't match.
- **How an app signs in to Postgres with a token** (Phase 10, phase quiz Q3): said "we use Entra ID"; the chain is Npgsql's password provider → `DefaultAzureCredential` → Container Apps' identity endpoint returns an Entra token for `id-dcrm-be-dev` → sent as the password with `Username=id-dcrm-be-dev` → Postgres validates it with Entra and maps it to the role the migration job created (`pgaadauth_create_principal`), which has row access only.
- **What GitHub's OIDC token is** (Phase 10, Step 4b Q2): answered "notes" and asked for the explanation; it is a signed JWT (issuer `token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`, subject `repo:<owner>/<repo>:environment:dev`), and Entra ID validates it exactly as the API validates a Google ID token in Phase 6, with the federated credentials playing the role of `AllowedEmails`.
- **Why the pipeline's IDs aren't secrets** (Phase 10, Step 4b Q3): answered "not" without the reason; the client, tenant and subscription IDs only name what to sign in as, and signing in still needs a GitHub-signed token whose subject matches, which only a job in that repo's `dev` environment can get. The risk moves to who can push to the repo and run its workflows.
- **Token expiry** (Phase 10, Step 10.2 Q1): named the Entra token; missed what happens when it expires: nothing breaks, because the app asks the credential for a new one before each new connection (refreshed every 5 minutes), and connections already open stay signed in.
- **Why local Redis got a password** (Phase 10, Step 10.2 Q2): said there's no token locally; the missing link is that the app chooses by the value's shape, so a Redis value without a password sends it down the token path, which fails on a laptop (demo 3). The password keeps local on the password path.
- **Narrowing the credential chain** (Phase 10, Step 10.2 Q3): said it retries; missed the consequences (a misconfigured revision takes about 2 minutes to fail, and a full chain could sign in with an unexpected credential, such as stray `AZURE_CLIENT_SECRET` variables) and the fix (`AZURE_TOKEN_CREDENTIALS=ManagedIdentityCredential` plus `AZURE_CLIENT_ID`).
- **Fail open vs fail closed** (Phase 10, Step 10.1 Q1): named what happens (read from the database, a duplicate must fail) but not the rule behind it: the cache is an optimisation, so skipping it costs only speed; idempotency is a guarantee, so skipping it costs correctness (a duplicate return request).

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
- **Why a failed deploy can just be re-run** (Phase 9, phase quiz Q1): said the resources are "isolated from each other"; missed that ARM is declarative and idempotent: a failed deployment doesn't roll back, and the next run compares each resource with the template, leaves matching ones alone and creates only what's missing.
- **Control plane vs data plane** (Phase 9, phase quiz Q3): answered that only the apps may read secrets; missed that Owner is a control-plane role (manage the vault itself) and reading a secret is a data-plane action that needs its own role, which is why the Bicep gives `deployer()` Key Vault Secrets Officer.
- **What polling measures** (Phase 15, Step 2 Q2): answered "yes" without the reason: the script only looks every 2 s, so `time_to_decision` is "decided by the time we checked", accurate to about ±2 s, never to the millisecond.
- **Proving a backlog, not guessing it** (Phase 15, Step 2 Q3): named "worker backlog"; the evidence is Service Bus active messages climbing and the worker's processed-per-minute staying flat (about 65) however hard the API is pushed.
- **Thresholds vs checks, tags** (Phase 15, Step 3 quiz): not answered; James asked the agent to run the rest of Phase 15. A check records one response; a threshold judges the whole run and sets the exit code (99); a `name` tag groups URLs that differ only by ID into one metric.
- **Case-sensitive patterns** (Phase 8, Steps 6–8 Q3): needed the explanation that Docker matches `.dockerignore` case-sensitively while macOS filenames are not.

## Resolved

None yet.
