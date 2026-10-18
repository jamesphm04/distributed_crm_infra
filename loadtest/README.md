# Load tests

k6 scripts that run against the deployed system in Azure.
What each run found is in `../docs/loadtest-results.md`.

## Run

Install k6 (`brew install k6`), then from the repo root:

```bash
export BASE_URL="https://$(az containerapp show -n ca-dcrm-be-dev -g rg-dcrm-dev --query properties.configuration.ingress.fqdn -o tsv)"
export TOKEN="<Google ID token from the OAuth Playground>"

mkdir -p loadtest/results
K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT=loadtest/results/stress.html \
  PROFILE=stress k6 run --summary-export loadtest/results/stress.json loadtest/return-requests.js
```

While it runs, the web dashboard is at http://localhost:5665.
The HTML report and the JSON summary land in `loadtest/results/`, which git ignores.

The token lasts an hour.
The script refuses to start if it would expire before the run finishes.

## Profiles

| Profile | Lookups/s | Journeys/min | Length | Purpose |
|---|---|---|---|---|
| `smoke` | 2 | 30 | 1 min | The script and the system work; fills the lookup pool |
| `stress` | 10 → 25 → 50 → 100 → 200 | 30 → 60 → 120 | 11 min | Where it breaks |
| `stress-high` | 200 → 300 → 400 | 30 | 6 min | Only if 200/s still passes |
| `spike` | 10 → `SPIKE_RATE` → 10 | 30 | 4 min | A sudden jump, and the recovery |
| `steady` | `STEADY_RATE` (50) | 30 | 11 min | Steady load while a dependency is broken on purpose |
| `soak` | `SOAK_RATE` (50) | 30 | 31 min | Drift over time |

Each step ramps for its first part and holds for the rest.
Requests carry `level` and `phase` tags, and every step has its own thresholds, so the report shows which levels passed.

## The two kinds of user

- **Lookups** read a random return request from a pool of 200.
  This is the live-call read path; search replaces it in Phase 14.
  `setup()` reuses existing rows and only creates the shortfall.
- **Journeys** create a return request with a new `Idempotency-Key`, then poll its status every 2 seconds, up to 8 times.
  `time_to_decision` and `decided_in_window` measure how far the worker lags behind.

Created rows have the reason `k6 load test`.

## Breaking Redis on purpose

Turning off Redis public network access blocks new connections but not the apps' open ones, so the outage run also restarts both apps:

```bash
az redisenterprise update -g rg-dcrm-dev -n <redis-name> --public-network-access Disabled
az containerapp revision restart -n ca-dcrm-be-dev -g rg-dcrm-dev --revision <active-revision>
az containerapp revision restart -n ca-dcrm-worker-dev -g rg-dcrm-dev --revision <active-revision>
# ... later
az redisenterprise update -g rg-dcrm-dev -n <redis-name> --public-network-access Enabled
```

Add `--out csv=loadtest/results/<name>.csv.gz` to the k6 command to get every request with its timestamp, then `python3 loadtest/timeline.py loadtest/results/<name>.csv.gz` prints a timeline.
Run the same restart with Redis healthy as a control, so the restart's own effect can be told apart.

## Before a run

- Run `smoke` first.
- Open App Insights → Live metrics.
- Check today's telemetry ingestion against the Log Analytics daily cap.
