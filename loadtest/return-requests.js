// Load test for the deployed system. Two kinds of user run at the same time:
//   lookups  - read an existing return request (the live-call read path; search takes its place in Phase 14)
//   journeys - create a return request, then poll its status until the worker decides it
//
//   BASE_URL=https://<api-host> TOKEN=<google-id-token> PROFILE=<profile> k6 run loadtest/return-requests.js
//
// Profiles are below. See loadtest/README.md for how to run them and docs/loadtest-results.md for what we found.
import http from "k6/http";
import exec from "k6/execution";
import { check, sleep } from "k6";
import { b64decode } from "k6/encoding";
import { Rate, Trend } from "k6/metrics";

const BASE_URL = requireEnv("BASE_URL").replace(/\/$/, "");
const TOKEN = requireEnv("TOKEN");
const PROFILE = __ENV.PROFILE || "smoke";

// Journeys poll every 2 s, at most 8 times (a 16 s window). A message that fails is retried 30 s later,
// so about 30% of decisions land outside the window on purpose.
const POLL_INTERVAL_SECONDS = 2;
const MAX_POLLS = 8;
const LOOKUP_POOL_SIZE = 200;

// Each step ramps to its rates, then holds them. Numbers are only read from the hold, where the load is steady.
// lookups: requests per second. journeys: journeys started per minute.
function step(level, lookups, journeys, ramp, hold) {
  return { level: String(level), lookups, journeys, ramp, hold };
}

const PROFILES = {
  // Proves the script and the system work, and fills the lookup pool. About 1 minute.
  smoke: { steps: [step(2, 2, 30, "10s", "50s")] },
  // Climbs until something breaks. Journeys step across the worker's limit (about 1 decision a second).
  stress: {
    steps: [
      step(10, 10, 30, "30s", "90s"),
      step(25, 25, 30, "30s", "90s"),
      step(50, 50, 60, "30s", "90s"),
      step(100, 100, 120, "30s", "90s"),
      step(200, 200, 120, "30s", "90s"),
    ],
  },
  // Only if 200/s still passes: continues where stress stopped.
  "stress-high": {
    steps: [
      step(200, 200, 30, "1m", "30s"),
      step(300, 300, 30, "30s", "90s"),
      step(400, 400, 30, "30s", "90s"),
    ],
  },
  // A sudden jump from a quiet base, then back down. SPIKE_RATE is set to about 75% of the capacity found.
  spike: {
    steps: [
      step("base", 10, 30, "30s", "60s"),
      step("spike", Number(__ENV.SPIKE_RATE || 150), 30, "1s", "60s"),
      step("recovery", 10, 30, "1s", "120s"),
    ],
  },
  // Steady load while a dependency is broken from outside (the Redis outage experiment). About 11 minutes.
  steady: { steps: [step(50, Number(__ENV.STEADY_RATE || 50), 30, "30s", "10m")] },
  // Moderate load held for a long time, looking for drift. SOAK_RATE is about 50% of the capacity found.
  soak: { steps: [step("soak", Number(__ENV.SOAK_RATE || 50), 30, "1m", "30m")] },
};

const profile = PROFILES[PROFILE];
if (!profile) {
  throw new Error(`PROFILE must be one of: ${Object.keys(PROFILES).join(", ")}`);
}

const RAMP_DOWN = "30s";
const timeline = buildTimeline(profile.steps);

// Google ID tokens last an hour; a token that expires mid-run turns the rest of the run into 401s.
requireTokenValidFor(Math.ceil(timeline.totalMs / 60000) + 3);

export const options = {
  setupTimeout: "2m",
  scenarios: {
    // Open model: requests start on schedule whether or not earlier ones have finished, so a slow system shows
    // up as rising latency instead of quietly lowering the load.
    lookups: {
      executor: "ramping-arrival-rate",
      exec: "lookup",
      startRate: 0,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 1000,
      stages: toStages(profile.steps, "lookups"),
    },
    journeys: {
      executor: "ramping-arrival-rate",
      exec: "journey",
      startRate: 0,
      timeUnit: "1m",
      preAllocatedVUs: 20,
      maxVUs: 300,
      stages: toStages(profile.steps, "journeys"),
    },
  },
  thresholds: buildThresholds(profile.steps),
};

const timeToDecision = new Trend("time_to_decision", true);
const decidedInWindow = new Rate("decided_in_window");

const authHeaders = { Authorization: `Bearer ${TOKEN}` };

// Runs once before the load. Reuses existing return requests so repeated runs don't flood the worker with
// pool-building messages; only the first run on a fresh database creates them.
export function setup() {
  const ids = [];
  for (let page = 1; ids.length < LOOKUP_POOL_SIZE; page++) {
    const res = http.get(`${BASE_URL}/api/return-requests?page=${page}&pageSize=100`, {
      headers: authHeaders,
      tags: { name: "setup" },
    });
    if (res.status !== 200) {
      throw new Error(`Listing return requests failed with ${res.status}; is the token valid?`);
    }
    const items = res.json("items");
    items.forEach((item) => ids.push(item.id));
    if (items.length < 100) {
      break;
    }
  }

  while (ids.length < LOOKUP_POOL_SIZE) {
    const count = Math.min(20, LOOKUP_POOL_SIZE - ids.length);
    const responses = http.batch(
      Array.from({ length: count }, () => ["POST", `${BASE_URL}/api/return-requests`, createBody(), createParams("setup")]),
    );
    responses.forEach((res) => {
      if (res.status !== 201) {
        throw new Error(`Creating the lookup pool failed with ${res.status}`);
      }
      ids.push(res.json("id"));
    });
  }

  return { ids: ids.slice(0, LOOKUP_POOL_SIZE) };
}

export function lookup(data) {
  const id = data.ids[Math.floor(Math.random() * data.ids.length)];
  const res = http.get(`${BASE_URL}/api/return-requests/${id}`, {
    headers: authHeaders,
    tags: { name: "lookup", ...currentLevel() },
  });
  check(res, { "lookup returns 200": (r) => r.status === 200 });
}

export function journey() {
  const startedAt = Date.now();

  const created = http.post(`${BASE_URL}/api/return-requests`, createBody(), createParams("create"));
  // check() returns false when it fails: stop this journey instead of polling /undefined.
  if (!check(created, { "create returns 201": (r) => r.status === 201 })) {
    return;
  }

  const id = created.json("id");

  for (let poll = 0; poll < MAX_POLLS; poll++) {
    sleep(POLL_INTERVAL_SECONDS);

    // Every URL has a different id; the name tag groups them into one line of the report.
    const res = http.get(`${BASE_URL}/api/return-requests/${id}`, {
      headers: authHeaders,
      tags: { name: "status", ...currentLevel() },
    });
    if (!check(res, { "status returns 200": (r) => r.status === 200 })) {
      return;
    }

    const status = res.json("status");
    if (status === "Approved" || status === "Rejected") {
      timeToDecision.add(Date.now() - startedAt, currentLevel());
      decidedInWindow.add(true, currentLevel());
      return;
    }
  }

  decidedInWindow.add(false, currentLevel());
}

function createBody() {
  return JSON.stringify({
    orderReference: `LT-${crypto.randomUUID()}`,
    customerEmail: "loadtest@example.com",
    item: "Front brake pad set",
    reason: "k6 load test",
  });
}

function createParams(name) {
  return {
    headers: {
      ...authHeaders,
      "Content-Type": "application/json",
      // A new key per request: a reused key would replay the first response and never reach Postgres.
      "Idempotency-Key": crypto.randomUUID(),
    },
    tags: { name, ...(name === "create" ? currentLevel() : {}) },
  };
}

// Which step the test is in right now, as tags: level (the step's name) and phase (ramp, hold or rampdown).
function currentLevel() {
  const elapsed = Date.now() - exec.scenario.startTime;
  const segment = timeline.segments.find((s) => elapsed < s.endMs);
  return segment ? { level: segment.level, phase: segment.phase } : { level: "end", phase: "rampdown" };
}

function buildTimeline(steps) {
  const segments = [];
  let endMs = 0;
  for (const s of steps) {
    endMs += toMs(s.ramp);
    segments.push({ endMs, level: s.level, phase: "ramp" });
    endMs += toMs(s.hold);
    segments.push({ endMs, level: s.level, phase: "hold" });
  }
  endMs += toMs(RAMP_DOWN);
  segments.push({ endMs, level: "end", phase: "rampdown" });
  return { segments, totalMs: endMs };
}

function toStages(steps, rate) {
  const stages = [];
  for (const s of steps) {
    stages.push({ target: s[rate], duration: s.ramp }, { target: s[rate], duration: s.hold });
  }
  stages.push({ target: 0, duration: RAMP_DOWN });
  return stages;
}

function buildThresholds(steps) {
  const thresholds = {
    // Over 10% errors after the first minute: stop, the system is already broken.
    http_req_failed: ["rate<0.01", { threshold: "rate<0.10", abortOnFail: true, delayAbortEval: "1m" }],
    "http_req_duration{name:lookup}": ["p(95)<300"],
    "http_req_duration{name:create}": ["p(95)<500"],
    "http_req_duration{name:status}": ["p(95)<300"],
    time_to_decision: ["med<5000"],
    // About 70% at zero load. 50%, not 60%, so a quiet run can't fail by chance.
    decided_in_window: ["rate>0.5"],
  };
  // The same rules per step, so the report says which levels passed: the capacity is the last one that did.
  for (const s of steps) {
    const hold = `level:${s.level},phase:hold`;
    thresholds[`http_req_duration{name:lookup,${hold}}`] = ["p(95)<300"];
    thresholds[`http_req_failed{name:lookup,${hold}}`] = ["rate<0.01"];
    thresholds[`http_req_duration{name:create,${hold}}`] = ["p(95)<500"];
    thresholds[`time_to_decision{level:${s.level}}`] = ["med<5000"];
    thresholds[`decided_in_window{level:${s.level}}`] = ["rate>0.5"];
  }
  return thresholds;
}

function toMs(duration) {
  const match = /^(\d+)(s|m)$/.exec(duration);
  if (!match) {
    throw new Error(`Durations are written like 30s or 2m, not ${duration}`);
  }
  return Number(match[1]) * (match[2] === "m" ? 60000 : 1000);
}

function requireEnv(name) {
  const value = __ENV[name];
  if (!value) {
    throw new Error(`Set ${name}; see loadtest/README.md`);
  }
  return value;
}

function requireTokenValidFor(minutes) {
  const payload = JSON.parse(b64decode(TOKEN.split(".")[1], "rawurl", "s"));
  const minutesLeft = Math.floor((payload.exp * 1000 - Date.now()) / 60000);
  if (minutesLeft < minutes) {
    throw new Error(`TOKEN expires in ${minutesLeft} min; this profile needs ${minutes}. Get a new one.`);
  }
}
