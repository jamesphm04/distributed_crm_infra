# Load test results

What each k6 run against the deployed system found.
How to run them is in `../loadtest/README.md`; why the test is shaped this way is in `decisions.md`.

## The question

WCP's requirements say "speed is the actual spec": the app must be fast enough for a salesperson mid-call, or staff won't use it (`11-non-functional-requirements.md`).
There is no numeric target, so this project uses these:

| Rule | Target |
|---|---|
| Lookup (the live-call read; search replaces it in Phase 14) | p95 < 300 ms |
| Create | p95 < 500 ms |
| Errors | < 1% (the run aborts above 10%) |
| Decision (worker) | median < 5 s, and over 50% decided within 16 s |

**Capacity** is the highest lookup level whose 90-second hold meets the lookup rules.
To turn rates into people we use Little's Law with a deliberately heavy staff member: one journey a minute, so 1 journey/s ≈ 60 active staff.

## Setup

- Environment: 2 API replicas and 1 worker at 0.5 vCPU / 1 GiB each, Postgres Flexible Server B1ms, Managed Redis Balanced B0, Service Bus Standard, all in Australia East.
- Load from a laptop in Adelaide, about 25 ms from Australia East.
  `dropped_iterations` stayed under 15 per run (of 47,000 to 99,000), so the laptop was never the bottleneck.
- Two kinds of user ran at once: `lookups` (GET a random return request from a pool of 200) and `journeys` (create, then poll every 2 s, up to 8 times).
- Run on 2026-10-18; times are UTC (Adelaide is UTC+10:30).

## Results

### Smoke — 07:36–07:38

Everything worked: 630 requests, 0 errors, lookup p95 45 ms, create p95 49 ms.
**No journey got a decision** (0 of 34), because `setup()` had just created 170 pool rows and their messages queued ahead of the journeys.
The queue drained at about 0.6 messages a second, the first measurement of the worker's ceiling.
Later runs reuse the pool.

### Baseline stress — 07:41–07:52

| Level (lookups/s) | Journeys/min | Lookup p95 | Create p95 | Errors | Decided in window | Median decision |
|---|---|---|---|---|---|---|
| 10 | 30 | 35 ms | 50 ms | 0 | 72% | 2.1 s |
| 25 | 30 | 33 ms | 45 ms | 0 | 59% | 2.1 s |
| 50 | 60 | 33 ms | 47 ms | 0 | 60% | **8.2 s** ✗ |
| 100 | 120 | 33 ms | 45 ms | 0 | **0%** ✗ | — |
| 200 | 120 | 32 ms | 46 ms | 0 | **0%** ✗ | — |

- **The API never came close to its limits**: 51,840 requests, 0 errors, and lookup p95 flat at about 33 ms from 10/s to 200/s.
- **The worker is the first bottleneck**, at about **65 messages a minute** (just over 1 a second, including failed attempts).
  At 60 journeys a minute decisions started arriving late; at 120 a minute none arrived inside the 16-second window.
  The queue grew from 2 to 308 messages during the run:

  | 07:42 | 07:44 | 07:46 | 07:47 | 07:48 | 07:49 | 07:50 | 07:51 | 07:52 |
  |---|---|---|---|---|---|---|---|---|
  | 2 | 1 | 4 | 17 | 50 | 111 | 184 | 254 | 308 |

- Why the worker is slow: each message spends a median **844 ms** (p95 1.4 s) waiting on the simulated approval API, and `MaxConcurrentCalls = 1` handles one message at a time.
  Postgres (3.7 ms), Redis (1.4 ms) and completing the message (57 ms) are small next to it.

### Stress-high — 07:53–07:59

| Level (lookups/s) | Lookup p95 | Create p95 | Errors |
|---|---|---|---|
| 200 | 32 ms | 44 ms | 0 |
| 300 | 33 ms | 69 ms | 0 |
| 400 | 33 ms | 69 ms | 0 |

- 100,410 requests, 0 errors, lookup p95 still 33 ms at 400/s.
- The busiest API replica reached **79% CPU at 400/s** (from 7% at 10/s), with memory at 19%.
  Postgres stayed at about 11% CPU and 14 connections, because every lookup was a cache hit.
- **Capacity is above 400 lookups/s; it was not reached.**
  At that CPU, the API replicas' CPU would set the limit somewhere around 450–500/s; that is an estimate, not a measurement.

### Spike — 08:00–08:05

10/s, then 300/s within one second for 60 s, then back to 10/s.
Lookup p95 was 35 ms before, 32 ms during and 34 ms after; 0 errors in 21,626 requests.
Nothing needed to recover.

### Cache off — 08:06–08:17

The stress ramp again with `Caching__Enabled=false`, so every lookup read Postgres.

| Postgres at 200 lookups/s | Cache on | Cache off |
|---|---|---|
| Data sent per minute | about 1 MB | about 9 MB |
| CPU | about 11% | about 25% |
| Active connections | about 14 | 29 |

- What users saw didn't change: lookup p95 33 ms at every level, 0 errors in 51,931 requests.
- A primary-key read costs Postgres a few milliseconds, and the server side of a cached lookup is 1.7 ms median (4.5 ms p95).
  Most of the 33 ms users see is the network between Adelaide and Australia East.
- **So at this size, Redis buys database headroom, not speed.**
  Without it, Postgres CPU more than doubled and connections reached 29 of the 50 a B1ms allows (10 of which are reserved).
  B1ms is burstable: a sustained 25% would draw down its CPU credits, so a longer run would likely degrade.
  Search in Phase 14 runs a real query instead of a primary-key read, so the cache should matter more there.

### Redis outage — 08:25–08:36

Steady load (50 lookups/s, 30 journeys/min).
At 08:27:17 Redis public network access was turned off and both apps were restarted, so they came back unable to reach Redis.
At 08:31:33 access was turned back on.

| UTC | Lookups | Creates |
|---|---|---|
| 08:25–08:28 | 200, p95 31–34 ms | 201 |
| 08:28:30 | 200 | **503 + `Retry-After: 5`** |
| 08:29:00–08:31:00 | **p95 4 s → 13 s → 22 s, then 60 s timeouts (395 requests)** | 503 |
| 08:31:00 | 200, p95 39 ms | 503 |
| 08:31:30 | 200 | 201 again |

- **Creates failed closed, as designed.**
  Every create during the outage got `503` with `Retry-After: 5` and *"The idempotency store is unavailable. Retry the request with the same Idempotency-Key."*
  They recovered within about 30 s of Redis coming back.
- **Lookups did not fail open cleanly.**
  They stayed correct (every completed lookup was a 200 from Postgres), but for about two minutes latency rose to timeouts, and the replicas ran at 86–98% CPU against about 15% normally at this load.
  They recovered by themselves at 08:31:00, half a minute before Redis came back.
- **The cause is Redis being unreachable, not the restart.**
  A control run at 08:38–08:45 did the same rolling restart with Redis healthy: lookup p95 peaked at 64 ms and API CPU at 30%, with 0 errors.
- **Likely mechanism, not yet proven:** every lookup made two failing Redis calls (the read and the write-back), and each failure was logged as a warning with a full stack trace.
  At 50 lookups/s that is about 100 exceptions and stack traces a second on a 0.5 vCPU replica.
  The replica console logs show exactly these warnings.
  The usual fix is a circuit breaker: after a few failures, skip Redis for a few seconds instead of trying it on every request.
- **Turning off public network access alone does not cut Redis off.**
  In the dry run it blocked new connections (a laptop was refused) but the apps' existing connections kept working for minutes, so the apps had to be restarted to lose them.
- The stale-cache effect predicted in the plan did not show up: during the outage no new cache entries were written and no creates succeeded, so there was nothing to go stale.

## What it means for WCP

With the heavy model (each staff member does one action a minute):

| Path | Measured limit | Staff at once |
|---|---|---|
| Lookups (live-call read) | over 400/s, not reached | over 24,000 |
| Decisions (worker) | about 65 a minute | about 65 creating a return every minute, nonstop |

- The live-call read is nowhere near a limit, and its server time (1.7 ms median) leaves room for search's real query.
- The worker's ceiling sounds low, but it is about 3,900 decisions an hour.
  WCP's whole business does 600–800 quotes a day, and returns are a fraction of that, so the ceiling is far above real volume.
  What matters for WCP is the shape, not the number: the write-back is single-file and waits on an external system, so a slow Pinnacle bot makes every decision wait in line, and a burst can only drain as fast as that bot.
- A Redis outage stops new returns from being created until it's back (by design), and as built today it also slows lookups badly for a couple of minutes.

## Telemetry

- Smoke measured about **11 KB of telemetry per API request**.
  A third of all trace rows were Redis span events (`Enqueued`, `Sent`, `ResponseReceived`, `received-first-response`, four per Redis command).
- **The workspace stopped collecting at 07:58:35** with `OverQuota`, after about 0.57 GB that day, although the daily cap had been raised from 0.5 to 5 GB at 07:34.
  The cause is not known yet.
  So App Insights has no data for the spike, cache-off and outage runs; those results come from k6, Azure platform metrics (Container Apps, Postgres, Service Bus, which don't go through Log Analytics) and the replicas' console log stream.
- The workspace is recreated by `up`, so Monday starts with a 5 GB cap from creation.

## Open items

- Why a 5 GB cap stopped at about 0.57 GB.
- After the demo, candidate fixes, each to be measured with the same profiles:
  a circuit breaker in front of Redis;
  rate-limited logging of Redis failures;
  `MaxConcurrentCalls` above 1, or scaling the worker on queue length (only once it's known whether the real Pinnacle write-back can take parallel writes);
  turning off Redis span events (`EnrichActivityWithTimingEvents`).
- The 30-minute soak (Monday).
