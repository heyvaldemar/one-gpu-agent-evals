#!/usr/bin/env bash
# recompute.sh - the load generator and the recomputation, against a stub
# server, in seconds.
#
# loadgen/calls.py runs the flagship's capacity.py, as released, against
# tests/stub_server.py (which answers at once and fails every seventh call),
# and scripts/recompute.py must find every reported aggregate in the call
# records. Then the records are damaged in the ways a recomputation exists to
# notice, one copy each, and every copy must be refused:
#   - a series that stopped before its end;
#   - one call's time changed;
#   - one call dropped from its level;
#   - a failed call recorded as answered.
# tests/recompute-plants.tsv breaks calls.py and recompute.py in turn; this
# test must notice each.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAGSHIP="${FLAGSHIP:-$("$ROOT/scripts/sources.sh" path flagship)}"
export FLAGSHIP
work="$(mktemp -d)"
trap 'kill "$stub" 2>/dev/null; rm -rf "$work"' EXIT
failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I "$ROOT/tests/stub_server.py" "$port" &
stub=$!
disown "$stub"
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 0.1; done

MODEL=stub SLOTS=1 THREADS=1 ACCELERATOR=stub MIN_SECONDS=0 \
  python3 -I "$ROOT/loadgen/calls.py" run "http://127.0.0.1:$port" "$work/capacity.json" 1,2,4 "$work/calls.jsonl" >/dev/null \
  || { fail "the load generator did not finish against the stub"; exit 1; }

if python3 -I "$ROOT/scripts/recompute.py" check "$work/capacity.json" "$work/calls.jsonl" >"$work/intact.txt"; then
  pass "every level's aggregates follow from the call records ($(grep -c '^PASS' "$work/intact.txt") levels)"
else
  fail "the intact series does not follow from its own records: $(grep '^FAIL' "$work/intact.txt" | head -1)"
fi
if python3 -I - "$work/calls.jsonl" <<'PY'
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
calls = [r for r in rs if r["type"] == "call" and r["level"] is not None]
sys.exit(0 if calls and any(not r["ok"] for r in calls) and any(r["ok"] for r in calls) else 1)
PY
then
  pass "the records hold answered and failed calls, so both are recomputed"
else
  fail "the stub's records hold no failed call, or no answered one"
fi

damaged() {
  local what="$1" code="$2"
  python3 -I -c "$code" "$work/calls.jsonl" "$work/damaged.jsonl"
  if python3 -I "$ROOT/scripts/recompute.py" check "$work/capacity.json" "$work/damaged.jsonl" >/dev/null; then
    fail "the recomputation accepts $what"
  else
    pass "the recomputation refuses $what"
  fi
}
damaged "a series that stopped before its end" '
import sys; ls = open(sys.argv[1]).readlines(); open(sys.argv[2], "w").writelines(ls[:-1])'
damaged "a series where the time of one call was changed" '
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
c = next(r for r in rs if r["type"] == "call" and r["level"] == 2 and r["ok"])
c["s"] = c["s"] * 3 + 0.5
open(sys.argv[2], "w").writelines(json.dumps(r) + "\n" for r in rs)'
damaged "a series with one call dropped from its level" '
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
i = next(k for k, r in enumerate(rs) if r["type"] == "call" and r["level"] == 4)
open(sys.argv[2], "w").writelines(json.dumps(r) + "\n" for k, r in enumerate(rs) if k != i)'
damaged "a series with a failed call recorded as answered" '
import json, sys
rs = [json.loads(l) for l in open(sys.argv[1])]
c = next(r for r in rs if r["type"] == "call" and r["level"] is not None and not r["ok"])
c.update(ok=True, error=None, prompt=500, completion=20)
open(sys.argv[2], "w").writelines(json.dumps(r) + "\n" for r in rs)'

# Line 1's table (ADR 1): results/line1/TABLE.md is what recompute.py set
# computes from the three series under it, every unit whole and recomputed
# from its calls; a unit with a file its SHA256SUMS does not list, or a
# record changed after it was hashed, stops the table.
if python3 -I "$ROOT/scripts/recompute.py" set "$ROOT/results/line1" 2>"$work/set.err" >"$work/table.md" \
    && cmp -s "$work/table.md" "$ROOT/results/line1/TABLE.md"; then
  pass "results/line1/TABLE.md is the table recompute.py computes from line1-2, line1-3 and line1-4"
else
  fail "results/line1/TABLE.md is not the table its series give: $(tail -1 "$work/set.err")$(diff "$work/table.md" "$ROOT/results/line1/TABLE.md" | head -4)"
fi
# Every figure the README gives for line 1 is computed here from TABLE.md,
# and must be in the README as written.
if python3 -I - "$ROOT/results/line1/TABLE.md" "$ROOT/README.md" >"$work/readme.txt" 2>&1 <<'PY2'
import re, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\| (\S+) \| (\d+) W \| (\S+) \| (\d+) \| ([\d.]+) \(([\d.]+)-([\d.]+)\) \| [\d.]+ s \| (\d+) of (\d+) \|", line)
    if m:
        rows.append({"model": m[1], "w": int(m[2]), "cpus": m[3], "c": int(m[4]), "med": float(m[5]),
                     "lo": float(m[6]), "hi": float(m[7]), "failed": int(m[8]), "calls": int(m[9])})
def cell(model, w, cpus, c):
    return next(r for r in rows if (r["model"], r["w"], r["cpus"], r["c"]) == (model, w, cpus, c))
def pct(a, b):
    return "%.1f%%" % (abs(a / b - 1) * 100)
def most(model, f):
    return max(f(r) for r in rows if r["model"] == model and f(r) is not None)
def other(r, **k):
    try:
        return cell(r["model"], k.get("w", r["w"]), k.get("cpus", r["cpus"]), r["c"])
    except StopIteration:
        return None
b8, b1 = "granite-4.1-8b", "granite-4.0-1b"
a, z = cell(b8, 450, "all", 8), cell(b8, 350, "all", 8)
power = lambda r: abs(r["med"] / other(r, w=450)["med"] - 1) * 100 if r["w"] == 350 else None
cpus = lambda r: abs(r["med"] / other(r, cpus="all")["med"] - 1) * 100 if r["cpus"] != "all" else None
spread = lambda r: (r["hi"] / r["lo"] - 1) * 100
said = {
    "every call": "None of the {:,} calls failed".format(sum(r["calls"] for r in rows)) if not sum(r["failed"] for r in rows) else "a failed call",
    "8B at 450 W, c=8": "%.1f (%.1f-%.1f) calls a minute at 450 W" % (a["med"], a["lo"], a["hi"]),
    "8B at 350 W, c=8": "%.1f (%.1f-%.1f) at 350 W" % (z["med"], z["lo"], z["hi"]),
    "8B power, c=8": "costs %s there" % pct(z["med"], a["med"]),
    "8B power, any c": "at most %.1f%% at any concurrency" % most(b8, power),
    "8B CPUs": "stay within %.1f%%" % most(b8, cpus),
    "8B spread": "inside the %.1f%% its series spread" % most(b8, spread),
    "1B spread": "spread up to %.1f%% apart" % most(b1, spread),
    "1B differences": "up to %.1f%%, cannot" % max(most(b1, power), most(b1, cpus)),
}
readme = open(sys.argv[2], encoding="utf-8").read()
missing = [k + ": " + v for k, v in said.items() if v not in readme]
print("; ".join(missing) if missing else "%d figures" % len(said))
sys.exit(1 if missing else 0)
PY2
then
  pass "every figure the README gives for line 1 is the one TABLE.md gives: $(cat "$work/readme.txt")"
else
  fail "the README's line 1 figures are not the table's: $(cat "$work/readme.txt")"
fi
cp -R "$ROOT/results/line1" "$work/set-extra"
u="$(find "$work/set-extra/line1-3/units" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
printf 'x\n' >"$u/extra.txt"
if python3 -I "$ROOT/scripts/recompute.py" set "$work/set-extra" >/dev/null 2>"$work/set-extra.err"; then
  fail "a unit with a file its SHA256SUMS does not list went into the table"
else
  pass "a unit with a file its SHA256SUMS does not list stops the table: $(tail -1 "$work/set-extra.err")"
fi
cp -R "$ROOT/results/line1" "$work/set-changed"
u="$(find "$work/set-changed/line1-4/units" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
printf 'x\n' >>"$u/server.log"  # a file the recomputation does not read: only its hash holds it
if python3 -I "$ROOT/scripts/recompute.py" set "$work/set-changed" >/dev/null 2>"$work/set-changed.err"; then
  fail "a unit changed after it was hashed went into the table"
else
  pass "a unit changed after it was hashed stops the table: $(tail -1 "$work/set-changed.err")"
fi
exit "$failed"
