#!/usr/bin/env python3
"""memory_probe.py SPEC OUT [--test] - how much of the card and of the
environment's memory a model takes, measured, before a series of it is planned.

A probe, never published. For each configuration the spec lists (how many
layers keep their experts on the CPU, `--n-cpu-moe`, and whether the server
maps the weights or reads them in, `--no-mmap`), in that order:

  - the flagship's GPU server image starts the model on an internal Docker
    network, with a memory limit two GiB under the environment's own, so a
    configuration that does not fit fails in its container and not in the
    environment;
  - once a second, from before the server starts to after it is gone: the
    card's memory, the environment's memory (available, cached, anonymous,
    mapped), the server's resident set split into anonymous and file pages,
    and its container's memory as its cgroup counts it;
  - its time to ready, then a few short calls and one long one from a
    container beside it, with the server's own timings of each;
  - its log, kept whatever the end.

A configuration whose server does not come up is recorded with the end of its
log, and the configurations after it in the same mapping mode that put more on
the card are not tried. No configuration starts when the spec's time budget
would not hold it. Nothing in OUT is overwritten: OUT must not exist.

Before any configuration: the isolation check passes (ADR 3), the carried-in
files match their list, the model file is the one models.lock pins and the
image is the one images.lock pins. --test skips the isolation check and the
image pin for tests/memory_probe.sh, and the manifest says so.
"""
import json
import os
import re
import shutil
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_series as rs  # noqa: E402  (the runner's own helpers and checks)

NET = "memprobe-net"
SERVER = "memprobe-server"
MEMINFO = ("MemTotal", "MemAvailable", "MemFree", "Cached", "AnonPages", "Mapped", "Shmem")
STATUS = ("VmRSS", "RssAnon", "RssFile", "RssShmem")
CALLS = r"""
import json, sys, time, urllib.request
url, model, n, max_tokens = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def call(content):
    body = {"model": model, "messages": [{"role": "user", "content": content}], "max_tokens": max_tokens,
            "temperature": 0, "seed": 1}
    req = urllib.request.Request(url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t = time.time()
    try:
        d = json.load(urllib.request.urlopen(req, timeout=900))
    except Exception as e:
        return {"wall_s": round(time.time() - t, 3), "error": str(e)[:300]}
    return {"wall_s": round(time.time() - t, 3), "usage": d.get("usage"), "timings": d.get("timings"),
            "finish_reason": (d.get("choices") or [{}])[0].get("finish_reason")}
# About four thousand tokens of one plain sentence, the same every run.
long_text = "The quick brown fox jumps over the lazy dog near the river bank. " * 300
print(json.dumps({"short": [call("Name three prime numbers.") for _ in range(n)],
                  "long": call(long_text + "\nSay in one sentence what the text above repeats.")}))
"""


def meminfo():
    out = {}
    try:
        for line in open("/proc/meminfo"):
            k, v = line.split(":", 1)
            if k in MEMINFO:
                out[k] = int(v.split()[0])
    except OSError:
        pass
    return out


def proc_status(pid):
    out = {}
    try:
        for line in open("/proc/%d/status" % pid):
            k, v = line.split(":", 1)
            if k in STATUS:
                out[k] = int(v.split()[0])
    except (OSError, ValueError):
        pass
    return out


def cgroup_memory(pid):
    """The container's memory as cgroup v2 counts it, page cache included."""
    try:
        path = [l.split("::", 1)[1].strip() for l in open("/proc/%d/cgroup" % pid) if l.startswith("0::")][0]
        base = os.path.join("/sys/fs/cgroup", path.lstrip("/"))
        out = {}
        for name in ("memory.current", "memory.peak"):
            p = os.path.join(base, name)
            if os.path.exists(p):
                out[name] = int(open(p).read().split()[0])
        return out
    except (OSError, IndexError, ValueError):
        return {}


class Sampler(threading.Thread):
    """One line a second until stopped: the card, the environment, the server."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.stop, self.pid, self.rows = path, threading.Event(), None, []

    def run(self):
        with open(self.path, "w", encoding="utf-8") as f:
            while not self.stop.is_set():
                g = rs.gpu_query("memory.used,memory.total,utilization.gpu,power.draw")
                row = {"t": rs.utc(), "gpu_memory_used_mib": rs.number(g[0]) if g else None,
                       "gpu_utilization": rs.number(g[2]) if g else None, "gpu_power_w": rs.number(g[3]) if g else None}
                row.update({"env_" + k + "_kib": v for k, v in meminfo().items()})
                if self.pid:
                    row.update({"server_" + k + "_kib": v for k, v in proc_status(self.pid).items()})
                    row.update({"cgroup_" + k.split(".")[1] + "_bytes": v for k, v in cgroup_memory(self.pid).items()})
                self.rows.append(row)
                f.write(json.dumps(row, sort_keys=True) + "\n")
                f.flush()
                self.stop.wait(1.0)


def peaks(rows):
    def mx(k):
        v = [r[k] for r in rows if r.get(k) is not None]
        return max(v) if v else None

    def mn(k):
        v = [r[k] for r in rows if r.get(k) is not None]
        return min(v) if v else None
    return {"gpu_memory_used_mib_max": mx("gpu_memory_used_mib"), "env_MemAvailable_kib_min": mn("env_MemAvailable_kib"),
            "env_Cached_kib_max": mx("env_Cached_kib"), "server_VmRSS_kib_max": mx("server_VmRSS_kib"),
            "server_RssAnon_kib_max": mx("server_RssAnon_kib"), "server_RssFile_kib_max": mx("server_RssFile_kib"),
            "cgroup_current_bytes_max": mx("cgroup_current_bytes"), "cgroup_peak_bytes_max": mx("cgroup_peak_bytes"),
            "samples": len(rows)}


def one(spec, out, name, n_cpu_moe, mode, limit_bytes):
    """One configuration: start, sample, wait, call, keep the log, remove."""
    r_ = {"config": name, "n_cpu_moe": n_cpu_moe, "mmap": mode, "started": rs.utc()}
    args = list(spec["base_args"])
    if n_cpu_moe is not None:
        args += ["--n-cpu-moe", str(n_cpu_moe)]
    if mode == "no-mmap":
        args += ["--no-mmap"]
    r_["server_args"] = args
    sampler = Sampler(os.path.join(out, name + ".samples.jsonl"))
    sampler.start()
    time.sleep(2)  # the environment before the server, for the record
    model = os.path.join(spec["models_dir"], spec["model"] + ".gguf")
    cmd = ["docker", "run", "-d", "--name", SERVER, "--network", NET, "--read-only", "--tmpfs", "/tmp",
           "--memory", str(limit_bytes), "--memory-swap", str(limit_bytes),
           "-v", "%s:/models/model.gguf:ro" % model] + spec.get("gpu_flags", [])
    for src, dst in spec.get("mounts", []):
        cmd += ["-v", "%s:%s:ro" % (src if src.startswith("/") else os.path.join(rs.ROOT, src), dst)]
    t0 = time.time()
    try:
        r = rs.run(cmd + [spec["image"]] + args)
        if r.returncode != 0:
            r_["failed"] = "the server's container did not start: " + r.stderr.strip()[-300:]
            return r_
        pid = rs.run(["docker", "inspect", "-f", "{{.State.Pid}}", SERVER]).stdout.strip()
        sampler.pid = int(pid) if pid.isdigit() and int(pid) > 0 else None
        wait = int(spec.get("ready_timeout_s", 1500))
        probe = ("import time, urllib.request\nt = time.time()\nwhile time.time() - t < %d:\n"
                 "    try:\n        urllib.request.urlopen('http://%s:8080/health', timeout=2); print('ready'); break\n"
                 "    except Exception: time.sleep(0.5)\n") % (wait, SERVER)
        r = rs.run(["docker", "run", "--rm", "--network", NET, spec["client_image"], "python3", "-I", "-c", probe])
        r_["time_to_ready_s"] = round(time.time() - t0, 1)
        state = rs.run(["docker", "inspect", "-f", "{{.State.Status}} {{.State.OOMKilled}} {{.State.ExitCode}}",
                        SERVER]).stdout.split()
        r_["container_state"] = state
        if "ready" not in r.stdout:
            r_["failed"] = ("the server was killed for memory" if len(state) > 1 and state[1] == "true"
                            else "the server was not ready in %d s" % wait)
            return r_
        r = rs.run(["docker", "run", "--rm", "--network", NET, "--read-only", "--tmpfs", "/tmp",
                    spec["client_image"], "python3", "-I", "-c", CALLS, "http://%s:8080" % SERVER, spec["model"],
                    str(spec.get("calls", 3)), str(spec.get("max_tokens", 128))])
        try:
            r_["calls"] = json.loads(r.stdout)
        except ValueError:
            r_["calls"] = {"error": (r.stdout + r.stderr).strip()[-300:]}
        time.sleep(2)  # the server settled after its calls, for the record
    finally:
        logs = rs.run(["docker", "logs", SERVER])
        with open(os.path.join(out, name + ".server.log"), "w", encoding="utf-8") as f:
            f.write(logs.stdout + logs.stderr)
        if r_.get("failed"):
            r_["log_tail"] = (logs.stdout + logs.stderr).strip().splitlines()[-25:]
        rs.docker_rm(SERVER)
        time.sleep(2)  # the environment after the server, for the record
        sampler.stop.set()
        sampler.join()
        r_["peaks"] = peaks(sampler.rows)
        r_["seconds"] = round(time.time() - t0, 1)
        r_["ended"] = rs.utc()
    return r_


def main(argv):
    test = "--test" in argv
    argv = [a for a in argv if a != "--test"]
    if len(argv) != 2:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    spec_path, out = argv
    spec = json.load(open(spec_path, encoding="utf-8"))
    if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", spec["model"]):
        print("REFUSED  the spec's model is not a models.lock name", file=sys.stderr)
        return 1
    if os.path.exists(out):
        print("REFUSED  %s exists: a probe never writes over another" % out, file=sys.stderr)
        return 1
    os.makedirs(out)
    started, t_start = rs.utc(), time.time()
    m = {"probe": spec["probe"], "spec_sha256": rs.sha256(spec_path), "started": started, "test": test,
         "runner_sha256": rs.sha256(os.path.abspath(__file__)), "kernel": os.uname().release,
         "env_memory_kib": meminfo().get("MemTotal"), "cpus": os.cpu_count()}

    def refuse(why):
        m["refused"] = why
        m["ended"] = rs.utc()
        rs.write_json(os.path.join(out, "manifest.json"), m)
        seal(out)
        print("REFUSED  " + why)
        return 1

    if test:
        m["isolation"] = {"state": "not checked", "why": "--test"}
    else:
        rec = os.path.join(out, "isolation-%s.json" % time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
        r = rs.run([sys.executable, "-I", os.path.join(rs.ROOT, "workstation", "isolation_check.py"), "series",
                    spec["probes"], rec])
        m["isolation"] = {"state": "passed" if r.returncode == 0 else "failed", "record": os.path.basename(rec)}
        if r.returncode != 0:
            return refuse("the isolation check failed: the probe does not start in an open environment")
    if spec.get("carry_in"):
        r = rs.run(["sha256sum", "-c", "--quiet", os.path.basename(spec["carry_in"])],
                   cwd=os.path.dirname(spec["carry_in"]))
        m["carry_in"] = {"list_sha256": rs.sha256(spec["carry_in"]), "state": "verified" if r.returncode == 0 else "failed"}
        if r.returncode != 0:
            return refuse("a carried-in file is not the one its list names")
    pins = dict(re.findall(r"^([A-Z0-9_]+_IMAGE)=(\S+)$", open(os.path.join(rs.ROOT, "images.lock")).read(), re.M))
    m["image"] = spec["image"]
    if not test and (spec["image"] != pins.get("LLAMA_CUDA_IMAGE") or spec["client_image"] != pins.get("PYTHON_IMAGE")):
        return refuse("the spec's images are not LLAMA_CUDA_IMAGE and PYTHON_IMAGE as images.lock pins them")
    lock = rs.models_lock()
    if spec["model"] not in lock:
        return refuse("models.lock has no line for %s" % spec["model"])
    path = os.path.join(spec["models_dir"], spec["model"] + ".gguf")
    t = time.time()
    got = rs.sha256(path) if os.path.isfile(path) else None
    m["model"] = {"name": spec["model"], "sha256": got, "pinned": lock[spec["model"]]["sha256"],
                  "license": lock[spec["model"]]["license"], "hash_seconds": round(time.time() - t, 1),
                  "bytes": os.path.getsize(path) if got else None}
    if got != lock[spec["model"]]["sha256"]:
        return refuse("%s is %s, models.lock pins %s" % (spec["model"], got, lock[spec["model"]]["sha256"]))
    g = rs.gpu_query("name,driver_version,memory.total,memory.used")
    m["gpu"] = dict(zip(("name", "driver_version", "memory.total", "memory.used"), g)) if g else None
    if spec.get("gpu_flags") and not g:
        return refuse("the spec's server runs on the GPU, and nvidia-smi does not answer for the card")
    total = meminfo().get("MemTotal")
    limit = int(spec.get("server_memory_bytes") or max(1 << 30, (total or 0) * 1024 - (2 << 30)))
    m["server_memory_limit_bytes"] = limit
    disk = shutil.disk_usage(spec["models_dir"])
    m["models_disk"] = {"total_bytes": disk.total, "free_bytes": disk.free}

    rs.run(["docker", "network", "create", "--internal", NET])
    rs.docker_rm(SERVER)
    results, budget, last = [], int(spec.get("budget_s", 5400)), 0.0
    for mode in spec.get("mmap", ["mmap"]):
        did_not_fit = None
        for n in spec.get("n_cpu_moe", [None]):
            name = "%s-%s" % (mode, "all-gpu" if n is None else "cpu-moe-%s" % n)
            if did_not_fit is not None:
                results.append({"config": name, "skipped": "with %s layers' experts on the CPU it did not come up; "
                                "fewer on the CPU puts more on the card" % did_not_fit})
                continue
            if time.time() - t_start + last * 1.2 > budget:
                results.append({"config": name, "skipped": "the time budget (%d s) would not hold it" % budget})
                continue
            res = one(spec, out, name, n, mode, limit)
            last = res.get("seconds", last)
            results.append(res)
            if res.get("failed") and n is not None:
                did_not_fit = n
            with open(os.path.join(out, "results.jsonl"), "a", encoding="utf-8") as f:
                f.write(json.dumps(res, sort_keys=True) + "\n")
    m["configs"] = [{k: r.get(k) for k in ("config", "failed", "skipped", "time_to_ready_s", "peaks")} for r in results]
    m["ended"] = rs.utc()
    rs.write_json(os.path.join(out, "manifest.json"), m)
    seal(out)
    for r in results:
        state = "SKIP" if r.get("skipped") else ("FAIL" if r.get("failed") else "OK")
        p = r.get("peaks") or {}
        print("%-4s  %s: %s" % (state, r["config"], r.get("skipped") or r.get("failed") or
                                "ready in %s s, card %s MiB, server RSS %s KiB, environment available down to %s KiB"
                                % (r.get("time_to_ready_s"), p.get("gpu_memory_used_mib_max"),
                                   p.get("server_VmRSS_kib_max"), p.get("env_MemAvailable_kib_min"))))
    return 0


def seal(out):
    """SHA256SUMS over every file the probe wrote, then all of it on disk."""
    names = sorted(n for n in os.listdir(out) if n != "SHA256SUMS")
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        for n in names:
            f.write("%s  %s\n" % (rs.sha256(os.path.join(out, n)), n))
    rs.fsync_tree(out)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
