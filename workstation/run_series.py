#!/usr/bin/env python3
"""run_series.py PLAN.json OUT [--power-limit-w W] [--only UNIT] - one series
of line 1 in the closed environment (ADR 3), unit by unit, resumable.

A plan is a list of units: one model, one server and its arguments, one
power limit, the levels of concurrency. A unit is the piece that survives a
power cut: it is either done (OUT/units/<id>/ with its SHA256SUMS and a
`done` marker) or it is measured again whole, since a rate is read from one
unbroken window. A unit left half done by an interruption is found as
OUT/units/<id>.partial, recorded in OUT/series.json, set aside, and redone.
Every file of a unit is on disk before the unit is marked done, and the hash
of its SHA256SUMS goes into OUT/series.json then; a done unit that is no
longer what it was (a file changed, added or gone, or its sums rewritten) is
recorded as damaged, set aside, and redone. Nothing is deleted, and an
invocation that is refused touches no unit.

Before any unit, the invocation must pass its preflight, and each part of it
goes into OUT/series.json:
  - the isolation check (workstation/isolation_check.py series PROBES), as
    root, passed: the series does not start in an environment that is open;
  - every file of the carry-in list is the file its sha256 says;
  - the flagship's release archive and every model file are the ones the plan
    and models.lock pin (MODELS_LOCK names another lock, for the test only).
The power limit is the host's to set. With --power-limit-w, only the units
for that limit run, and only if nvidia-smi reports it.

A series is measured under one set of conditions the environment can see
(its memory, the driver, the kernel, the card): an invocation whose
conditions differ from the series' first is refused, and the units it would
run belong in a new OUT.

For each unit: the server's container on an internal Docker network, its
time to ready from start, nvidia-smi sampled every 500 ms for the whole
unit, the flagship's capacity.py through loadgen/calls.py from a client
container beside it, the server's log, the recomputation of every level from
its records, and a manifest. Nothing in OUT names the machine: the manifest
holds versions, digests, hashes and times in UTC, and the series is
published only after review (ADR 3).
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NET = "series-net"
SERVER = "series-server"
SAMPLE_FIELDS = ("timestamp,power.draw,power.limit,clocks.sm,clocks.mem,temperature.gpu,utilization.gpu,"
                 "memory.used,memory.total,pcie.link.gen.current,pcie.link.width.current,"
                 "pcie.link.gen.max,pcie.link.width.max")


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def fsync_tree(path):
    """Every file in a unit's directory, and the directory, on disk. A power cut
    after a unit is marked done must not leave it done and empty."""
    for name in os.listdir(path):
        full = os.path.join(path, name)
        if os.path.isfile(full):
            fd = os.open(full, os.O_RDONLY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def holds(udir, sums_sha256):
    """True when a done unit is still what it was when it was marked done: its
    SHA256SUMS is the file whose hash the series recorded then, it names every
    file in the unit and nothing outside it, and every file is the file it says."""
    try:
        path = os.path.join(udir, "SHA256SUMS")
        if sums_sha256 is None or sha256(path) != sums_sha256:
            return False
        listed = {}
        for line in open(path, encoding="utf-8"):
            h, n = line.rstrip("\n").split("  ", 1)
            if os.path.isabs(n) or os.sep in n or n in (".", ".."):
                return False
            listed[n] = h
        if set(listed) != set(os.listdir(udir)) - {"SHA256SUMS", "done"}:
            return False
        return all(sha256(os.path.join(udir, n)) == h for n, h in listed.items())
    except (OSError, ValueError):
        return False


def models_lock():
    out = {}
    for line in open(os.environ.get("MODELS_LOCK") or os.path.join(ROOT, "models.lock"), encoding="utf-8"):
        f = line.split()
        if f and not line.lstrip().startswith("#") and len(f) == 5:
            out[f[0]] = {"url": f[1], "sha256": f[2], "license": f[3], "image": f[4]}
    return out


def gpu_query(fields):
    if not shutil.which("nvidia-smi"):
        return None
    r = run(["nvidia-smi", "--query-gpu=" + fields, "--format=csv,noheader,nounits"])
    return [x.strip() for x in r.stdout.strip().split(",")] if r.returncode == 0 else None


def preflight(plan, series, skip_isolation):
    pre = {"at": utc()}
    if skip_isolation:
        pre["isolation"] = {"state": "not checked", "why": skip_isolation}
    else:
        probes = plan["probes"]
        out = os.path.join(series["dir"], "isolation-%s.json" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
        r = run([sys.executable, "-I", os.path.join(ROOT, "workstation", "isolation_check.py"), "series", probes, out])
        pre["isolation"] = {"state": "passed" if r.returncode == 0 else "failed", "record": os.path.basename(out),
                            "check_sha256": sha256(os.path.join(ROOT, "workstation", "isolation_check.py"))}
        if r.returncode != 0:
            return pre, "the isolation check failed: the series does not start in an open environment"
    carry = plan.get("carry_in")
    if carry:
        r = run(["sha256sum", "-c", "--quiet", os.path.basename(carry)], cwd=os.path.dirname(carry))
        pre["carry_in"] = {"list": os.path.basename(carry), "list_sha256": sha256(carry),
                           "state": "verified" if r.returncode == 0 else "failed"}
        if r.returncode != 0:
            return pre, "a carried-in file is not the one its sha256 says"
    archive = plan["flagship"]["archive"]
    got = sha256(archive)
    pre["flagship"] = {"tag": plan["flagship"]["tag"], "archive_sha256": got}
    if got != plan["flagship"]["sha256"]:
        return pre, "the flagship's archive is %s, the plan pins %s" % (got, plan["flagship"]["sha256"])
    if not os.path.isfile(os.path.join(plan["flagship"]["dir"], "scripts", "capacity.py")):
        return pre, "the flagship's release is not unpacked at %s" % plan["flagship"]["dir"]
    lock, seen = models_lock(), {}
    for unit in plan["units"]:
        name = unit["model"]
        if name in seen:
            continue
        if name not in lock:
            return pre, "models.lock has no line for %s" % name
        path = os.path.join(plan["models_dir"], name + ".gguf")
        got = sha256(path) if os.path.isfile(path) else None
        seen[name] = {"sha256": got, "pinned": lock[name]["sha256"], "license": lock[name]["license"]}
        if got != lock[name]["sha256"]:
            pre["models"] = seen
            return pre, "%s is %s, models.lock pins %s" % (name, got, lock[name]["sha256"])
    pre["models"] = seen
    pre["gpu"] = dict(zip(("name", "driver_version", "memory.used", "memory.total", "utilization.gpu", "power.limit"),
                          gpu_query("name,driver_version,memory.used,memory.total,utilization.gpu,power.limit") or []))
    pre["kernel"] = os.uname().release
    pre["docker"] = run(["docker", "version", "--format", "{{.Server.Version}}"]).stdout.strip()
    pre["conditions"] = conditions(pre)
    return pre, None


def conditions(pre):
    """What a series' numbers depend on and the environment can see: its own
    memory, the driver, the kernel, the card. A series is measured under one
    set of them; the host records its own (its memory and the memory's speed)."""
    mem = None
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemTotal:"):
                mem = int(line.split()[1])
    except OSError:
        pass
    return {"guest_memory_kib": mem, "kernel": pre.get("kernel"),
            "driver_version": pre.get("gpu", {}).get("driver_version"), "gpu": pre.get("gpu", {}).get("name")}


def number(text):
    """A reading of nvidia-smi as a number, or None when it says [N/A] or the
    like, as it can for the power limit inside a GPU-P guest; the host then
    records the limit it set."""
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def docker_rm(name):
    run(["docker", "rm", "-f", name])


def unit_run(plan, unit, udir):
    """One unit, with the GPU sampled from before the server starts to after it
    is gone, and the server's log kept and its container removed however the
    unit ends."""
    run(["docker", "network", "create", "--internal", NET])
    docker_rm(SERVER)
    sampler = None
    if shutil.which("nvidia-smi"):
        sampler = subprocess.Popen(["nvidia-smi", "--query-gpu=" + SAMPLE_FIELDS, "--format=csv,nounits", "-lms", "500"],
                                   stdout=open(os.path.join(udir, "gpu-samples.csv"), "w"), stderr=subprocess.DEVNULL)
    m = None
    try:
        m = _unit_run(plan, unit, udir)
        return m
    finally:
        # The server's log is evidence: it is kept whatever the unit's end, and
        # a unit that passed without it does not pass.
        logs = run(["docker", "logs", SERVER])
        with open(os.path.join(udir, "server.log"), "w") as f:
            f.write(logs.stdout + logs.stderr)
        if m is not None:
            m["server_log"] = "kept" if logs.returncode == 0 else "not kept: docker logs exited %d" % logs.returncode
            if logs.returncode != 0 and not m.get("failed"):
                m["failed"] = "the server's log could not be kept"
        docker_rm(SERVER)
        if sampler:
            sampler.terminate()
            sampler.wait()


def _unit_run(plan, unit, udir):
    m = {"unit": unit, "started": utc(), "images": plan["images"]}
    model_path = os.path.join(plan["models_dir"], unit["model"] + ".gguf")
    server = plan["server"]
    cpus = unit.get("server_cpus", "all")
    cmd = ["docker", "run", "-d", "--name", SERVER, "--network", NET, "--read-only", "--tmpfs", "/tmp",
           "--memory", server.get("memory", "12g"), "-v", "%s:/models/model.gguf:ro" % model_path]
    cmd += server.get("gpu_flags", [])
    if cpus != "all":
        cmd += ["--cpuset-cpus", cpus]
    for src, dst in server.get("mounts", []):
        cmd += ["-v", "%s:%s:ro" % (os.path.join(ROOT, src) if not src.startswith("/") else src, dst)]
    args = [a.replace("@MODEL@", unit["model"]) for a in server["args"]]
    cmd += [plan["images"]["server"]] + args
    t0 = time.time()
    r = run(cmd)
    if r.returncode != 0:
        m["failed"] = "the server's container did not start: " + r.stderr.strip()[-300:]
        return m
    m["server_args"] = args
    m["server_cpus"] = cpus
    # Time to ready: the server's own /health, asked from a container on the
    # same network every half second.
    wait = int(server.get("ready_timeout_s", 900))
    probe = ("import time, urllib.request\n"
             "t = time.time()\n"
             "while time.time() - t < %d:\n"
             "    try:\n"
             "        urllib.request.urlopen('http://%s:8080/health', timeout=2); print('ready'); break\n"
             "    except Exception: time.sleep(0.5)\n") % (wait, SERVER)
    r = run(["docker", "run", "--rm", "--network", NET, plan["images"]["client"], "python3", "-I", "-c", probe])
    m["time_to_ready_s"] = round(time.time() - t0, 1)
    if "ready" not in r.stdout:
        m["failed"] = "the server was not ready in %d s" % wait
        return m
    client = ["docker", "run", "--rm", "--network", NET, "--cpus", "1", "--memory", "256m", "--read-only",
              "--tmpfs", "/tmp", "-v", "%s:/work/flagship:ro" % plan["flagship"]["dir"],
              "-v", "%s:/work/loadgen:ro" % os.path.join(ROOT, "loadgen"), "-v", "%s:/out" % udir,
              "-e", "FLAGSHIP=/work/flagship", "-e", "MODEL=%s" % unit["model"],
              "-e", "SLOTS=%s" % unit.get("slots", 8), "-e", "THREADS=%s" % unit.get("threads", 0),
              "-e", "ACCELERATOR=%s" % plan["accelerator"], "-e", "MIN_SECONDS=%s" % unit.get("min_seconds", 30),
              plan["images"]["client"], "python3", "-I", "/work/loadgen/calls.py", "run",
              "http://%s:8080" % SERVER, "/out/capacity.json", ",".join(map(str, unit["levels"])), "/out/calls.jsonl"]
    r = run(client)
    m["client_exit"] = r.returncode
    with open(os.path.join(udir, "client.log"), "w") as f:
        f.write(r.stdout + r.stderr)
    if r.returncode != 0:
        m["failed"] = "the load generator did not finish"
        return m
    rc = run([sys.executable, "-I", os.path.join(ROOT, "scripts", "recompute.py"), "check",
              os.path.join(udir, "capacity.json"), os.path.join(udir, "calls.jsonl")],
             env=dict(os.environ, FLAGSHIP=plan["flagship"]["dir"]))
    with open(os.path.join(udir, "recompute.txt"), "w") as f:
        f.write(rc.stdout + rc.stderr)
    if rc.returncode != 0:
        m["failed"] = "the levels do not follow from their call records"
        return m
    start = json.loads(open(os.path.join(udir, "calls.jsonl")).readline())
    m["requests"], m["requests_sha256"] = start.get("requests"), start.get("requests_sha256")
    m["gpu"] = dict(zip(("name", "driver_version", "power.limit"), gpu_query("name,driver_version,power.limit") or []))
    m["ended"] = utc()
    return m


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    plan_path, out = argv[0], argv[1]
    opts = dict(zip(argv[2::2], argv[3::2]))
    plan = json.load(open(plan_path, encoding="utf-8"))
    os.makedirs(os.path.join(out, "units"), exist_ok=True)
    spath = os.path.join(out, "series.json")
    series = json.load(open(spath)) if os.path.exists(spath) else {"plan_sha256": sha256(plan_path), "invocations": []}
    if series["plan_sha256"] != sha256(plan_path):
        sys.exit("OUT holds a series of another plan: start a new OUT")
    series["dir"] = out
    inv = {"started": utc(), "power_limit_w": opts.get("--power-limit-w"), "only": opts.get("--only"),
           "interrupted_units": [], "units": {}}
    series["invocations"].append(inv)
    pre, why = preflight(plan, series, os.environ.get("SERIES_SKIP_ISOLATION_CHECK"))
    inv["preflight"] = pre
    first = next((i["preflight"]["conditions"] for i in series["invocations"][:-1]
                  if i.get("preflight", {}).get("conditions")), None)
    if not why and first is not None and first != pre["conditions"]:
        why = ("the series' conditions changed since it began (%s): its units would not be one series; start a new OUT"
               % ", ".join(k for k in sorted(first) if first[k] != pre["conditions"].get(k)))
    if why:
        inv["refused"] = why
        write_json(spath, {k: v for k, v in series.items() if k != "dir"})
        print("REFUSED  " + why)
        return 1
    # Only an invocation that may run looks at what earlier ones left. Nothing
    # is deleted: a unit cut short, or one done and no longer what it was, is
    # set aside under a name of its own, for review, and measured again.
    # Only the plan's own units are looked at: what was set aside before keeps
    # its own name and is never taken for a unit again.
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    done_sums = series.setdefault("done_sums", {})
    ids = {u["id"] for u in plan["units"]}
    for name in sorted(os.listdir(os.path.join(out, "units"))):
        full = os.path.join(out, "units", name)
        if name.endswith(".partial") and name[:-len(".partial")] in ids:
            uid = name[:-len(".partial")]
            inv["interrupted_units"].append(uid)
            os.replace(full, os.path.join(out, "units", "%s.interrupted-%s" % (uid, stamp)))
        elif name in ids and os.path.exists(os.path.join(full, "done")) and not holds(full, done_sums.get(name)):
            inv.setdefault("damaged_units", []).append(name)
            os.replace(full, os.path.join(out, "units", "%s.damaged-%s" % (name, stamp)))
            done_sums.pop(name, None)
    failed = 0
    for unit in plan["units"]:
        uid = unit["id"]
        final = os.path.join(out, "units", uid)
        if opts.get("--only") and opts["--only"] != uid:
            continue
        if os.path.exists(os.path.join(final, "done")):
            inv["units"][uid] = "done before"
            continue
        if opts.get("--power-limit-w") and str(unit.get("power_limit_w")) != opts["--power-limit-w"]:
            continue
        # The power limit is the host's. Read where the environment can read
        # it, and held to the unit's; where nvidia-smi answers but not with a
        # number ([N/A] inside a GPU-P guest), the unit runs only when the host
        # says which limit it set (--power-limit-w), and says so in the manifest.
        attested = None
        if unit.get("power_limit_w"):
            raw = (gpu_query("power.limit") or [None])[0]
            limit = number(raw)
            if limit is not None and abs(limit - unit["power_limit_w"]) > 1:
                inv["units"][uid] = "skipped: the GPU's power limit is %s W, the unit's %s W" % (limit, unit["power_limit_w"])
                continue
            if raw is not None and limit is None:
                if opts.get("--power-limit-w") != str(unit["power_limit_w"]):
                    inv["units"][uid] = ("skipped: the power limit reads %r in the environment, and the host did not say "
                                         "it set %s W (--power-limit-w)" % (raw, unit["power_limit_w"]))
                    continue
                attested = "%s W, as the host set it; it reads %r in the environment" % (unit["power_limit_w"], raw)
            elif limit is not None:
                attested = "%s W, read in the environment" % limit
        partial = final + ".partial"
        os.makedirs(partial)
        write_json(spath, {k: v for k, v in series.items() if k != "dir"})
        m = unit_run(plan, unit, partial)
        m["preflight_at"] = pre["at"]
        m["power_limit"] = attested
        write_json(os.path.join(partial, "manifest.json"), m)
        if m.get("failed"):
            failed += 1
            inv["units"][uid] = "failed: " + m["failed"]
            os.replace(partial, final + ".failed-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
            continue
        names = sorted(n for n in os.listdir(partial) if n != "SHA256SUMS")
        sums = "".join("%s  %s\n" % (sha256(os.path.join(partial, n)), n) for n in names)
        with open(os.path.join(partial, "SHA256SUMS"), "w") as f:
            f.write(sums)
            f.flush()
            os.fsync(f.fileno())
        fsync_tree(partial)
        os.replace(partial, final)
        with open(os.path.join(final, "done"), "w") as f:
            os.fsync(f.fileno())
        fsync_tree(final)
        fsync_tree(os.path.dirname(final))
        done_sums[uid] = sha256(os.path.join(final, "SHA256SUMS"))
        inv["units"][uid] = "done"
        write_json(spath, {k: v for k, v in series.items() if k != "dir"})
    inv["ended"] = utc()
    write_json(spath, {k: v for k, v in series.items() if k != "dir"})
    for uid, state in inv["units"].items():
        print("%s  %s: %s" % ("PASS" if state.startswith("done") else "FAIL" if state.startswith("failed") else "SKIP", uid, state))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
