#!/usr/bin/env python3
"""recompute.py - every published number, computed again from the records of
each call.

    recompute.py check OUT.json CALLS.jsonl   OUT.json must follow from CALLS.jsonl
    recompute.py table DIR                    one table from every series under DIR

A series measured on a workstation is not signed by CI. What CI can do is
take the record of every call (loadgen/calls.py) and compute each level's
aggregates again, with the formulas of the flagship's scripts/capacity.py,
and fail when the result differs from what the series reported in the last
digit. This proves the numbers follow from the records. It cannot prove the
records are true; that is why the README says where each was measured, and
why CI measures the CPU row itself with the same load generator every day.

Checked for each level: the number of calls, of failed calls, calls a minute,
p50, p95, output tokens a second and the mean prompt; and that the records
are whole: a start, one level record per level in the order asked for, the
calls that level counted and no others, an end.
"""
import glob
import json
import os
import statistics
import sys


def pct(xs, q):
    # The same index capacity.py takes, so the same call is the p95 here.
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else None


def levels_from(calls_path):
    """[(concurrency, wall_s, [call records])] from a CALLS.jsonl, or an error."""
    records = [json.loads(l) for l in open(calls_path, encoding="utf-8") if l.strip()]
    if not records or records[0].get("type") != "start":
        raise ValueError("the records do not begin with the series' start")
    asked = records[0]["levels"]
    pending, out, ended = [], [], False
    for r in records[1:]:
        if ended:
            raise ValueError("records follow the series' end")
        if r["type"] == "end":
            ended = True
        elif r["type"] == "call":
            if r["level"] is not None:
                pending.append(r)
        elif r["type"] == "level":
            c = r["concurrency"]
            mine = [p for p in pending if p["level"] == c]
            if len(mine) != len(pending):
                raise ValueError("calls of another level are recorded inside level %d" % c)
            if len(mine) != r["calls"]:
                raise ValueError("level %d counted %d calls and %d are recorded" % (c, r["calls"], len(mine)))
            out.append((c, r["wall_s"], mine))
            pending = []
        else:
            raise ValueError("a record of unknown type %r" % r.get("type"))
    if not ended:
        raise ValueError("the records do not end: the series stopped before it finished")
    if pending:
        raise ValueError("%d timed calls are recorded after the last level" % len(pending))
    if [c for c, _, _ in out] != asked:
        raise ValueError("levels recorded %s, asked for %s" % ([c for c, _, _ in out], asked))
    return out


def aggregate(c, wall, done):
    """One level as capacity.py reports it, from its calls."""
    n = len(done)
    ok = [d for d in done if d["ok"]]
    lat = [d["s"] for d in ok]
    return {"concurrency": c, "calls": n, "failed": n - len(ok), "wall_s": round(wall, 1),
            "calls_per_min": round(len(ok) / wall * 60, 1) if wall else None,
            "p50_s": round(statistics.median(lat), 2) if lat else None,
            "p95_s": round(pct(lat, 0.95), 2) if lat else None,
            "out_tokens_per_s": round(sum(d["completion"] or 0 for d in ok) / wall, 1) if wall else None,
            "prompt_tokens_mean": round(statistics.mean(d["prompt"] for d in ok if d["prompt"]), 0)
            if any(d["prompt"] for d in ok) else None}


def check(out_path, calls_path):
    reported = json.load(open(out_path, encoding="utf-8"))
    try:
        levels = levels_from(calls_path)
    except (ValueError, KeyError) as e:
        print("FAIL  the call records of %s are not whole: %s" % (os.path.basename(calls_path), e))
        return 1
    if len(levels) != len(reported["levels"]):
        print("FAIL  %d levels reported, %d recorded" % (len(reported["levels"]), len(levels)))
        return 1
    bad = 0
    for (c, wall, done), rep in zip(levels, reported["levels"]):
        again = aggregate(c, wall, done)
        diff = {k: (rep.get(k), v) for k, v in again.items() if rep.get(k) != v}
        if diff:
            bad += 1
            print("FAIL  concurrency %d: reported and recomputed differ: %s" % (
                c, ", ".join("%s %s vs %s" % (k, a, b) for k, (a, b) in sorted(diff.items()))))
        else:
            print("PASS  concurrency %d: %s calls a minute, p50 %s s, p95 %s s, %d of %d failed, recomputed from %d call records"
                  % (c, again["calls_per_min"], again["p50_s"], again["p95_s"], again["failed"], again["calls"], len(done)))
    return 1 if bad else 0


def table(directory):
    rows = []
    for out in sorted(glob.glob(os.path.join(directory, "**", "capacity.json"), recursive=True)):
        calls = os.path.join(os.path.dirname(out), "calls.jsonl")
        r = json.load(open(out, encoding="utf-8"))
        if check(out, calls) != 0:
            sys.exit("%s does not follow from its call records" % out)
        s = r["server"]
        for lv in r["levels"]:
            rows.append((s["MODEL"], s.get("ACCELERATOR") or "CPU", int(s["SLOTS"]), int(s["THREADS"]), lv))
    rows.sort(key=lambda x: (x[0], x[1], x[2], x[4]["concurrency"]))
    print("| Model | On | Slots x threads | Concurrency | Calls a minute | p50 | p95 | Output tokens/s | Failed |")
    print("|---|---|---|---|---|---|---|---|---|")
    for model, on, slots, threads, lv in rows:
        print("| %s | %s | %d x %d | %d | %s | %s s | %s s | %s | %d of %d |" % (
            model, on, slots, threads, lv["concurrency"], lv["calls_per_min"], lv["p50_s"], lv["p95_s"],
            lv["out_tokens_per_s"], lv["failed"], lv["calls"]))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 3 and sys.argv[1] == "table":
        table(sys.argv[2])
        sys.exit(0)
    sys.exit(__doc__)
