#!/usr/bin/env bash
# e2e.sh - the CPU row, measured in CI with the load generator the
# workstation uses, and every number in it computed again from its records.
#
# On the kind cluster scripts/up.sh made: the flagship's CPU server with the
# weights models.lock pins (deploy/model-server.yaml), then the flagship's
# capacity.py through loadgen/calls.py from a Job beside it
# (deploy/capacity-job.yaml). Checks, each a PASS or FAIL line:
#   - the server starts only on the weights models.lock pins;
#   - the load generator finishes, and no call fails at any level;
#   - every level's aggregates follow from the call records
#     (scripts/recompute.py check);
#   - every pod in the cluster runs an image images.lock names.
# Measured lines carry each level's calls a minute, p50 and p95.
#
# MODEL (granite-4.0-1b), LEVELS (1,2) and MIN_SECONDS (20) set the series.
# RESULTS names a directory to keep capacity.json and calls.jsonl in;
# E2E_RESULTS a file for the checks and measurements as JSON.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${MODEL:-granite-4.0-1b}"
LEVELS="${LEVELS:-1,2}"
MIN_SECONDS="${MIN_SECONDS:-20}"
FLAGSHIP="${FLAGSHIP:-$("$ROOT/scripts/sources.sh" path flagship)}"
export FLAGSHIP
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
checks=(); measured=(); failed=0
pass() { checks+=("PASS	$*"); printf 'PASS  %s\n' "$*"; }
fail() { checks+=("FAIL	$*"); printf 'FAIL  %s\n' "$*"; failed=1; }
measure() { measured+=("$*"); printf 'MEASURED  %s\n' "$*"; }

record() {
  [ -n "${E2E_RESULTS:-}" ] || return 0
  { printf '%s\n' "${checks[@]}"; printf -- '--measured--\n'; printf '%s\n' "${measured[@]}"; } \
    | python3 -I -c '
import json, sys
checks, _, measured = sys.stdin.read().partition("--measured--\n")
out = {"checks": [{"state": l.split("\t", 1)[0], "name": l.split("\t", 1)[1]} for l in checks.splitlines() if "\t" in l],
       "measured": [l for l in measured.splitlines() if l.strip()]}
json.dump(out, open(sys.argv[1], "w"), indent=2)' "$E2E_RESULTS"
}
finish() { record; exit "$failed"; }

# The server, on the weights models.lock pins and no other.
sha="$(awk -v n="$MODEL" '$1 == n && $0 !~ /^[[:space:]]*#/ {print $3}' "$ROOT/models.lock")"
[ -n "$sha" ] || { fail "models.lock has no line for $MODEL"; finish; }
sed -e "s#@MODEL@#$MODEL#g" -e "s#@SHA256@#$sha#g" "$ROOT/deploy/model-server.yaml" | kubectl apply -f - >/dev/null \
  || { fail "the model server's manifest does not apply"; finish; }
ready=""
for _ in $(seq 1 120); do
  status="$(kubectl -n inference get pods -l app=model-server -o json)"
  verdict="$(python3 -I -c '
import json, sys
pods = json.load(sys.stdin)["items"]
live = [p for p in pods if not p["metadata"].get("deletionTimestamp")]
for p in live:
    for s in p["status"].get("initContainerStatuses", []):
        t = s.get("state", {}).get("terminated") or s.get("lastState", {}).get("terminated")
        if t and t.get("exitCode", 0) != 0:
            print("refused"); sys.exit()
print("ready" if len(live) == 1 and all(c.get("ready") for c in live[0]["status"].get("containerStatuses", [{}])) else "waiting")
' <<<"$status")"
  [ "$verdict" = waiting ] || { ready="$verdict"; break; }
  sleep 5
done
case "$ready" in
  ready)
    pass "the model server started on $MODEL after its pod hashed the weights: sha256 ${sha:0:12}..., the one models.lock pins" ;;
  refused)
    fail "the model server's pod refused the weights: their sha256 is not the ${sha:0:12}... models.lock pins"; finish ;;
  *)
    fail "the model server was not ready in ten minutes"; finish ;;
esac

# The control for that check: the same pod, told another sha256, must refuse
# the same file before its server starts.
python3 -I - "$ROOT/deploy/model-server.yaml" "$MODEL" <<'PY' | kubectl apply -f - >/dev/null
import sys
doc = next(d for d in open(sys.argv[1]).read().split("\n---\n") if "kind: Deployment" in d)
print(doc.replace("name: model-server\n", "name: wrong-weights\n").replace("app: model-server", "app: wrong-weights")
      .replace("@MODEL@", sys.argv[2]).replace("@SHA256@", "0" * 64))
PY
control=""
for _ in $(seq 1 60); do
  control="$(kubectl -n inference get pods -l app=wrong-weights -o json | python3 -I -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    for s in p["status"].get("initContainerStatuses", []):
        t = s.get("state", {}).get("terminated") or s.get("lastState", {}).get("terminated")
        if t:
            print("refused" if t.get("exitCode", 0) != 0 else "accepted"); sys.exit()
')"
  [ -z "$control" ] || break
  sleep 5
done
kubectl -n inference delete deployment wrong-weights --ignore-not-found --wait=false >/dev/null 2>&1
if [ "$control" = refused ]; then
  pass "the control: the same pod told another sha256 refused the same weights before its server started"
else
  fail "the control: a pod told another sha256 did not refuse the weights (${control:-no answer in five minutes})"
fi

# The load, from a Job beside the server.
kubectl delete namespace measure --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
sed -e "s#@LEVELS@#$LEVELS#" -e "s#@MIN_SECONDS@#$MIN_SECONDS#" -e "s#@MODEL@#$MODEL#" "$ROOT/deploy/capacity-job.yaml" \
  | python3 -I -c 'import sys; print(next(d for d in sys.stdin.read().split("\n---\n") if "kind: Namespace" in d))' \
  | kubectl apply -f - >/dev/null
kubectl -n measure create configmap capacity \
  --from-file=calls.py="$ROOT/loadgen/calls.py" \
  --from-file=capacity.py="$FLAGSHIP/scripts/capacity.py" \
  --from-file=harness.py="$FLAGSHIP/evals/harness.py" \
  --from-file=tasks.json="$FLAGSHIP/evals/tasks.json" \
  --from-file=server.py="$FLAGSHIP/manifests/mcp/server.py" \
  --from-file=policy.json="$FLAGSHIP/manifests/mcp/policy.json" >/dev/null
sed -e "s#@LEVELS@#$LEVELS#" -e "s#@MIN_SECONDS@#$MIN_SECONDS#" -e "s#@MODEL@#$MODEL#" "$ROOT/deploy/capacity-job.yaml" \
  | kubectl apply -f - >/dev/null || { fail "the load generator's Job does not apply"; finish; }
state=""
for _ in $(seq 1 240); do
  state="$(kubectl -n measure get job capacity -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null)"
  case "$state" in 1/*|*/1) break ;; esac
  sleep 5
done
kubectl -n measure logs job/capacity >"$work/log" 2>&1
sed -n '1,/^--capacity--$/p' "$work/log" | sed '$d'
sed -n '/^--capacity--$/,/^--calls--$/p' "$work/log" | sed '1d;$d' >"$work/capacity.json"
sed '1,/^--calls--$/d' "$work/log" >"$work/calls.jsonl"
case "$state" in
  1/*) pass "the load generator finished every level ($LEVELS), each at least $MIN_SECONDS s" ;;
  *) fail "the load generator did not finish (Job state '$state')"; finish ;;
esac
if [ -n "${RESULTS:-}" ]; then
  mkdir -p "$RESULTS/cpu-$MODEL"
  /bin/cp -f "$work/capacity.json" "$work/calls.jsonl" "$RESULTS/cpu-$MODEL/"
fi

python3 -I "$ROOT/scripts/recompute.py" check "$work/capacity.json" "$work/calls.jsonl" >"$work/recompute.txt"
while IFS= read -r line; do
  case "$line" in
    PASS*) pass "${line#PASS  }" ;;
    FAIL*) fail "${line#FAIL  }" ;;
  esac
done <"$work/recompute.txt"
grep -q '^PASS' "$work/recompute.txt" || fail "the recomputation checked no level"

python3 -I - "$work/capacity.json" "$MODEL" >"$work/levels.txt" <<'PY'
import json, sys
r, model = json.load(open(sys.argv[1])), sys.argv[2]
bad = 0
for lv in r["levels"]:
    print("MEASURED\t%s · CPU, a GitHub-hosted runner, 1 slot x 2 threads · concurrency %d: %s calls a minute, p50 %s s, p95 %s s, %s output tokens/s, %d of %d failed"
          % (model, lv["concurrency"], lv["calls_per_min"], lv["p50_s"], lv["p95_s"], lv["out_tokens_per_s"], lv["failed"], lv["calls"]))
    bad += lv["failed"]
sys.exit(1 if bad else 0)
PY
answered=$?
while IFS=$'\t' read -r _ text; do measure "$text"; done < <(grep '^MEASURED' "$work/levels.txt")
if [ "$answered" -eq 0 ] && grep -q '^MEASURED' "$work/levels.txt"; then
  pass "no call failed at any level: the server answered every call the load generator made"
else
  fail "calls failed in the series, or it reported no level"
fi

# Every image a pod runs is one images.lock names.
pods="$(kubectl get pods --all-namespaces -o json)"
stray="$(python3 -I -c '
import json, re, sys
pins = set(re.findall(r"^[A-Z0-9_]+_IMAGE=(\S+)$", open(sys.argv[1]).read(), re.M))
pods = json.load(sys.stdin)["items"]
used = {c["image"] for p in pods for c in p["spec"].get("containers", []) + p["spec"].get("initContainers", [])}
print(" ".join(sorted(used - pins)))
' "$ROOT/images.lock" <<<"$pods")"
if [ -z "$stray" ]; then
  pass "every pod in the cluster runs an image images.lock names"
else
  fail "pods run images images.lock does not name: $stray"
fi
finish
