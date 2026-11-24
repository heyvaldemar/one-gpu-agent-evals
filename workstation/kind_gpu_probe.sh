#!/usr/bin/env bash
# kind_gpu_probe.sh OUT [--test] - can a kind node in the closed environment
# run a pod on the GPU the host lends it? A probe, never published.
#
# Line 2 measures models at the flagship's real boundary, which runs on kind,
# and the inference gateway's row needs four vLLM pods on the card; both need
# a kind node whose pods reach the GPU. In a GPU-P guest the card is not a PCI
# device but /dev/dxg with the driver's libraries under /usr/lib/wsl, which
# Docker reaches through the CDI spec nvidia-ctk wrote. This probe tries, step
# by step, and records every step whether it passes or not:
#
#   isolation   the isolation check passes (ADR 3)
#   tools       kind and kubectl are the ones tools.lock pins
#   gpu         nvidia-smi, /dev/dxg and the CDI spec in the environment
#   docker-gpu  the flagship's CUDA server image sees the card through Docker
#   images      the node, CUDA and device plugin images are here, no pull
#   cluster     one kind node, with /dev/dxg, /usr/lib/wsl, the CDI spec and
#               the binaries its hooks call mounted in, labelled as a GPU node
#   node        what the node's containerd says about CDI
#   load        the CUDA and device plugin images loaded into the node
#   digest      whether the node finds the CUDA image by its digest, as the
#               flagship's and the gateway's manifests name it
#   libs        where NVML loads from, asked in the node and in a pod with
#               the plugin's mounts: the library under the driver root and
#               /usr/lib/wsl at its own path, ldd and nvidia-smi -L for each
#               (a finding, not a failure: 24.11 the plugin could not load NVML)
#   plugin-*    NVIDIA's device plugin (the gateway's v0.20.1) with one CDI
#               strategy, /usr/lib/wsl mounted at its own path, and whether
#               the node then offers nvidia.com/gpu
#   pod-*       a pod asking for nvidia.com/gpu runs the CUDA image's
#               --list-devices, and whether it names the card
#
# The cluster is deleted however the probe ends, and only this probe's
# cluster. Nothing in OUT is overwritten: OUT must not exist. --test runs it
# on a machine with no GPU (tests/kind_gpu_probe.sh): the isolation check,
# the tool pins and every GPU step are skipped and recorded as skipped.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: kind_gpu_probe.sh OUT [--test]}"
TEST=0; [ "${2:-}" = --test ] && TEST=1
if [ -e "$OUT" ]; then echo "REFUSED  $OUT exists: a probe never writes over another"; exit 1; fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
CLUSTER=kindgpu-probe
NODE="$CLUSTER-control-plane"
PROBES="${PROBES:-/etc/portfolio/probes}"
NODE_IMAGE="$(sed -n 's/^KIND_NODE_IMAGE=//p' "$ROOT/images.lock")"
CUDA_IMAGE="$(sed -n 's/^LLAMA_CUDA_IMAGE=//p' "$ROOT/images.lock")"
# The inference gateway's v1.4.0 pin (deploy/gpu/device-plugin.yaml).
PLUGIN_IMAGE="nvcr.io/nvidia/k8s-device-plugin:v0.20.1@sha256:d279ecdb47b252c4cd96f4224650e9808c36012f6979570c9611ddbc5b0749a7"
[ "$TEST" = 1 ] && CUDA_IMAGE="${TEST_CUDA_IMAGE:-$(sed -n 's/^PYTHON_IMAGE=//p' "$ROOT/images.lock")}"
KIND="${KIND:-kind}"; KUBECTL="${KUBECTL:-kubectl}"
export KUBECONFIG="$OUT/.kubeconfig"
first_fail=""; gpu_seen=""

record() {  # record STEP STATE SECONDS NOTE (the step's log is OUT/STEP.log)
  python3 -I - "$OUT" "$@" <<'PY'
import json, os, sys, time
out, step, state, secs, note = sys.argv[1:6]
log = os.path.join(out, step + ".log")
tail = open(log, errors="replace").read().strip().splitlines()[-12:] if os.path.exists(log) else []
row = {"step": step, "state": state, "seconds": float(secs), "note": note, "log_tail": tail,
       "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
open(os.path.join(out, "steps.jsonl"), "a").write(json.dumps(row) + "\n")
print("%-4s  %s%s" % (state, step, (": " + note) if note else ""))
PY
}
step() {  # step NAME NOTE CMD... : run CMD with its output in OUT/NAME.log
  local name="$1" note="$2" t0 rc; shift 2
  t0="$(date +%s)"
  "$@" >"$OUT/$name.log" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then record "$name" PASS "$(( $(date +%s) - t0 ))" "$note"
  else record "$name" FAIL "$(( $(date +%s) - t0 ))" "$note (exit $rc)"; [ -n "$first_fail" ] || first_fail="$name"; fi
  return "$rc"
}
skip() { record "$1" SKIP 0 "$2"; }
teardown() {
  "$KIND" delete cluster --name "$CLUSTER" >"$OUT/teardown.log" 2>&1
  docker rmi kindgpu-probe/cuda:local kindgpu-probe/device-plugin:local >>"$OUT/teardown.log" 2>&1
  rm -f "$KUBECONFIG"
}
finish() {
  teardown
  python3 -I - "$OUT" "$TEST" "$first_fail" "$gpu_seen" "$NODE_IMAGE" "$CUDA_IMAGE" "$PLUGIN_IMAGE" <<'PY'
import hashlib, json, os, sys, time
out, test, first_fail, gpu_seen, node, cuda, plugin = sys.argv[1:]
steps = [json.loads(l) for l in open(os.path.join(out, "steps.jsonl"))] if os.path.exists(os.path.join(out, "steps.jsonl")) else []
verdict = ("a pod on the kind node saw the GPU (%s)" % gpu_seen) if gpu_seen else \
          ("no pod on the kind node saw the GPU; first step that failed: %s" % (first_fail or "none"))
json.dump({"probe": "kind-gpu", "test": test == "1", "verdict": verdict, "images": {"node": node, "cuda": cuda, "plugin": plugin},
           "steps": [{k: s[k] for k in ("step", "state", "seconds", "note")} for s in steps],
           "ended": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, open(os.path.join(out, "manifest.json"), "w"), indent=2)
names = sorted(n for n in os.listdir(out) if n != "SHA256SUMS" and not n.startswith("."))
with open(os.path.join(out, "SHA256SUMS"), "w") as f:
    for n in names:
        f.write("%s  %s\n" % (hashlib.sha256(open(os.path.join(out, n), "rb").read()).hexdigest(), n))
print("VERDICT  " + verdict)
PY
  sync
  # On the workstation the probe passes when a pod saw the card; under --test,
  # when no step that ran failed.
  if [ -n "$gpu_seen" ] || { [ "$TEST" = 1 ] && [ -z "$first_fail" ]; }; then exit 0; fi
  exit 1
}
trap finish EXIT

# isolation, tools
if [ "$TEST" = 1 ]; then skip isolation "--test"; else
  step isolation "" python3 -I "$ROOT/workstation/isolation_check.py" series "$PROBES" \
    "$OUT/isolation-$(date -u +%Y%m%dT%H%M%SZ).json" || exit 1
fi
pinned() {  # pinned TOOL: its binary is the linux-amd64 one tools.lock pins
  local want got; want="$(awk -v t="$1" '$1 == t && $3 == "linux-amd64" {print $6}' "$ROOT/tools.lock")"
  got="$(sha256sum "$(command -v "$2")" | cut -d' ' -f1)"
  echo "$1: $(command -v "$2") sha256 $got, tools.lock $want"; [ -n "$want" ] && [ "$got" = "$want" ]
}
if [ "$TEST" = 1 ]; then skip tools "--test: the machine's own kind and kubectl"
else step tools "" bash -c "$(declare -f pinned); ROOT='$ROOT'; pinned kind '$KIND' && pinned kubectl '$KUBECTL'" || exit 1; fi

# the GPU as the environment and Docker see it
CDI_DIRS=""; HOOKS=""
if [ "$TEST" = 1 ]; then skip gpu "--test: no GPU here"; skip docker-gpu "--test: no GPU here"
else
  step gpu "" bash -c 'nvidia-smi -L && ls -l /dev/dxg && ls -l /etc/cdi /var/run/cdi 2>/dev/null; (nvidia-ctk cdi list 2>/dev/null || true)' || exit 1
  for d in /etc/cdi /var/run/cdi; do ls "$d"/*.yaml "$d"/*.json >/dev/null 2>&1 && CDI_DIRS="$CDI_DIRS $d"; done
  # The binaries the spec's hooks call run in the node's namespace, so they are mounted in too.
  HOOKS="$(cat /etc/cdi/*.y*ml /etc/cdi/*.json /var/run/cdi/*.y*ml /var/run/cdi/*.json 2>/dev/null \
           | grep -oE '/usr(/local)?/bin/[A-Za-z0-9._-]+' | sort -u | while read -r p; do [ -x "$p" ] && echo "$p"; done | tr '\n' ' ')"
  echo "cdi dirs:$CDI_DIRS; hook binaries: ${HOOKS:-none}" >"$OUT/cdi.txt"
  step docker-gpu "the CUDA image's --list-devices through Docker's CDI" \
    bash -c "docker run --rm --device nvidia.com/gpu=all '$CUDA_IMAGE' --list-devices 2>&1 | tee /dev/stderr | grep -qiE 'RTX|CUDA[0-9]*:'" || exit 1
fi

# images, no pull
need=("$NODE_IMAGE" "$CUDA_IMAGE"); [ "$TEST" = 1 ] || need+=("$PLUGIN_IMAGE")
step images "" bash -c 'for i in "$@"; do docker image inspect -f "{{.Id}} $i" "$i" || exit 1; done' _ "${need[@]}" || exit 1

# one kind node, with the GPU's paths mounted in
python3 -I - "$OUT/kind.yaml" "$NODE_IMAGE" "$TEST" "$CDI_DIRS" "$HOOKS" <<'PY'
import sys
path, image, test, cdi, hooks = sys.argv[1:]
mounts = []
if test != "1":
    mounts = [("/dev/dxg", "/dev/dxg", False), ("/usr/lib/wsl", "/usr/lib/wsl", True)]
    mounts += [(d, d, True) for d in cdi.split()] + [(h, h, True) for h in hooks.split()]
lines = ["kind: Cluster", "apiVersion: kind.x-k8s.io/v1alpha4", "nodes:", "  - role: control-plane",
         "    image: " + image, "    labels:", "      inference.heyvaldemar.com/accelerator: nvidia",
         "      boundary.heyvaldemar.com/accelerator: nvidia"]
if mounts:
    lines.append("    extraMounts:")
    for h, c, ro in mounts:
        lines += ["      - hostPath: " + h, "        containerPath: " + c] + (["        readOnly: true"] if ro else [])
open(path, "w").write("\n".join(lines) + "\n")
PY
"$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1
step cluster "" "$KIND" create cluster --name "$CLUSTER" --config "$OUT/kind.yaml" --wait 180s --kubeconfig "$KUBECONFIG" || exit 1
step node "containerd and CDI in the node" bash -c "docker exec '$NODE' containerd --version; docker exec '$NODE' sh -c 'containerd config dump | grep -n -i cdi'; docker exec '$NODE' sh -c 'ls -l /dev/dxg /usr/lib/wsl/lib 2>&1 | head -20'"

# Images into the node, each under its own reference and a local tag: pods
# here use the tag, and the digest step below asks whether the reference the
# flagship's and the gateway's manifests use survived the load.
docker tag "$CUDA_IMAGE" kindgpu-probe/cuda:local
loads=("$CUDA_IMAGE=kindgpu-probe/cuda:local")
if [ "$TEST" = 0 ]; then docker tag "$PLUGIN_IMAGE" kindgpu-probe/device-plugin:local; loads+=("$PLUGIN_IMAGE=kindgpu-probe/device-plugin:local"); fi
# One platform's archive each: a multi-platform image whose other platforms
# are not here fails kind's import of all of them.
load() {
  local arch tmp ref tag; arch="$(docker version -f '{{.Server.Arch}}')"; tmp="$OUT/.load"; mkdir -p "$tmp"
  for pair in "$@"; do
    ref="${pair%%=*}"; tag="${pair#*=}"
    docker save --platform "linux/$arch" -o "$tmp/image.tar" "$ref" "$tag" 2>/dev/null \
      || docker save -o "$tmp/image.tar" "$ref" "$tag" || return 1
    "$KIND" load image-archive --name "$CLUSTER" "$tmp/image.tar" || return 1
    rm -f "$tmp/image.tar"
  done
  rmdir "$tmp"
}
step load "" load "${loads[@]}" || exit 1
info() {  # info NAME NOTE CMD...: like step, but a negative answer is a finding, not a failure
  local name="$1" note="$2" t0; shift 2; t0="$(date +%s)"
  if "$@" >"$OUT/$name.log" 2>&1; then record "$name" PASS "$(( $(date +%s) - t0 ))" "$note"
  else record "$name" NO "$(( $(date +%s) - t0 ))" "$note"; fi
}
info digest "the node finds the CUDA image by the digest the manifests name, without a pull" \
  docker exec "$NODE" crictl inspecti -o go-template --template '{{.status.id}} {{.status.repoDigests}}' "$CUDA_IMAGE"
if [ "$TEST" = 1 ]; then skip libs "--test: no GPU here"; skip plugin "--test: no GPU here"; skip pod "--test: no GPU here"; exit 0; fi

plugin_yaml() {  # plugin_yaml STRATEGY: the gateway's DaemonSet, with the GPU-P paths and the driver root
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: nvidia-device-plugin, namespace: kube-system}
data:
  config.yaml: |
    version: v1
    flags:
      migStrategy: none
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: nvidia-device-plugin, namespace: kube-system}
spec:
  selector: {matchLabels: {app: nvidia-device-plugin}}
  template:
    metadata: {labels: {app: nvidia-device-plugin}}
    spec:
      automountServiceAccountToken: false
      priorityClassName: system-node-critical
      nodeSelector: {inference.heyvaldemar.com/accelerator: nvidia}
      containers:
        - name: nvidia-device-plugin
          image: kindgpu-probe/device-plugin:local
          imagePullPolicy: Never
          env:
            - {name: CONFIG_FILE, value: /config/config.yaml}
            - {name: FAIL_ON_INIT_ERROR, value: "true"}
            - {name: DEVICE_LIST_STRATEGY, value: "$1"}
            - {name: NVIDIA_DRIVER_ROOT, value: /}
            - {name: CONTAINER_DRIVER_ROOT, value: /driver-root}
            - {name: LD_LIBRARY_PATH, value: /usr/lib/wsl/lib}
          securityContext: {privileged: true}
          volumeMounts:
            - {name: device-plugin, mountPath: /var/lib/kubelet/device-plugins}
            - {name: config, mountPath: /config, readOnly: true}
            - {name: driver-root, mountPath: /driver-root, readOnly: true}
            - {name: wsl, mountPath: /usr/lib/wsl, readOnly: true}
            - {name: cdi, mountPath: /var/run/cdi}
            - {name: dxg, mountPath: /dev/dxg}
      volumes:
        - {name: device-plugin, hostPath: {path: /var/lib/kubelet/device-plugins, type: Directory}}
        - {name: config, configMap: {name: nvidia-device-plugin}}
        - {name: driver-root, hostPath: {path: /}}
        - {name: wsl, hostPath: {path: /usr/lib/wsl, type: Directory}}
        - {name: cdi, hostPath: {path: /var/run/cdi, type: DirectoryOrCreate}}
        - {name: dxg, hostPath: {path: /dev/dxg}}
EOF
}
# What the libs step runs, in the node and in a pod: for each place NVML could
# load from, the file, ldd, and nvidia-smi -L (which loads NVML) with that
# directory first on the library path.
LIBS_SCRIPT='for d in /driver-root/usr/lib/wsl/lib /usr/lib/wsl/lib; do
  [ -d "$d" ] || { echo "== $d: absent"; continue; }
  echo "== $d"; ls -la "$d/libnvidia-ml.so.1" 2>&1; ls "$(dirname "$d")" 2>&1 | tr "\n" " "; echo
  LD_LIBRARY_PATH="$d" ldd "$d/libnvidia-ml.so.1" 2>&1 | grep -E "not found|=>" | head -8
  if [ -x "$d/nvidia-smi" ]; then o="$(LD_LIBRARY_PATH="$d" "$d/nvidia-smi" -L 2>&1)"; rc=$?; printf "%s\n" "$o" | head -3; echo "nvidia-smi exit $rc"; else echo "no nvidia-smi in $d"; fi
done'
libs_pod_yaml() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: nvml-libs, namespace: kube-system}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: {inference.heyvaldemar.com/accelerator: nvidia}
  containers:
    - name: libs
      image: kindgpu-probe/cuda:local
      imagePullPolicy: Never
      command: ["sh", "-c", "\$(LIBS)"]
      env:
        - name: LIBS
          valueFrom: {configMapKeyRef: {name: nvml-libs, key: libs.sh}}
      securityContext: {privileged: true}
      volumeMounts:
        - {name: driver-root, mountPath: /driver-root, readOnly: true}
        - {name: wsl, mountPath: /usr/lib/wsl, readOnly: true}
        - {name: dxg, mountPath: /dev/dxg}
  volumes:
    - {name: driver-root, hostPath: {path: /}}
    - {name: wsl, hostPath: {path: /usr/lib/wsl, type: Directory}}
    - {name: dxg, hostPath: {path: /dev/dxg}}
EOF
}
libs() {
  echo "### in the node"; docker exec "$NODE" sh -c "$LIBS_SCRIPT"
  echo "### in a pod with the plugin's mounts"
  printf '%s\n' "$LIBS_SCRIPT" >"$OUT/libs.sh"
  libs_pod_yaml >"$OUT/libs-pod.yaml"
  "$KUBECTL" -n kube-system create configmap nvml-libs --from-file=libs.sh="$OUT/libs.sh" >/dev/null || return 1
  "$KUBECTL" apply -f "$OUT/libs-pod.yaml" >/dev/null || return 1
  local p=""; for _ in $(seq 1 60); do p="$("$KUBECTL" -n kube-system get pod nvml-libs -o jsonpath='{.status.phase}')"; case "$p" in Succeeded|Failed) break;; esac; sleep 2; done
  "$KUBECTL" -n kube-system logs nvml-libs 2>&1
  "$KUBECTL" -n kube-system delete pod nvml-libs --wait=false >/dev/null 2>&1
  "$KUBECTL" -n kube-system delete configmap nvml-libs >/dev/null 2>&1
  [ "$p" = Succeeded ]
}
info libs "where NVML loads from, in the node and in a pod with the plugin's mounts" libs
pod_yaml() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: gpu-probe, namespace: default}
spec:
  restartPolicy: Never
  nodeSelector: {inference.heyvaldemar.com/accelerator: nvidia}
  containers:
    - name: cuda
      image: kindgpu-probe/cuda:local
      imagePullPolicy: Never
      args: ["--list-devices"]
      resources: {limits: {nvidia.com/gpu: 1}}
EOF
}
for strategy in cdi-cri cdi-annotations; do
  plugin_yaml "$strategy" >"$OUT/plugin-$strategy.yaml"
  step "plugin-$strategy" "the node offers nvidia.com/gpu" bash -c "
    '$KUBECTL' apply -f '$OUT/plugin-$strategy.yaml' &&
    '$KUBECTL' -n kube-system rollout status ds/nvidia-device-plugin --timeout=120s;
    '$KUBECTL' -n kube-system logs ds/nvidia-device-plugin --tail=60;
    for _ in \$(seq 1 30); do
      n=\$('$KUBECTL' get node '$NODE' -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'); [ -n \"\$n\" ] && [ \"\$n\" != 0 ] && { echo \"allocatable nvidia.com/gpu: \$n\"; exit 0; }; sleep 2
    done; exit 1"
  if [ $? = 0 ]; then
    pod_yaml >"$OUT/pod.yaml"
    step "pod-$strategy" "a pod asking for nvidia.com/gpu names the card" bash -c "
      '$KUBECTL' apply -f '$OUT/pod.yaml' &&
      for _ in \$(seq 1 90); do p=\$('$KUBECTL' get pod gpu-probe -o jsonpath='{.status.phase}'); case \"\$p\" in Succeeded|Failed) break;; esac; sleep 2; done;
      '$KUBECTL' describe pod gpu-probe | tail -25; '$KUBECTL' logs gpu-probe 2>&1 | tee /dev/stderr | grep -qiE 'RTX|CUDA[0-9]*:'" \
      && gpu_seen="device plugin with DEVICE_LIST_STRATEGY=$strategy"
    "$KUBECTL" delete pod gpu-probe --wait=false >/dev/null 2>&1
  fi
  [ -n "$gpu_seen" ] && break
  "$KUBECTL" delete -f "$OUT/plugin-$strategy.yaml" --wait=true --timeout=60s >/dev/null 2>&1
done
exit 0
