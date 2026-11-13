#!/usr/bin/env bash
# series.sh - workstation/run_series.py, run on a plan whose server is
# tests/stub_server.py in a container, so every step of a unit runs with no
# GPU and no model: the internal network, the server's time to ready, the
# flagship's capacity.py through loadgen/calls.py from a client container, the
# recomputation, the manifest, the unit's SHA256SUMS. Then:
#   - a unit left half done is found, recorded as interrupted and redone, and
#     a unit done before is not run again;
#   - a done unit that is no longer what it was (a file emptied, a file
#     changed with its sums rewritten to match, a file added) is set aside and
#     redone, and nothing is deleted;
#   - a model file that is not the one its lock pins stops the series before
#     any unit;
#   - a unit whose server never becomes ready fails and leaves no server
#     running;
#   - a unit whose power limit the environment cannot read runs only on the
#     host's word, and says so;
#   - a series whose card's PCIe link width changed does not go on;
#   - a card nvidia-smi does not report in full, or a GPU plan with no
#     nvidia-smi at all, stops the series; a power limit with no answer
#     is as unreadable as [N/A];
#   - a unit whose server's log cannot be kept does not pass;
#   - a unit with a file in it that it does not make fails;
#   - a flagship dir that is not its archive unpacked (a file emptied, a file
#     added) stops the series before any unit;
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
   && grep -q '"u2": "done"' <<<"$inv" && [ -f "$work/out/units/u2/done" ] && [ ! -e "$work/out/units/u2.partial" ] \
   && compgen -G "$work/out/units/u2.interrupted-*" >/dev/null; then
  pass "a unit cut short is recorded as interrupted, kept aside and redone whole; a unit done before is not run again"
else
  fail "resuming a series: $inv"
fi

# A unit done once whose files no longer match its sums (a power cut that
# left a file empty): recorded as damaged and measured again.
damage() {
  local what="$1" how="$2"
  ( cd "$work/out/units/u1" && eval "$how" )
  SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out" >"$work/run2a.txt" 2>&1
  inv="$(last "$work/out")"
  if grep -q '"damaged_units": \["u1"\]' <<<"$inv" && grep -q '"u1": "done"' <<<"$inv" \
     && [ -s "$work/out/units/u1/capacity.json" ] && [ -f "$work/out/units/u1/done" ] \
     && [ "$(compgen -G "$work/out/units/u1.damaged-*" | wc -l)" -ge 1 ]; then
    pass "a done unit with $what is recorded as damaged, kept aside, and measured again"
  else
    fail "a done unit with $what: $inv"
  fi
  sleep 1  # the next set-aside name has its own second
}
damage "a file emptied" ': >capacity.json'
damage "a file changed and its sums rewritten to match" 'echo "{}" >capacity.json && sha256sum capacity.json >/dev/null 2>&1; python3 -I -c "
import hashlib, os
names = sorted(n for n in os.listdir(\".\") if n not in (\"SHA256SUMS\", \"done\"))
open(\"SHA256SUMS\", \"w\").write(\"\".join(\"%s  %s\\n\" % (hashlib.sha256(open(n, \"rb\").read()).hexdigest(), n) for n in names))"'
damage "a file added that its sums do not name" 'echo extra >extra.txt'

# An invocation that is refused touches no unit, a unit cut short included.
mkdir -p "$work/out/units/u9.partial"

# The conditions changed since the series began: another series, not this one.
python3 -I - "$work/out/series.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["invocations"][0]["preflight"]["conditions"]["driver_version"] = "0.0"
json.dump(s, open(sys.argv[1], "w"))
PY
if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" series "$work/out" >"$work/run2b.txt" 2>&1; then
  fail "a series went on although its conditions had changed since it began"
elif grep -q "conditions changed since it began (driver_version)" "$work/run2b.txt" && [ -d "$work/out/units/u9.partial" ]; then
  pass "a series whose conditions changed since it began does not go on, names the change, and touches no unit"
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
# One reading for each field asked, in its order, as nvidia-smi gives them.
# FAKE_WIDTH is the PCIe link's width, FAKE_SHORT leaves the last field out,
# FAKE_NO_LIMIT fails a query of the power limit alone.
case "$*" in
  *-lms*) echo "timestamp, power.draw [W]"; exec sleep 3600 ;;
esac
q=""
for a in "$@"; do case "$a" in --query-gpu=*) q="${a#--query-gpu=}" ;; esac; done
[ "$q" = power.limit ] && [ -n "${FAKE_NO_LIMIT:-}" ] && exit 9
out=""
IFS=,
for f in $q; do
  case "$f" in
    name) v="Fake GPU" ;;
    driver_version) v="0.0" ;;
    power.limit) v="[N/A]" ;;
    pcie.link.width.current) v="${FAKE_WIDTH:-8}" ;;
    *) v="1" ;;
  esac
  out="${out:+$out, }$v"
done
[ -n "${FAKE_SHORT:-}" ] && out="${out%, *}"
echo "$out"
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
# The card's PCIe link wider than when the series began (a drive moved off
# the lanes the slot shares with it): another series, not this one.
export FAKE_WIDTH=16
limited "$work/out5" --power-limit-w 450 >"$work/run7b.txt" 2>&1
unset FAKE_WIDTH
if grep -q 'conditions changed since it began (pcie_link_width)' "$work/run7b.txt"; then
  pass "a series whose card's PCIe link width changed since it began does not go on, and names it"
else
  fail "a changed PCIe link width: $(tail -2 "$work/run7b.txt" | tr '\n' ' ')"
fi
# nvidia-smi here, and not answering every field the preflight asks: the
# card's conditions could not be compared with the next invocation's, so the
# series does not start.
export FAKE_SHORT=1
limited "$work/out8" --power-limit-w 450 >"$work/run7c.txt" 2>&1
unset FAKE_SHORT
if grep -q "REFUSED  nvidia-smi did not report all of the card's" "$work/run7c.txt" && [ -z "$(ls "$work/out8/units")" ]; then
  pass "nvidia-smi that does not answer every field of the card stops the series before any unit"
else
  fail "an unanswered field of the card: $(tail -2 "$work/run7c.txt" | tr '\n' ' ')"
fi
# A power limit with no answer at all is as unreadable as [N/A]: the unit runs
# only on the host's word.
export FAKE_NO_LIMIT=1
limited "$work/out9" >"$work/run7d.txt" 2>&1
unset FAKE_NO_LIMIT
if grep -q 'SKIP  u450: skipped: the power limit reads None' "$work/run7d.txt" && [ ! -e "$work/out9/units/u450" ]; then
  pass "a unit whose power limit gets no answer at all is skipped when the host does not say it set it"
else
  fail "a power limit with no answer: $(tail -2 "$work/run7d.txt" | tr '\n' ' ')"
fi
# A plan whose server runs on the GPU, where there is no nvidia-smi to read
# the card: nothing to hold the series' card to, so it does not start.
python3 -I - "$work/plan.json" "$work/plan-gpu.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["server"]["gpu_flags"] = ["--device", "nvidia.com/gpu=all"]
json.dump(plan, open(sys.argv[2], "w"))
PY
if command -v nvidia-smi >/dev/null 2>&1; then
  printf 'SKIP  %s\n' "a GPU plan with no nvidia-smi: this machine has one"
elif SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" MODELS_LOCK="$work/models.lock" \
     python3 -I "$ROOT/workstation/run_series.py" "$work/plan-gpu.json" "$work/out10" >"$work/run7e.txt" 2>&1; then
  fail "a series whose server runs on the GPU started with no nvidia-smi to read the card"
elif grep -q "REFUSED  the plan's server runs on the GPU, and nvidia-smi is not here" "$work/run7e.txt" && [ -z "$(ls "$work/out10/units")" ]; then
  pass "a series whose server runs on the GPU does not start without nvidia-smi to read the card"
else
  fail "a GPU plan with no nvidia-smi: $(tail -2 "$work/run7e.txt" | tr '\n' ' ')"
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

# A file the unit does not make, with a newline in its name, put in the
# unit's directory by its client (here, by a docker that adds it when the
# client starts): the unit fails, and no forged line reaches its sums.
mkdir -p "$work/bin3"
cat >"$work/bin3/docker" <<SH
#!/bin/sh
for a in "\$@"; do case "\$a" in *:/out) d="\${a%:/out}"; printf x >"\$d/forged
line" ;; esac; done
exec "$real_docker" "\$@"
SH
chmod +x "$work/bin3/docker"
if PATH="$work/bin3:$PATH" SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" MODELS_LOCK="$work/models.lock" \
     python3 -I "$ROOT/workstation/run_series.py" "$work/plan-nolog.json" "$work/out7" >"$work/run9.txt" 2>&1; then
  fail "a unit passed with a file in it that it does not make"
elif grep -q "FAIL  u-nolog: failed: the unit holds 1 file(s) it does not make" "$work/run9.txt" && [ ! -e "$work/out7/units/u-nolog/done" ]; then
  pass "a unit with a file in it that it does not make (a newline in its name) fails, and is not marked done"
else
  fail "a stray file in a unit: $(tail -2 "$work/run9.txt" | tr '\n' ' ')"
fi

# A flagship dir that is not its archive unpacked, though the archive is the
# pinned one: capacity.py left empty by a stop before the disk caught up (what
# the first measured block met), and a module the release does not hold, which
# capacity.py would import instead of the standard library's. Either stops the
# series before any unit.
unpacked() {
  local what="$1" how="$2" bad="$work/flagship-$3"
  /bin/cp -R "$FLAGSHIP" "$bad"
  ( cd "$bad" && eval "$how" )
  python3 -I - "$work/plan.json" "$work/plan-$3.json" "$bad" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["flagship"]["dir"] = sys.argv[3]
json.dump(plan, open(sys.argv[2], "w"))
PY
  if SERIES_SKIP_ISOLATION_CHECK="a test machine is not the environment" MODELS_LOCK="$work/models.lock" \
       python3 -I "$ROOT/workstation/run_series.py" "$work/plan-$3.json" "$work/out-$3" >"$work/run-$3.txt" 2>&1; then
    fail "a series ran on a flagship dir with $what"
  elif grep -q "is not its archive unpacked" "$work/run-$3.txt" && [ -z "$(ls "$work/out-$3/units")" ]; then
    pass "a flagship dir with $what stops the series before any unit"
  else
    fail "a flagship dir with $what: $(tail -2 "$work/run-$3.txt" | tr '\n' ' ')"
  fi
}
unpacked "capacity.py left empty" ': >scripts/capacity.py' empty
unpacked "a module beside capacity.py that the release does not hold" 'printf "x = 1\n" >scripts/json.py' extra

# An environment that is not closed: the isolation check runs and fails here.
if series "$work/out3" >"$work/run4.txt" 2>&1; then
  fail "a series started although its isolation check had not passed"
elif grep -q 'the isolation check failed' "$work/run4.txt" && [ -z "$(ls "$work/out3/units")" ]; then
  pass "a series whose isolation check fails does not start"
else
  fail "the series did not start, for another reason: $(tail -2 "$work/run4.txt" | tr '\n' ' ')"
fi
exit "$failed"
