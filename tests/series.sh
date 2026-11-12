#!/usr/bin/env bash
# series.sh - workstation/run_series.py, run on a plan whose server is
# tests/stub_server.py in a container, so every step of a unit runs with no
# GPU and no model: the internal network, the server's time to ready, the
# flagship's capacity.py through loadgen/calls.py from a client container, the
# recomputation, the manifest, the unit's SHA256SUMS. Then:
#   - a unit left half done is found, recorded as interrupted and redone, and
#     a unit done before is not run again;
#   - a model file that is not the one its lock pins stops the series before
#     any unit;
#   - a series whose isolation check fails does not start.
# The isolation check is skipped (and recorded as skipped) in the cases that
# do not test it: a test machine is not a closed environment.
# tests/series-plants.tsv breaks the runner in turn; this test must notice.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$(sed -n 's/^PYTHON_IMAGE=//p' "$ROOT/images.lock")"
FLAGSHIP="${FLAGSHIP:-$("$ROOT/scripts/sources.sh" path flagship)}"
ARCHIVE="$(dirname "$FLAGSHIP")/release/kubernetes-air-gapped-ai-agent-v1.9.0.tar.gz"
SHA="$(awk '$1 == "flagship" {print $4}' "$ROOT/sources.lock")"
# Docker Desktop shares the home directory, not the system's temporary one.
work="$ROOT/.cache/series-test"
/bin/rm -rf "$work" && mkdir -p "$work/models"
trap '/bin/rm -rf "$work"; docker rm -f series-server >/dev/null 2>&1' EXIT
failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

head -c 4096 /dev/urandom >"$work/models/stub-model.gguf"
sum="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$work/models/stub-model.gguf")"
printf 'stub-model https://huggingface.co/example/stub/resolve/%040d/stub.gguf %s Apache-2.0 unpinned\n' 0 "$sum" >"$work/models.lock"
printf 'data %s\nallow 127.0.0.1 9 series\ndeny 1.1.1.1 443\n' "$work" >"$work/probes"
python3 -I - "$work" "$IMAGE" "$FLAGSHIP" "$ARCHIVE" "$SHA" <<'PY'
import json, sys
work, image, flagship, archive, sha = sys.argv[1:]
plan = {
    "series": "test", "probes": work + "/probes", "accelerator": "stub, tests/series.sh",
    "flagship": {"tag": "v1.9.0", "sha256": sha, "archive": archive, "dir": flagship},
    "images": {"server": image, "client": image}, "models_dir": work + "/models",
    "server": {"args": ["python3", "-I", "/stub/stub_server.py", "8080", "0.0.0.0"],
               "mounts": [["tests", "/stub"]], "memory": "256m", "gpu_flags": []},
    "units": [{"id": "u1", "model": "stub-model", "levels": [1, 2], "min_seconds": 0},
              {"id": "u2", "model": "stub-model", "levels": [1], "min_seconds": 0}],
}
json.dump(plan, open(work + "/plan.json", "w"), indent=1)
PY

series() { MODELS_LOCK="$work/models.lock" python3 -I "$ROOT/workstation/run_series.py" "$work/plan.json" "$@"; }
last() { python3 -I -c 'import json, sys; s = json.load(open(sys.argv[1])); print(json.dumps(s["invocations"][-1]))' "$1/series.json"; }

# A whole series.
if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out" >"$work/run1.txt" 2>&1; then
  pass "a whole series ran: $(grep -c '^PASS' "$work/run1.txt") units done"
else
  fail "the series did not finish: $(tail -3 "$work/run1.txt" | tr '\n' ' ')"
fi
for u in u1 u2; do
  d="$work/out/units/$u"
  if [ -f "$d/done" ] && [ -f "$d/SHA256SUMS" ] && grep -q '"requests_sha256": "603153b0dc5fd6ab' "$d/manifest.json" \
     && grep -q '^PASS' "$d/recompute.txt" && ! grep -q '^FAIL' "$d/recompute.txt"; then
    pass "unit $u: done, its levels recomputed from their records, the flagship's load (603153b0...) in its manifest"
  else
    fail "unit $u is not done whole (done, SHA256SUMS, manifest with the load's hash, a recomputation that passed)"
  fi
done
if (cd "$work/out/units/u1" && python3 -I -c '
import hashlib, os, sys
listed = {}
for line in open("SHA256SUMS"):
    h, n = line.split()
    listed[n] = h
if set(listed) != set(os.listdir(".")) - {"SHA256SUMS", "done"}:
    sys.exit(1)
if any(hashlib.sha256(open(n, "rb").read()).hexdigest() != h for n, h in listed.items()):
    sys.exit(1)'); then
  pass "a unit's SHA256SUMS names every file in it, and holds for each"
else
  fail "a unit's SHA256SUMS leaves a file out, or does not hold for one"
fi
if grep -q '"state": "not checked"' "$work/out/series.json"; then
  pass "the skipped isolation check is recorded as not checked"
else
  fail "the skipped isolation check is not recorded"
fi

# A unit cut short, and a unit done before.
/bin/rm -rf "$work/out/units/u2" && mkdir -p "$work/out/units/u2.partial" && echo cut >"$work/out/units/u2.partial/calls.jsonl"
SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out" >"$work/run2.txt" 2>&1
inv="$(last "$work/out")"
if grep -q '"interrupted_units": \["u2"\]' <<<"$inv" && grep -q '"u1": "done before"' <<<"$inv" \
   && grep -q '"u2": "done"' <<<"$inv" && [ -f "$work/out/units/u2/done" ] && [ ! -e "$work/out/units/u2.partial" ]; then
  pass "a unit cut short is recorded as interrupted and redone whole; a unit done before is not run again"
else
  fail "resuming a series: $inv"
fi

# The conditions changed since the series began: another series, not this one.
python3 -I - "$work/out/series.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["invocations"][0]["preflight"]["conditions"]["driver_version"] = "0.0"
json.dump(s, open(sys.argv[1], "w"))
PY
if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out" >"$work/run2b.txt" 2>&1; then
  fail "a series went on although its conditions had changed since it began"
elif grep -q "conditions changed since it began (driver_version)" "$work/run2b.txt"; then
  pass "a series whose conditions changed since it began does not go on, and the changed one is named"
else
  fail "a changed condition stopped the series for another reason: $(tail -2 "$work/run2b.txt" | tr '\n' ' ')"
fi

# Weights that are not the ones the lock pins.
printf 'x' >>"$work/models/stub-model.gguf"
if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out2" >"$work/run3.txt" 2>&1; then
  fail "a series ran on a model file whose sha256 is not the one its lock pins"
elif grep -q 'models.lock pins' "$work/run3.txt" && [ -z "$(ls "$work/out2/units")" ]; then
  pass "a model file that is not the pinned one stops the series before any unit"
else
  fail "a changed model file stopped the series for another reason: $(tail -2 "$work/run3.txt" | tr '\n' ' ')"
fi
head -c -1 "$work/models/stub-model.gguf" >"$work/models/stub-model.tmp" 2>/dev/null \
  || python3 -I -c 'import sys; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d[:-1])' "$work/models/stub-model.gguf" "$work/models/stub-model.tmp"
mv -f "$work/models/stub-model.tmp" "$work/models/stub-model.gguf"

# An environment that is not closed: the isolation check runs and fails here.
if series "$work/out3" >"$work/run4.txt" 2>&1; then
  fail "a series started although its isolation check had not passed"
elif grep -q 'the isolation check failed' "$work/run4.txt" && [ -z "$(ls "$work/out3/units")" ]; then
  pass "a series whose isolation check fails does not start"
else
  fail "the series did not start, for another reason: $(tail -2 "$work/run4.txt" | tr '\n' ' ')"
fi
exit "$failed"
