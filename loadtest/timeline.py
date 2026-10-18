# Prints a timeline from a k6 CSV output: requests, status codes and p95 per bucket, for lookups and creates.
#   python3 loadtest/timeline.py loadtest/results/<name>.csv.gz [bucket-seconds]
import csv, gzip, sys, collections, datetime
path, bucket = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 15
rows = collections.defaultdict(lambda: collections.defaultdict(list))
with gzip.open(path, "rt") as f:
    for r in csv.DictReader(f):
        if r["metric_name"] != "http_req_duration" or r["name"] not in ("lookup", "create", "status"):
            continue
        t = int(r["timestamp"]) // bucket * bucket
        rows[t][r["name"]].append((r["status"], float(r["metric_value"])))
def p95(v):
    v = sorted(v); return v[int(len(v) * 0.95)] if v else 0
print("time(UTC)  | lookup n  codes             p95ms | create n codes           p95ms")
for t in sorted(rows):
    out = []
    for n in ("lookup", "create"):
        v = rows[t][n]; codes = collections.Counter(s for s, _ in v)
        out.append(f"{len(v):5d} {dict(codes)!s:22.22} {p95([d for _, d in v]):7.0f}")
    print(datetime.datetime.utcfromtimestamp(t).strftime("%H:%M:%S"), " | ", " | ".join(out))
