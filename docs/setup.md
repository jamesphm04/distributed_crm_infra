# Setup

## What lives where

```
distributed_crm/                   <- plain folder, NOT a git repo itself
├── CLAUDE.md                      <- project conventions (not tracked in git anywhere)
├── docker-compose.yml             <- local Postgres/Redis/RabbitMQ (not tracked in git anywhere)
├── docs/                          <- this folder (not tracked in git anywhere)
├── distributed_crm_be/            <- git repo, origin: github.com/jamesphm04/distributed_crm_be
├── distributed_crm_worker/        <- git repo, origin: github.com/jamesphm04/distributed_crm_etl (name mismatch, see note below)
└── distributed_crm_fe/            <- git repo, origin: github.com/jamesphm04/distributed_crm_fe
```

**Important gap:** `CLAUDE.md`, `docker-compose.yml`, and this `docs/` folder are currently only on this machine's disk.
Cloning the three repos on a new device will NOT bring them over.
Copy them manually (AirDrop, USB, a private gist, whatever) or paste their contents back in via Claude on the new device.

**Note:** `distributed_crm_worker`'s remote is still named `distributed_crm_etl` on GitHub — a leftover from before the repo was renamed locally.
Doesn't block anything, but worth renaming the GitHub repo itself at some point for consistency.

## Prerequisites on the new device

- .NET 10 SDK
- `dotnet-ef` global tool: `dotnet tool install --global dotnet-ef`
- Docker Desktop (or another Docker runtime) running
- Node.js (for `distributed_crm_fe` — check `package.json` engines field for exact version)

## Getting it running

1. Clone all three repos into a shared parent folder (matching the layout above):
   ```bash
   mkdir distributed_crm && cd distributed_crm
   git clone https://github.com/jamesphm04/distributed_crm_be.git
   git clone https://github.com/jamesphm04/distributed_crm_etl.git distributed_crm_worker
   git clone https://github.com/jamesphm04/distributed_crm_fe.git
   ```
2. Copy `CLAUDE.md`, `docker-compose.yml`, and this `docs/` folder into that same parent folder.
3. Start the backing services (Postgres, Redis, RabbitMQ):
   ```bash
   docker compose up -d
   ```
   Port mappings (host → container), chosen to avoid collisions with other local projects:
   - Postgres: `5436` → `5432`
   - Redis: `6380` → `6379`
   - RabbitMQ: `5672` → `5672` (AMQP), `15672` → `15672` (management UI, `http://localhost:15672`, default `guest`/`guest`)

   Adjust the compose file and the connection strings below if these ports are no longer free on the new machine.
4. Restore/build the backend:
   ```bash
   cd distributed_crm_be
   dotnet build
   ```
5. Confirm `src/DistributedCrm.Api/appsettings.Development.json` has both connection strings:
   ```json
   "ConnectionStrings": {
     "DistributedCrm": "Host=localhost;Port=5436;Database=distributed_crm;Username=postgres;Password=devpassword",
     "Redis": "localhost:6380"
   }
   ```
6. Apply migrations (creates the schema in the fresh database):
   ```bash
   dotnet ef database update \
     --project src/DistributedCrm.Infrastructure \
     --startup-project src/DistributedCrm.Api
   ```
7. Run the API:
   ```bash
   ASPNETCORE_URLS=http://localhost:5214 ASPNETCORE_ENVIRONMENT=Development \
     dotnet run --project src/DistributedCrm.Api --no-launch-profile
   ```
   Sanity check — create a return request:
   ```bash
   curl -s -X POST http://localhost:5214/api/return-requests \
     -H "Content-Type: application/json" \
     -H "Idempotency-Key: setup-check-1" \
     -d '{"orderReference":"ORD-1","customerEmail":"a@b.com","item":"Widget","reason":"Wrong item"}'
   ```
8. To run a second instance (for testing statelessness/idempotency across instances — see `decisions.md`):
   ```bash
   ASPNETCORE_URLS=http://localhost:5215 ASPNETCORE_ENVIRONMENT=Development \
     dotnet run --project src/DistributedCrm.Api --no-launch-profile
   ```

## Common gotchas

- `--no-launch-profile` skips `launchSettings.json` entirely, including its `ASPNETCORE_ENVIRONMENT=Development` default — always set that env var explicitly alongside it, or `appsettings.Development.json` (and its connection strings) silently won't load.
- zsh treats an unquoted `&` in a URL as a job-control operator — always quote curl URLs that have query strings, e.g. `curl -s "http://localhost:5214/api/return-requests?page=1&pageSize=10"`.
- `curl -s` hides HTTP status codes. Use `curl -i` or `-v` when a response looks empty/unexpected — a malformed GUID against a `{id:guid}` route, for example, fails the route match and returns a silent `404` with an empty body.
