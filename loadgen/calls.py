#!/usr/bin/env python3
"""calls.py - the flagship's scripts/capacity.py, unchanged, with every call it
makes written down.

    calls.py run URL OUT.json LEVELS CALLS.jsonl

capacity.py reports each level of concurrency as aggregates only: calls a
minute, p50, p95, output tokens a second. A number measured away from CI is
worth publishing only if anyone can compute it again from what was recorded,
so this runs capacity.py exactly as the flagship's release carries it and
records, for every call, what capacity.py itself was told: the seconds, whether
it answered, and the tokens. scripts/recompute.py then computes every
aggregate again from those records and has to agree with OUT.json.

Nothing in capacity.py is changed. Two of its functions are wrapped, and each
wrapper hands back exactly what the original returned:

  one()        each call, kept with the level it belongs to (none for the
               warm-up calls, which capacity.py does not time), its seed, and
               its start on the wall clock, to set beside the GPU's power
               samples;
  one_level()  each timed level, with its wall time as capacity.py measured
               it, unrounded, since calls a minute is computed from it.

NOTHING IS WRITTEN WHILE A LEVEL IS TIMED. A level's calls are kept in memory
and written, with the level's record, after one_level() has returned; the
warm-up calls before it are written as it starts. A write or an fsync inside
the timed window would be part of every call's time. A series on a workstation
has to survive the power going off, and a level cut short is measured again
whole (a rate is read from one unbroken window), so nothing is lost by
holding one level's records until it ends; each batch is fsynced.

FLAGSHIP names the directory the flagship's release is unpacked in, verified
by scripts/sources.sh.
"""
import json
import os
import sys
import threading
import time

FLAGSHIP = os.environ.get("FLAGSHIP")
if not FLAGSHIP or not os.path.isfile(os.path.join(FLAGSHIP, "scripts", "capacity.py")):
    sys.exit("FLAGSHIP must name the unpacked flagship release (scripts/sources.sh path flagship)")
sys.path.insert(0, os.path.join(FLAGSHIP, "scripts"))
import capacity  # noqa: E402  the release's own file, from the path above

_lock = threading.Lock()
_out = None
_kept = []
_n = 0
# The level being timed. one_level() starts its workers after this is set and
# joins them before it is cleared, so every call it times carries its level,
# and the warm-up calls capacity.run() makes outside it carry none.
_level = None


def _write(records):
    """Append records and put them on disk. Never called inside a timed level."""
    _out.write("".join(json.dumps(r, sort_keys=True) + "\n" for r in records))
    _out.flush()
    os.fsync(_out.fileno())


def _flush():
    global _kept
    with _lock:
        records, _kept = _kept, []
    if records:
        _write(sorted(records, key=lambda r: r["i"]))


def _one(url, body, seed, _orig=capacity.one):
    global _n
    level, started = _level, time.time()
    r = _orig(url, body, seed)
    with _lock:
        _n += 1
        _kept.append({"type": "call", "i": _n, "level": level, "seed": seed, "start_unix": round(started, 3),
                      "s": r["s"], "ok": r["ok"], "prompt": r.get("prompt"), "completion": r.get("completion"),
                      "error": r.get("error")})
    return r


def _one_level(url, bodies, c, seed, min_s, _orig=capacity.one_level):
    global _level
    _flush()  # the warm-up calls before this level, written before it is timed
    _level = c
    try:
        done, wall = _orig(url, bodies, c, seed, min_s)
    finally:
        _level = None
    _flush()
    _write([{"type": "level", "concurrency": c, "calls": len(done), "wall_s": wall, "min_seconds": min_s}])
    return done, wall


def main(argv):
    global _out
    if len(argv) != 5 or argv[0] != "run":
        sys.exit(__doc__)
    url, out, levels, calls = argv[1], argv[2], [int(x) for x in argv[3].split(",")], argv[4]
    _out = open(calls, "a", encoding="utf-8")
    _write([{"type": "start", "levels": levels, "min_seconds": float(os.environ.get("MIN_SECONDS") or 0),
             "server": {k: os.environ.get(k) for k in ("MODEL", "SLOTS", "THREADS", "CONTEXT", "RUNNER_CPUS", "ACCELERATOR")}}])
    capacity.one = _one
    capacity.one_level = _one_level
    capacity.run(url, out, levels)
    _flush()
    _write([{"type": "end"}])
    _out.close()


if __name__ == "__main__":
    main(sys.argv[1:])
