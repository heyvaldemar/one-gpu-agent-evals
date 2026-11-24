#!/usr/bin/env bash
# memory_probe.sh - workstation/memory_probe.py, run on a spec whose server is
# tests/stub_server.py in a container, so every step of a configuration runs
# with no GPU and no model: the internal network, the sampler, the time to
# ready, the calls from a container beside the server, the kept log, the
# results and their SHA256SUMS. Then:
#   - a probe never writes over another: an OUT that exists is refused;
#   - a model file that is not the one its lock pins stops the probe before
#     any configuration;
#   - a server that never comes up fails its configuration, keeps its log,
#     leaves no server running, and the configurations after it in the same
#     mapping mode that would put more on the card are not tried;
#   - a configuration the time budget would not hold is not started.
# The isolation check and the image pins are skipped with --test, and the
# manifest says so: a test machine is not a closed environment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$(sed -n 's/^PYTHON_IMAGE=//p' "$ROOT/images.lock")"
mkdir -p "$ROOT/.cache"
work="$(mktemp -d "$ROOT/.cache/memprobe-test.XXXXXX")"
mkdir -p "$work/models"
trap '/bin/rm -rf "$work"; docker rm -f memprobe-server >/dev/null 2>&1' EXIT
failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

head -c 4096 /dev/urandom >"$work/models/stub-model.gguf"
sum="$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$work/models/stub-model.gguf")"
printf 'stub-model https://huggingface.co/example/stub/resolve/%040d/stub.gguf %s Apache-2.0 unpinned\n' 0 "$sum" >"$work/models.lock"
export MODELS_LOCK="$work/models.lock"

spec() {  # spec FILE ARGS_JSON N_CPU_MOE_JSON BUDGET
  python3 -I - "$1" "$work" "$IMAGE" "$2" "$3" "$4" <<'PY'
import json, sys
path, work, image, args, ncm, budget = sys.argv[1:]
json.dump({"probe": "test", "model": "stub-model", "models_dir": work + "/models", "image": image,
           "client_image": image, "base_args": json.loads(args), "mounts": [["tests", "/stub"]],
           "gpu_flags": [], "n_cpu_moe": json.loads(ncm), "mmap": ["mmap"], "ready_timeout_s": 20,
           "calls": 3, "max_tokens": 16, "budget_s": int(budget)}, open(path, "w"))
PY
}
probe() { python3 -I "$ROOT/workstation/memory_probe.py" "$@" --test; }
STUB='["python3", "-I", "/stub/stub_server.py", "8080", "0.0.0.0"]'

# A whole probe, two configurations.
spec "$work/ok.json" "$STUB" '[30, 26]' 3600
if probe "$work/ok.json" "$work/out1" >"$work/run1.txt" 2>&1; then
  pass "the probe ran on the stub server: $(grep -c '^OK' "$work/run1.txt") configurations OK"
else
  fail "the probe on the stub server exited non-zero: $(tail -3 "$work/run1.txt")"
fi
if python3 -I - "$work/out1" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(out, "results.jsonl"))]
assert [r["config"] for r in rows] == ["mmap-cpu-moe-30", "mmap-cpu-moe-26"], rows
for r in rows:
    assert not r.get("failed"), r
    assert r["time_to_ready_s"] is not None
    assert len(r["calls"]["short"]) == 3 and all("usage" in c for c in r["calls"]["short"]), r["calls"]
    assert "usage" in r["calls"]["long"], r["calls"]["long"]
    assert r["server_args"][-2:] == ["--n-cpu-moe", str(r["n_cpu_moe"])], r["server_args"]
    assert r["peaks"]["samples"] >= 3, r["peaks"]
    assert os.path.getsize(os.path.join(out, r["config"] + ".samples.jsonl")) > 0
    assert os.path.exists(os.path.join(out, r["config"] + ".server.log"))
m = json.load(open(os.path.join(out, "manifest.json")))
assert m["test"] is True and m["isolation"]["state"] == "not checked", m
listed = {}
for line in open(os.path.join(out, "SHA256SUMS")):
    s, n = line.rstrip("\n").split("  ", 1)
    listed[n] = s
assert set(listed) == set(os.listdir(out)) - {"SHA256SUMS"}, (sorted(listed), sorted(os.listdir(out)))
for n, s in listed.items():
    assert hashlib.sha256(open(os.path.join(out, n), "rb").read()).hexdigest() == s, n
PY
then pass "each configuration: ready, three short calls and a long one answered, samples kept, log kept, every file in SHA256SUMS"; else fail "a configuration's record is not whole"; fi
if [ -z "$(docker ps -aq -f name=^memprobe-server$)" ]; then pass "no server is left running"; else fail "a server was left running"; fi

# An OUT that exists is not written over.
before="$(cat "$work/out1/SHA256SUMS")"
if probe "$work/ok.json" "$work/out1" >"$work/run2.txt" 2>&1; then
  fail "the probe wrote into an OUT that exists"
elif grep -q 'REFUSED' "$work/run2.txt" && [ "$before" = "$(cat "$work/out1/SHA256SUMS")" ]; then
  pass "an OUT that exists is refused and left as it was"
else
  fail "an OUT that exists was not refused cleanly: $(tail -2 "$work/run2.txt")"
fi

# A model file that is not the pinned one stops the probe before any configuration.
cp "$work/models/stub-model.gguf" "$work/stub.keep"
printf 'x' >>"$work/models/stub-model.gguf"
if probe "$work/ok.json" "$work/out3" >"$work/run3.txt" 2>&1; then
  fail "the probe ran on a model file its lock does not pin"
elif grep -q 'models.lock pins' "$work/run3.txt" && [ ! -e "$work/out3/results.jsonl" ]; then
  pass "a model file its lock does not pin stops the probe before any configuration"
else
  fail "a changed model file was not refused before the configurations: $(tail -2 "$work/run3.txt")"
fi
/bin/cp -f "$work/stub.keep" "$work/models/stub-model.gguf"

# A server that never comes up: its configuration fails, the next one with more on the card is not tried.
spec "$work/never.json" '["python3", "-I", "-c", "import time; time.sleep(600)"]' '[30, 26]' 3600
probe "$work/never.json" "$work/out4" >"$work/run4.txt" 2>&1
if python3 -I - "$work/out4" <<'PY'
import json, os, sys
m = json.load(open(os.path.join(sys.argv[1], "manifest.json")))
c = m["configs"]
assert c[0]["config"] == "mmap-cpu-moe-30" and c[0]["failed"], c
assert c[1]["config"] == "mmap-cpu-moe-26" and c[1]["skipped"] and not c[1].get("failed"), c
assert os.path.exists(os.path.join(sys.argv[1], "mmap-cpu-moe-30.server.log"))
PY
then pass "a server that never comes up fails, keeps its log, and the configuration with more on the card is skipped"; else fail "a server that never came up was not handled: $(tail -3 "$work/run4.txt")"; fi
if [ -z "$(docker ps -aq -f name=^memprobe-server$)" ]; then pass "no server is left running after a failed configuration"; else fail "a failed configuration left its server running"; fi

# A server that exits at once (on 24.11 a flag the server no longer knew):
# the wait ends when it exits, not at the timeout, and says how it ended.
spec "$work/exits.json" '["python3", "-I", "-c", "import sys; sys.exit(3)"]' '[30]' 3600
probe "$work/exits.json" "$work/out6" >"$work/run6.txt" 2>&1
if python3 -I - "$work/out6" <<'PY'
import json, os, sys
c = json.load(open(os.path.join(sys.argv[1], "manifest.json")))["configs"]
assert "exited with code 3" in (c[0].get("failed") or ""), c
assert c[0]["time_to_ready_s"] < 15, c
PY
then pass "a server that exits at once ends its wait at once, with its exit code"; else fail "a server that exited was waited for: $(tail -3 "$work/run6.txt")"; fi
if [ -z "$(docker ps -aq -f name=^memprobe-server)" ]; then pass "no server or health check is left after a server that exited"; else fail "a container was left after a server that exited"; fi

# A budget that would not hold a configuration starts none after the first.
spec "$work/budget.json" "$STUB" '[30, 26, 22]' 5
probe "$work/budget.json" "$work/out5" >"$work/run5.txt" 2>&1
if python3 -I - "$work/out5" <<'PY'
import json, os, sys
c = json.load(open(os.path.join(sys.argv[1], "manifest.json")))["configs"]
assert not c[0].get("skipped"), c
assert all("time budget" in (x.get("skipped") or "") for x in c[1:]), c
PY
then pass "a configuration the time budget would not hold is not started"; else fail "the time budget was not kept: $(tail -3 "$work/run5.txt")"; fi

exit "$failed"
