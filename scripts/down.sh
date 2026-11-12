#!/usr/bin/env bash
# down.sh - the kind cluster up.sh made, gone. The verified release and the
# downloaded weights stay in .cache/ for the next run; `rm -rf .cache` removes
# them too.
set -euo pipefail
CLUSTER="${CLUSTER:-one-gpu-agent-evals}"
kind delete cluster --name "$CLUSTER"
