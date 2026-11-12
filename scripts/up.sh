#!/usr/bin/env bash
# up.sh - the cluster CI measures the CPU row in: the flagship's release
# verified and unpacked, the model's weights downloaded and hashed, and one
# kind node that sees them. tests/e2e.sh deploys the server and the load.
#
# MODEL names the model's line in models.lock (granite-4.0-1b by default).
# CLUSTER names the kind cluster (one-gpu-agent-evals).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="${MODEL:-granite-4.0-1b}"
CLUSTER="${CLUSTER:-one-gpu-agent-evals}"
say() { printf '== %s\n' "$*" >&2; }

"$ROOT/scripts/sources.sh" path flagship >/dev/null
file="$("$ROOT/scripts/models.sh" "$MODEL")"
say "$MODEL: $(basename "$file"), its sha256 the one models.lock pins"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  say "kind cluster $CLUSTER is up already"
  exit 0
fi
config="$(mktemp)"
trap 'rm -f "$config"' EXIT
sed "s#@MODELS@#$(dirname "$file")#" "$ROOT/cluster/kind.yaml" >"$config"
kind create cluster --name "$CLUSTER" --config "$config" --wait 180s >&2
say "kind cluster $CLUSTER is up"
