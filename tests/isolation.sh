#!/usr/bin/env bash
# isolation.sh - workstation/isolation_check.py, shown a closed environment
# and each way of opening it.
#
# The environment is a container of the flagship's Python image: no network,
# a clean environment, a data directory, root with the one capability a mount
# needs, so the check's own control (a tmpfs) can mount. That must pass, and so
# must the same with the variables a systemd session sets on its own (the
# workstation's first run took DBUS_SESSION_BUS_ADDRESS for a secret). Then
# one opening at a time, each of which must fail the check, and the check
# that names it:
#   - a host's drive visible at /mnt/c;
#   - a variable named like a secret;
#   - an SSH agent's socket;
#   - a git credential file in root's home;
#   - an interop variable;
#   - an address the probes deny that answers;
#   - an address the probes allow that does not (the control broken);
#   - the check run as a user other than root;
#   - root without the capability to mount anything, where the check's
#     refusals prove nothing and its control has to say so.
# tests/isolation-plants.tsv breaks the check in turn; this test must notice.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="$(sed -n 's/^PYTHON_IMAGE=//p' "$ROOT/images.lock")"
failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

# PROBES as the test writes it: a listener on 127.0.0.1:8099 that must answer,
# a port on 127.0.0.1 nothing listens on and an outside address, both denied.
probes='data /data
allow 127.0.0.1 8099 series
deny 1.1.1.1 443
deny 127.0.0.1 8097'

# run NAME EXPECT CHECK [docker options...] [-- setup command]
run() {
  local name="$1" expect="$2" check="$3"
  shift 3
  local opts=() setup="true"
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; setup="$*"; break; fi
    opts+=("$1"); shift
  done
  local out
  # The check comes in on stdin, not on a mount: a directory bound from the
  # machine running the test would be a filesystem of the host, and the check
  # would rightly say so.
  local caps=(--cap-add SYS_ADMIN)
  [ "${NOCAPS:-}" = 1 ] && caps=()
  out="$(docker run -i --rm --network none ${caps[@]+"${caps[@]}"} --security-opt apparmor=unconfined \
    --tmpfs /data --tmpfs /tmp "${opts[@]}" "$IMAGE" sh -c "
      cat > /tmp/isolation_check.py
      printf '%s\n' \"\$PROBES\" > /tmp/probes
      python3 -I -c 'import socket, threading
for port in (8099,):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"127.0.0.1\", port)); s.listen()
    threading.Thread(target=lambda s=s: [s.accept() for _ in iter(int, 1)], daemon=True).start()
import time; time.sleep(60)' &
      sleep 1
      $setup
      exec env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=\"\${HOME:-/root}\" \${EXTRA_ENV:-} python3 -I /tmp/isolation_check.py series /tmp/probes
    " <"$ROOT/workstation/isolation_check.py" 2>&1)"
  local code=$?
  if [ "$expect" = pass ]; then
    if [ "$code" -eq 0 ]; then pass "$name: the check passes"; else fail "$name: the check fails: $(grep '^FAIL' <<<"$out" | head -3 | tr '\n' ' ')"; fi
  else
    if [ "$code" -ne 0 ] && grep -q "^FAIL  $check:" <<<"$out"; then
      pass "$name: the check fails, and $check names it"
    else
      fail "$name: the check does not fail on $check (exit $code)"
    fi
  fi
}

export PROBES="$probes"
run "a closed environment" pass "" -e PROBES
run "a closed environment with the variables a systemd session sets" pass "" -e PROBES \
  -e EXTRA_ENV="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus XDG_SESSION_ID=1 XDG_SESSION_TYPE=tty"
run "an SSH agent's socket" fail credentials -e PROBES -e EXTRA_ENV=SSH_AUTH_SOCK=/tmp/ssh-agent.sock
run "a host's drive at /mnt/c" fail host-files -e PROBES -- 'mkdir -p /mnt/c/Users && touch /mnt/c/Users/x'
run "a variable named like a secret" fail credentials -e PROBES -e EXTRA_ENV=HF_TOKEN=x
run "a git credential file in root's home" fail credentials -e PROBES -- 'printf "https://u:p@example.com\n" > /root/.git-credentials'
run "an interop variable" fail host-programs -e PROBES -e EXTRA_ENV=WSL_INTEROP=/run/WSL/1_interop
PROBES="${probes/deny 127.0.0.1 8097/deny 127.0.0.1 8099}" run "a denied address that answers" fail network -e PROBES
PROBES="${probes/allow 127.0.0.1 8099 series/allow 127.0.0.1 8096 series}" run "an allowed address that does not answer" fail network -e PROBES
run "the check run as a user other than root" fail host-mount -e PROBES --user 1000:1000 -e HOME=/tmp
NOCAPS=1 run "root without the capability to mount" fail host-mount -e PROBES
exit "$failed"
