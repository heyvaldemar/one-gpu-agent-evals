#!/usr/bin/env bash
# validate.sh [CHECK...] - the static checks, all of them by default.
#
# Each holds this repository to the flagship's release sources.lock pins, so a
# number measured here is a number of the same server, the same weights and
# the same load the flagship measures with:
#   pins    the model server's and the load generator's images in images.lock
#           are the ones the release pins (airgap/images.txt, images-gpu.txt)
#   models  a model the release's models.lock also names has the same line here
#   args    the model server's arguments are the release's CPU server's
#           (manifests/inference/llama.yaml), but for the model's path and name
#   deploy  every image a manifest under deploy/ names is pinned by digest and
#           is one images.lock names
#   kind    cluster/kind.yaml starts the node image images.lock pins
#   private no file names a machine of the workstation's or its domain, or
#           holds an address in a private range (scripts/private_check.py,
#           which also runs over a series before it is committed here)
#   plan    every workstation plan serves with the release's GPU server's
#           arguments (manifests/inference/llama-gpu.yaml), but for the
#           model's path and name, and runs the images images.lock pins
# tests/static-plants.tsv breaks each of them; each must notice.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAGSHIP="${FLAGSHIP:-$("$ROOT/scripts/sources.sh" path flagship)}"
failed=0
pass() { printf 'PASS  %s: %s\n' "$check" "$*"; }
fail() { printf 'FAIL  %s: %s\n' "$check" "$*"; failed=1; }
pin() { sed -n "s/^$1=//p" "$ROOT/images.lock"; }

check_pins() {
  local name want got
  for name in LLAMA_CPU_IMAGE:airgap/images.txt:'ghcr.io/ggml-org/llama.cpp:server-b' \
              LLAMA_CUDA_IMAGE:airgap/images-gpu.txt:'ghcr.io/ggml-org/llama.cpp:server-cuda-b' \
              PYTHON_IMAGE:airgap/images.txt:'docker.io/library/python:' \
              BUSYBOX_IMAGE:airgap/images.txt:'docker.io/library/busybox:'; do
    IFS=: read -r var file prefix <<<"$name"
    want="$(grep -F "$prefix" "$FLAGSHIP/$file" | grep -v '^#' | head -n 1)"
    got="$(pin "$var")"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      pass "$var is the release's $file pin"
    else
      fail "$var is '$got'; the release's $file pins '$want'"
    fi
  done
}

check_models() {
  local line name theirs n=0
  # Every line, the release's or this repository's: a name, the publisher's
  # file at a 40-hex revision, its sha256, a permissive OSI licence, and the
  # flagship's image digest or `unpinned` (weights pinned by their sha256,
  # with no image CI rebuilds).
  if python3 -I - "$ROOT/models.lock" <<'PY'
import re, sys
bad = 0
for n, line in enumerate(open(sys.argv[1]), 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    f = line.split()
    ok = (len(f) == 5
          and re.fullmatch(r"[a-z0-9][a-z0-9.-]*", f[0])
          and re.fullmatch(r"https://huggingface\.co/[\w.-]+/[\w.-]+/resolve/[0-9a-f]{40}/[\w.-]+\.gguf", f[1])
          and re.fullmatch(r"[0-9a-f]{64}", f[2])
          and f[3] in ("Apache-2.0", "MIT", "BSD-2-Clause", "BSD-3-Clause")
          and (f[4] == "unpinned" or re.fullmatch(r"sha256:[0-9a-f]{64}", f[4])))
    if not ok:
        bad += 1
        print("FAIL  models: line %d is not 'name url-at-revision sha256 licence digest-or-unpinned': %s" % (n, line.strip()[:120]))
sys.exit(1 if bad else 0)
PY
  then
    pass "every line names a file at a pinned revision, its sha256, a permissive licence and a digest or unpinned"
  else
    failed=1
  fi
  while read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    name="${line%% *}"
    theirs="$(grep -E "^$name " "$FLAGSHIP/models/models.lock" || true)"
    [ -n "$theirs" ] || continue
    n=$((n + 1))
    if [ "$line" = "$theirs" ]; then
      pass "$name is the release's line, byte for byte"
    else
      fail "$name differs from the release's models.lock line"
    fi
  done <"$ROOT/models.lock"
  [ "$n" -gt 0 ] || fail "models.lock shares no model with the release"
}

check_args() {
  python3 -I - "$FLAGSHIP/manifests/inference/llama.yaml" "$ROOT/deploy/model-server.yaml" <<'PY' || failed=1
import re, sys
def args(path):
    m = re.search(r'args: \[(.*?)\]', open(path).read(), re.S)
    a = re.findall(r'"([^"]*)"', m.group(1)) if m else []
    # The model's path and the name it answers to are the only values allowed to differ.
    for flag in ("-m", "--alias"):
        if flag in a:
            a[a.index(flag) + 1] = "*"
    return a
theirs, ours = args(sys.argv[1]), args(sys.argv[2])
if theirs and ours == theirs:
    print("PASS  args: the model server's arguments are the release's CPU server's: " + " ".join(ours))
else:
    print("FAIL  args: the model server's arguments %s differ from the release's %s" % (ours, theirs))
    sys.exit(1)
PY
}

check_deploy() {
  local f img n=0
  for f in "$ROOT"/deploy/*.yaml; do
    while read -r img; do
      n=$((n + 1))
      case "$img" in *@sha256:*) ;; *) fail "$(basename "$f"): $img is not pinned by digest"; continue ;; esac
      if grep -qxF "$img" <(sed -n 's/^[A-Z0-9_]*_IMAGE=//p' "$ROOT/images.lock"); then
        pass "$(basename "$f"): $img is pinned in images.lock"
      else
        fail "$(basename "$f"): $img is not an image images.lock names"
      fi
    done < <(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f")
  done
  [ "$n" -gt 0 ] || fail "no image found under deploy/"
}

check_kind() {
  local node
  node="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$ROOT/cluster/kind.yaml")"
  if [ -n "$node" ] && [ "$node" = "$(pin KIND_NODE_IMAGE)" ]; then
    pass "cluster/kind.yaml starts the node image images.lock pins"
  else
    fail "cluster/kind.yaml starts '$node'; images.lock pins '$(pin KIND_NODE_IMAGE)'"
  fi
}

check_plan() {
  local f n=0
  for f in "$ROOT"/workstation/plans/*.json; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    if python3 -I - "$FLAGSHIP/manifests/inference/llama-gpu.yaml" "$f" "$ROOT/images.lock" <<'PY'
import json, re, sys
m = re.search(r'args: \[(.*?)\]', open(sys.argv[1]).read(), re.S)
theirs = re.findall(r'"([^"]*)"', m.group(1)) if m else []
plan = json.load(open(sys.argv[2]))
ours = list(plan["server"]["args"])
for a in (theirs, ours):
    for flag in ("-m", "--alias"):
        if flag in a:
            a[a.index(flag) + 1] = "*"
pins = dict(re.findall(r"^([A-Z0-9_]+_IMAGE)=(\S+)$", open(sys.argv[3]).read(), re.M))
bad = []
if not theirs or ours != theirs:
    bad.append("its server's arguments %s are not the release's GPU server's %s" % (ours, theirs))
if plan["images"]["server"] != pins.get("LLAMA_CUDA_IMAGE"):
    bad.append("its server image is not LLAMA_CUDA_IMAGE")
if plan["images"]["client"] != pins.get("PYTHON_IMAGE"):
    bad.append("its client image is not PYTHON_IMAGE")
for b in bad:
    print("FAIL  plan: %s: %s" % (sys.argv[2].rsplit("/", 1)[-1], b))
sys.exit(1 if bad else 0)
PY
    then
      pass "$(basename "$f"): the release's GPU server's arguments, and the images images.lock pins"
    else
      failed=1
    fi
  done
  [ "$n" -gt 0 ] || fail "no plan under workstation/plans"
}

check_private() {
  python3 -I "$ROOT/scripts/private_check.py" "$ROOT" || failed=1
}

all=(pins models args deploy kind plan private)
for check in "${@:-${all[@]}}"; do
  if [[ " ${all[*]} " != *" $check "* ]]; then
    echo "no check named $check (checks: ${all[*]})" >&2
    exit 2
  fi
  case "$check" in
    pins) check_pins ;;
    models) check_models ;;
    args) check_args ;;
    deploy) check_deploy ;;
    kind) check_kind ;;
    plan) check_plan ;;
    private) check_private ;;
  esac
done
exit "$failed"
