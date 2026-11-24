#!/usr/bin/env bash
# kind_gpu_probe.sh - workstation/kind_gpu_probe.sh with --test, on a machine
# with no GPU: the node image is the one images.lock pins, the cluster comes
# up with the GPU node's labels, an image is loaded into it by a local tag,
# every GPU step is recorded as skipped, the record is whole, and the cluster
# is gone afterwards. Then a probe never writes over another: an OUT that
# exists is refused. What it cannot test here (the GPU steps) runs only on
# the workstation, and its record says which step failed first.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.cache/bin:$PATH"
mkdir -p "$ROOT/.cache"
work="$(mktemp -d "$ROOT/.cache/kindgpu-test.XXXXXX")"
trap '/bin/rm -rf "$work"; kind delete cluster --name kindgpu-probe >/dev/null 2>&1' EXIT
failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

# The probe pulls nothing: on the workstation its images are carried in. Here
# the test brings them, by the digests images.lock pins, before it runs.
for ref in "$(sed -n 's/^KIND_NODE_IMAGE=//p' "$ROOT/images.lock")" "$(sed -n 's/^PYTHON_IMAGE=//p' "$ROOT/images.lock")"; do
  docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null || fail "could not pull $ref"
done
if bash "$ROOT/workstation/kind_gpu_probe.sh" "$work/out" --test >"$work/run.txt" 2>&1; then
  pass "the probe ran with --test: $(grep -c '^PASS' "$work/run.txt") steps passed, $(grep -c '^SKIP' "$work/run.txt") skipped"
else
  fail "the probe with --test exited non-zero: $(tail -4 "$work/run.txt")"
fi
if python3 -I - "$work/out" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
m = json.load(open(os.path.join(out, "manifest.json")))
state = {s["step"]: s["state"] for s in m["steps"]}
assert m["test"] is True, m
for s in ("images", "cluster", "node", "load"):
    assert state.get(s) == "PASS", (s, state)
for s in ("isolation", "tools", "gpu", "docker-gpu", "libs", "plugin", "pod"):
    assert state.get(s) == "SKIP", (s, state)
kind_yaml = open(os.path.join(out, "kind.yaml")).read()
assert "inference.heyvaldemar.com/accelerator: nvidia" in kind_yaml and "extraMounts" not in kind_yaml, kind_yaml
listed = dict(reversed(l.rstrip("\n").split("  ", 1)) for l in open(os.path.join(out, "SHA256SUMS")))
names = {n for n in os.listdir(out) if n != "SHA256SUMS" and not n.startswith(".")}
assert set(listed) == names, (sorted(listed), sorted(names))
for n, s in listed.items():
    assert hashlib.sha256(open(os.path.join(out, n), "rb").read()).hexdigest() == s, n
PY
then pass "cluster, node and load passed; the isolation check, tools and every GPU step recorded as skipped; every file in SHA256SUMS"; else fail "the probe's record is not what --test should leave"; fi
if kind get clusters 2>/dev/null | grep -qx kindgpu-probe; then fail "the probe's cluster was left running"; else pass "the probe's cluster is gone"; fi
if [ -z "$(docker images -q kindgpu-probe/cuda:local)" ]; then pass "the probe's local image tag is gone"; else fail "the probe left its image tag"; fi

before="$(cat "$work/out/SHA256SUMS")"
if bash "$ROOT/workstation/kind_gpu_probe.sh" "$work/out" --test >"$work/run2.txt" 2>&1; then
  fail "the probe wrote into an OUT that exists"
elif grep -q REFUSED "$work/run2.txt" && [ "$before" = "$(cat "$work/out/SHA256SUMS")" ]; then
  pass "an OUT that exists is refused and left as it was"
else
  fail "an OUT that exists was not refused cleanly: $(tail -2 "$work/run2.txt")"
fi
exit "$failed"
