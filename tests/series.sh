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
#   - a unit whose server never becomes ready fails and leaves no server
#     running;
#   - a unit whose power limit the environment cannot read runs only on the
#     host's word, and says so;
#   - a unit whose server's log cannot be kept does not pass;
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
# A directory of its own for each run: a path deleted and made again at once
# can look missing to Docker Desktop's file sharing for a moment.
mkdir -p "$ROOT/.cache"
work="$(mktemp -d "$ROOT/.cache/series-test.XXXXXX")"
mkdir -p "$work/models"
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

# A server that never becomes ready: the unit fails, and nothing of it is left
# running (its container, the GPU sampler).
python3 -I - "$work/plan.json" "$work/plan-dead.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["server"]["args"] = ["python3", "-I", "-c", "import time; time.sleep(3600)"]
plan["server"]["ready_timeout_s"] = 5
plan["units"] = plan["units"][:1]
json.dump(plan, open(sys.argv[2], "w"))
PY
if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" MODELS_LOCK="$work/models.lock" \
     python3 -I "$ROOT/workstation/run_series.py" "$work/plan-dead.json" "$work/out4" >"$work/run5.txt" 2>&1; then
  fail "a unit whose server never became ready passed"
elif grep -q 'the server was not ready in 5 s' "$work/run5.txt" && [ -z "$(docker ps -aq --filter name=^series-server$)" ] \
     && compgen -G "$work/out4/units/u1.failed-*" >/dev/null; then
  pass "a unit whose server never becomes ready fails, is kept as failed, and leaves no server running"
else
  fail "a dead server: $(tail -2 "$work/run5.txt" | tr '\n' ' '); containers left: $(docker ps -aq --filter name=^series-server$)"
fi

# A power limit the environment cannot read: a unit that pins one runs only
# when the host says it set it, and its manifest says how it was known. A fake
# nvidia-smi answers [N/A] for the limit, as one can inside a GPU-P guest.
mkdir -p "$work/bin"
cat >"$work/bin/nvidia-smi" <<'SH'
#!/bin/sh
case "$*" in
  *-lms*) echo "timestamp, power.draw [W]"; exec sleep 3600 ;;
  *--query-gpu=power.limit\ *|*--query-gpu=power.limit) echo "[N/A]" ;;
  *) echo "Fake GPU, 0.0, 1, 2, 0, [N/A]" ;;
esac
SH
chmod +x "$work/bin/nvidia-smi"
python3 -I - "$work/plan.json" "$work/plan-limit.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["units"] = [dict(plan["units"][0], id="u450", power_limit_w=450)]
json.dump(plan, open(sys.argv[2], "w"))
PY
limited() { PATH="$work/bin:$PATH" SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" \
  MODELS_LOCK="$work/models.lock" python3 -I "$ROOT/workstation/run_series.py" "$work/plan-limit.json" "$@"; }
limited "$work/out5" >"$work/run6.txt" 2>&1
if grep -q 'SKIP  u450: skipped: the power limit reads' "$work/run6.txt" && [ ! -e "$work/out5/units/u450" ]; then
  pass "a unit whose power limit the environment cannot read is skipped when the host does not say it set it"
else
  fail "an unreadable power limit without the host's word: $(tail -2 "$work/run6.txt" | tr '\n' ' ')"
fi
limited "$work/out5" --power-limit-w 450 >"$work/run7.txt" 2>&1
if [ -f "$work/out5/units/u450/done" ] && grep -q '"power_limit": "450 W, as the host set it' "$work/out5/units/u450/manifest.json" \
   && grep -q '"server_log": "kept"' "$work/out5/units/u450/manifest.json" && [ -f "$work/out5/units/u450/server.log" ]; then
  pass "with the host's word the unit runs, its manifest says the limit was the host's, and the server's log is kept"
else
  fail "an unreadable power limit with the host's word: $(tail -2 "$work/run7.txt" | tr '\n' ' ')"
fi

# A unit whose server's log cannot be kept does not pass: a docker that
# refuses `docker logs` and passes everything else to the real one.
real_docker="$(command -v docker)"
mkdir -p "$work/bin2"
# shellcheck disable=SC2016  # the fake's own $1 and $@, written as they are
printf '#!/bin/sh\n[ "$1" = logs ] && exit 1\nexec "%s" "$@"\n' "$real_docker" >"$work/bin2/docker"
chmod +x "$work/bin2/docker"
python3 -I - "$work/plan.json" "$work/plan-nolog.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["units"] = [dict(plan["units"][1], id="u-nolog")]
json.dump(plan, open(sys.argv[2], "w"))
PY
if PATH="$work/bin2:$PATH" SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" MODELS_LOCK="$work/models.lock" \
     python3 -I "$ROOT/workstation/run_series.py" "$work/plan-nolog.json" "$work/out6" >"$work/run8.txt" 2>&1; then
  fail "a unit passed although its server's log could not be kept"
elif grep -q "FAIL  u-nolog: failed: the server's log could not be kept" "$work/run8.txt"; then
  pass "a unit whose server's log could not be kept fails"
else
  fail "a unit without its server's log: $(tail -2 "$work/run8.txt" | tr '\n' ' ')"
fi

# An environment that is not closed: the isolation check runs and fails here.
if series "$work/out3" >"$work/run4.txt" 2>&1; then
  fail "a series started although its isolation check had not passed"
elif grep -q 'the isolation check failed' "$work/run4.txt" && [ -z "$(ls "$work/out3/units")" ]; then
  pass "a series whose isolation check fails does not start"
else
  fail "the series did not start, for another reason: $(tail -2 "$work/run4.txt" | tr '\n' ' ')"
fi
exit "$failed"
