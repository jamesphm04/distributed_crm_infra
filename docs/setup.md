# Setup

## What lives where

```
distributed_crm/                   <- plain folder, NOT a git repo itself
├── CLAUDE.md                      <- project conventions (not tracked in git anywhere)
├── distributed_crm_infra/         <- git repo, origin: github.com/jamesphm04/distributed_crm_infra (docker-compose.yml, docs/)
├── distributed_crm_be/            <- git repo, origin: github.com/jamesphm04/distributed_crm_be
├── distributed_crm_worker/        <- git repo, origin: github.com/jamesphm04/distributed_crm_worker
└── distributed_crm_fe/            <- git repo, origin: github.com/jamesphm04/distributed_crm_fe
```

**Gap:** `CLAUDE.md` is only on this machine's disk.
Cloning the repos on a new device will NOT bring it over — copy it manually into the `distributed_crm/` folder.

## Prerequisites on the new device

- .NET 10 SDK
- `dotnet-ef`: pinned per repo, `dotnet tool restore` in `distributed_crm_be`
- Docker Desktop (or another Docker runtime) running
- Node.js (for `distributed_crm_fe` — check `package.json` engines field for exact version)
- `python3` (only for decoding tokens locally)

## Google sign-in values

The API only accepts Google ID tokens from allowlisted emails, so you need two values before anything starts:

- **Client ID** of the Google Cloud OAuth 2.0 client (type "Web application"). Find it under Google Auth Platform → Clients.
  The client secret is only needed for the OAuth Playground (below); keep the downloaded client JSON outside every repo.
- **Allowed email** — your Google account's email.

Both repos involved are public, so these values never go into git.

## Getting it running (Compose — the normal way)

1. Clone all four repos into a shared parent folder (matching the layout above):
   ```bash
   mkdir distributed_crm && cd distributed_crm
   git clone https://github.com/jamesphm04/distributed_crm_infra.git
   git clone https://github.com/jamesphm04/distributed_crm_be.git
   git clone https://github.com/jamesphm04/distributed_crm_worker.git
   git clone https://github.com/jamesphm04/distributed_crm_fe.git
   ```
2. Create `distributed_crm_infra/.env` from the template and fill in both values (`.env` is gitignored):
   ```bash
   cd distributed_crm_infra
   cp .env.example .env
   ```
   `docker compose up` refuses to start if either value is missing.
3. Start everything:
   ```bash
   docker compose up -d --build
   ```
   Port mappings (host → container), all bound to `127.0.0.1` only:
   - API (`be`): `5214` → `8080`
   - Worker health endpoints: `5216` → `8080` (`/health/live`, `/health/ready`; the worker serves nothing else)
   - Postgres: `5436` → `5432`
   - Redis: `6380` → `6379`
   - Service Bus emulator: `5672` → `5672` (AMQP), `5300` → `5300` (health: `curl http://localhost:5300/health`). Takes ~30s to become healthy; the apps retry until it is. Its SQL Edge storage container publishes no ports.
   - Aspire dashboard (traces, metrics, logs): UI at http://localhost:18888, OTLP gRPC on `4317` → `18889`. No login locally. It keeps everything in memory, so restarting it clears all telemetry.
   Migrations run automatically: the one-shot `migrate` service applies the idempotent SQL script from the `be` image before `be` and `worker` start, and then shows as `Exited (0)` in `docker compose ps -a`.
   Check what's applied with `docker compose exec postgres psql -U postgres -d distributed_crm -c 'select migration_id from "__EFMigrationsHistory"'`.
4. Check both apps are up: `curl -i http://localhost:5214/health/ready` (API) and `curl -i http://localhost:5216/health/ready` (worker) → `200 Healthy` (Postgres, Redis and Service Bus all reachable). `/health/live` only says the process is running.
5. Get an ID token and make a request — see "Getting a Google ID token" below.
6. Open http://localhost:18888 → **Traces**. A `POST /api/return-requests` shows up as one trace across `be` and the worker, including the worker's retries, within about 15 s.

## Running the API with `dotnet run` instead

Useful for debugging, or for running a second instance to test statelessness/idempotency (see `decisions.md`).

1. Start only the backing services and the migration job: `docker compose up -d postgres migrate redis servicebus` (from `distributed_crm_infra`).
2. Put the Google values in user secrets (stored in `~/.microsoft/usersecrets/`, outside the repo):
   ```bash
   cd distributed_crm_be
   dotnet user-secrets set "GoogleAuth:ClientId" "<client-id>" --project src/DistributedCrm.Api
   dotnet user-secrets set "GoogleAuth:AllowedEmails:0" "<your-email>" --project src/DistributedCrm.Api
   ```
3. Run it (stop the `be` container first if you want port `5214`):
   ```bash
   ASPNETCORE_URLS=http://localhost:5214 ASPNETCORE_ENVIRONMENT=Development \
     dotnet run --project src/DistributedCrm.Api --no-launch-profile
   ```
   A second instance: same command with port `5215`.

The worker runs the same way; its launch profile listens on `http://localhost:5216` (stop the `worker` container first):
```bash
cd distributed_crm_worker
dotnet run --project src/DistributedCrm.Worker
```

## Azure environment (Phase 9)

Needs the Azure CLI signed in (`az login`) with Owner on the `distributed-crm-sandbox` subscription, and the Bicep compiler (`az bicep install`).
From `distributed_crm_infra`:
```bash
infra/deploy.sh plan   # what-if: shows what would change, creates nothing
infra/deploy.sh up     # creates or updates everything (bills by the hour from here)
infra/deploy.sh down   # deletes everything the stack created and purges the Key Vault
```
Run `down` at the end of every session; see `costs.md` for what each resource costs.
Every command pins the subscription, so the CLI's current subscription doesn't matter.
`up` first registers any resource provider the templates need that the subscription hasn't enabled yet (a one-time step per subscription, a few minutes each).
It then creates or updates the `dcrm-cicd` stack (the GitHub Actions identity, kept across teardowns), the `dcrm-dev` stack, and copies `GOOGLE_CLIENT_ID` and `ALLOWED_EMAIL` from `.env` into Key Vault.

### Deploying the apps (Phase 10)

One-time GitHub setup, in both `distributed_crm_be` and `distributed_crm_worker`:

1. **Settings → Environments → New environment** named `dev`. The workflows sign in from it, and Azure trusts only that environment.
2. Three repository secrets with the values `infra/deploy.sh cicd` prints (IDs, not credentials; sign-in is OIDC):
   ```bash
   gh secret set AZURE_CLIENT_ID --repo jamesphm04/<repo> --body "<value>"
   gh secret set AZURE_TENANT_ID --repo jamesphm04/<repo> --body "<value>"
   gh secret set AZURE_SUBSCRIPTION_ID --repo jamesphm04/<repo> --body "<value>"
   ```

Each session, after `up`: **Actions → Deploy → Run workflow** in `distributed_crm_be` first (it runs the migrations), then in `distributed_crm_worker`.
`down` deletes the Container Apps too, because they live in `rg-dcrm-dev`.

## Creating a migration

The EF tool version is pinned per repo in `distributed_crm_be/dotnet-tools.json`; run `dotnet tool restore` once after cloning.
```bash
cd distributed_crm_be
dotnet ef migrations add <Name> \
  --project src/DistributedCrm.Infrastructure \
  --startup-project src/DistributedCrm.Api
```
Then `docker compose up -d --build migrate` (from `distributed_crm_infra`) regenerates the script and applies it.
To read the generated SQL: `docker build --target migrate -t distributed-crm-migrate ../distributed_crm_be && docker run --rm --entrypoint cat distributed-crm-migrate /migrations/migrate.sql`.

## Getting a Google ID token

Until the frontend exists (Phase 11), tokens come from the OAuth Playground. They expire after about an hour.

1. Open https://developers.google.com/oauthplayground.
2. Gear icon → tick **Use your own OAuth credentials** → paste the client ID and secret.
3. Step 1: type `openid email` into "Input your own scopes" → **Authorize APIs** → sign in.
4. Step 2: **Exchange authorization code for tokens** → copy `id_token` (not `access_token`).

Keep it in a shell variable, and decode it locally rather than pasting it into a website:
```bash
export ID_TOKEN='eyJ...'
python3 -c 'import sys,base64,json;p=sys.argv[1].split(".")[1];print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))),indent=2))' "$ID_TOKEN"
```

Sanity check — create a return request:
```bash
curl -i -X POST http://localhost:5214/api/return-requests \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{"orderReference":"ORD-1","customerEmail":"a@b.com","item":"Widget","reason":"Wrong item"}'
```

## Common gotchas

- The emulator has no web UI. Queue settings live in `servicebus/Config.json` and are only read at emulator startup (`docker compose up -d --force-recreate servicebus` after editing). The emulator rejects values above its limits (e.g. a duplicate-detection window over 5 minutes) and refuses to start — check `docker compose logs servicebus`.
- `401` with `WWW-Authenticate: Bearer` and no `error=` → no token was sent. With `error="invalid_token"` → the token was rejected; `docker compose logs be` shows the `IDX...` reason (expired, wrong audience, bad signature).
- `403` → the token is valid but the email isn't on the allowlist (or isn't verified); the `be` log has a `Denied:` line saying which.
- `--no-launch-profile` skips `launchSettings.json` entirely, including its `ASPNETCORE_ENVIRONMENT=Development` default — always set that env var explicitly alongside it, or `appsettings.Development.json` (connection strings) and user secrets silently won't load.
- zsh treats an unquoted `&` in a URL as a job-control operator — always quote curl URLs that have query strings, e.g. `curl -s "http://localhost:5214/api/return-requests?page=1&pageSize=10"`.
- `curl -s` hides HTTP status codes. Use `curl -i` or `-v` when a response looks empty/unexpected — a malformed GUID against a `{id:guid}` route, for example, fails the route match and returns a silent `404` with an empty body.
- The `migrate` log is all `DO` lines whether it applied anything or not — each migration sits inside a `DO $EF$ … END $EF$` block, and `psql` only reports top-level statements. Query `__EFMigrationsHistory` to know what's applied.
- An app container exits with code `134` right after starting → read `docker compose logs be` (or `worker`). A missing connection string is named in the error, e.g. `Set the ConnectionStrings__Redis environment variable.` `134` means the process aborted; `tini` passes the code through.
- The Compose project is pinned as `distributed_crm` (`name:` in `docker-compose.yml`). Images built before that are named `distributed_crm_infra-*` and are no longer used: `docker image rm distributed_crm_infra-be distributed_crm_infra-worker distributed_crm_infra-migrate`. If you ever change `name:` again, run `docker compose down` first, or the old containers become orphans that block the fixed `container_name`s.
- `.dockerignore` patterns are case-sensitive even though macOS file names aren't: `.DS_store` does not match `.DS_Store`.
- `be` or `worker` not starting after a schema change → `docker compose logs migrate`. With `ON_ERROR_STOP=1` a failing migration exits non-zero, and Compose refuses to start the apps.
- An app started with `dotnet run` sends telemetry to `localhost:4317` by default, which is the dashboard's published OTLP port, so it shows up next to the containers with no extra config. Set `Telemetry__ConsoleExporter=true` to also print spans and metrics to the console.
- Redis spans appear in a trace about 10 s after the rest; refresh before deciding they are missing.
- Pasting YAML into nvim with auto-indent can nest a key under the list above it (`ports.[2] is missing a target port`). Use `:set paste` before pasting, or paste with `"+p`.
