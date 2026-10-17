# Azure costs

What each Azure resource costs, as estimated before deploying and as actually charged afterwards.
Everything runs in the `distributed-crm-sandbox` subscription (budget AUD 100/month, email alert at 80%).
A budget only sends an email; it never stops anything, so tearing down after each session is the real cost control.

## How the estimates were made

- Prices are Azure **retail list prices** for **Australia East**, in **AUD**, from the public price list API (`https://prices.azure.com/api/retail/prices`), read on 2026-10-16.
- Container Apps prices are per second, which the AUD list rounds to zero, so they were read in USD and converted at the list's own rate (USD 1 = AUD 1.4246).
- "24/7" assumes 730 hours a month. "Session" assumes about 80 hours a month (4 hours on 20 days), with everything deleted in between.
- Actual charges come from Cost Management (subscription → Cost analysis, grouped by resource). They show up 8–24 hours after use, so check the day after a session.

## Phase 9: the foundation (nothing running yet)

| Resource | Tier | Fixed charge | Usage charges | 24/7 estimate | Session estimate | Actual |
|---|---|---|---|---|---|---|
| Container Registry | Basic | AUD 0.2373/day | storage AUD 0.1425/GB-month (about 1 GB of images) | ~AUD 7.40 | ~AUD 4.90 (charged per day used) | — |
| PostgreSQL Flexible Server | Burstable B1ms, 32 GiB storage | compute AUD 0.037/hour; storage AUD 0.1966/GB-month | backup storage free up to the provisioned size, then AUD 0.1353/GB-month | ~AUD 33.30 (27.00 compute + 6.30 storage) | ~AUD 3.70 | — |
| Service Bus | Standard | AUD 0.0191/hour (AUD 14.25/month) | first 13M operations/month included; then AUD 1.1397 per million | ~AUD 14.25 | ~AUD 1.55 | — |
| Azure Managed Redis | Balanced B0 | AUD 0.0285/hour per instance; high availability is off, because it would run a second instance | none | ~AUD 20.80 | ~AUD 2.30 | — |
| Key Vault | Standard | none | AUD 0.0427 per 10,000 operations (apps read secrets at startup only) | < AUD 0.10 | < AUD 0.10 | — |
| Log Analytics + Application Insights | pay-as-you-go | none | first 5 GB ingested/month free, then AUD 4.7582/GB; 31 days retention included | AUD 0 if under 5 GB | AUD 0 | — |
| Container Apps environment | Consumption only | none while no dedicated workload profile is added | apps billed separately (Phase 10) | AUD 0 | AUD 0 | — |
| Managed identities, role assignments, resource group | — | free | free | AUD 0 | AUD 0 | — |
| **Total** | | | | **~AUD 76** | **~AUD 12.50** | — |

The fixed hourly charges are what matter: Postgres, Redis and Service Bus bill every hour they exist, whether or not anything uses them.
Left running for a month they use about three quarters of the budget before a single app runs.

## Phase 10 onwards: the apps (estimate, refined when deployed)

Container Apps on the Consumption plan bills each replica per second, at a lower rate while it is idle.
Prices: vCPU USD 0.000034/s active and USD 0.000004/s idle; memory USD 0.000004/GiB-s either way; requests AUD 0.5698 per million.
Each subscription gets 180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests free every month.

Planned: API 2 replicas and worker 1 replica, each 0.25 vCPU and 0.5 GiB, always on.

| Case | 24/7 estimate | Session estimate |
|---|---|---|
| All three replicas count as idle | ~AUD 30/month | ~AUD 0.60 (mostly inside the free grant) |
| All three replicas count as active | ~AUD 105/month | ~AUD 2.20 |

Which one applies is an open question for Phase 10: a replica is billed as idle only while it uses almost no CPU and under 1,000 bytes/s of network, and the API's outbox relay queries Postgres every second.

Phase 10b (private network) adds: private endpoints for Redis, Key Vault and the registry (about AUD 11/month each, billed hourly), private DNS zones (under AUD 1/month each), and the registry moving from Basic to Premium (about AUD 71/month), because only Premium supports private endpoints.
The VNet itself and Postgres VNet integration are free.
These are list-price estimates, to be checked against the price API when Phase 10b is planned.

Later phases add: Static Web Apps (Free tier, AUD 0), Blob Storage (cents for one photo per request), a Container Apps Job (seconds per run), and k6 load tests (one-off spikes in Container Apps and Log Analytics usage).

## Watch out for

- **Leaving it running.** About AUD 2.50 a day for the Phase 9 resources alone, with nobody using them.
- **Dedicated workload profiles.** Adding one to the Container Apps environment adds a management charge of AUD 0.2066/hour (about AUD 150/month) plus the profile's VMs. Stay Consumption-only.
- **Log Analytics ingestion.** The only charge here that grows with traffic and logging, not with time. Load tests and verbose logging are what push it past the 5 GB free allowance.
- **Stopping Postgres instead of deleting it.** A stopped server stops the compute charge but still bills storage, and Azure starts it again automatically after 7 days.

## Actual charges log

One row per working session, filled in from Cost Management the day after.

| Date | Hours up | What ran | Charged (AUD) | Notes |
|---|---|---|---|---|
