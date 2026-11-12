#!/usr/bin/env python3
"""isolation_check.py PHASE PROBES - what the environment a series runs in must
not be able to do, each tried, each beside a control that must succeed.

    isolation_check.py prepare|series PROBES [RESULTS.json]

Run as root inside the environment (ADR 3): the series run Docker and kind,
which are root's equivalent there, so root's reach is the reach that counts.
Every check prints a PASS or FAIL line; any FAIL exits 1. The check is trusted
only after it has failed: it is run first on the environment before it is
closed, where it must fail, and the series' manifest keeps both results.

  host-files     no filesystem of the host is mounted (drvfs, 9p, virtiofs,
                 cifs, nfs, smb), and no /mnt/<drive letter> exists; control:
                 the series' own data directory is mounted and writable.
  host-mount     the host's drives cannot be mounted by root (drvfs and 9p are
                 tried, each must be refused); control: a tmpfs mounts.
  host-programs  no way to start a program of the host: no interop entry in
                 binfmt_misc, no interop socket, no Windows executable on any
                 mounted path; control: a program of the environment runs.
  credentials    no credential the series could use or leak: no environment
                 variable named like a secret (names only are printed, never
                 values), no git, gh, Docker, SSH, cloud or package-manager
                 credential file in a home directory, no git credential helper.
  network        every `deny HOST PORT` line in PROBES is refused, and every
                 `allow HOST PORT` line answers. In the series phase the allow
                 lines are only the ones marked `series`. PROBES lives in the
                 environment and is never published: it names addresses.

PROBES format, one per line, `#` for comments:
    allow  HOST PORT  [series]   must connect (prepare; series too if marked)
    deny   HOST PORT             must be refused or time out, in both phases
    data   PATH                  the series' data directory (the host-files control)
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile

HOST_FS = {"drvfs", "9p", "virtiofs", "cifs", "smb3", "smbfs", "nfs", "nfs4", "fuse.sshfs"}
SECRET_NAME = re.compile(r"(TOKEN|SECRET|PASSW|PASSWD|PWD|KEY|CRED|AUTH|SESSION|COOKIE)", re.I)
# Names the secret check must not flag: variables of the shell, and the ones
# systemd and a login session set on their own, which name a bus or a session
# and hold nothing to steal. DBUS_SESSION_BUS_ADDRESS was the first false alarm,
# on the workstation's own first run. SSH_AUTH_SOCK is not among them: an SSH
# agent's socket lends whoever reaches it the keys behind it.
HARMLESS = {"OLDPWD", "PWD", "XAUTHORITY", "HISTCONTROL", "KEYTIMEOUT",
            "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_ID", "XDG_SESSION_TYPE", "XDG_SESSION_CLASS",
            "XDG_SESSION_DESKTOP", "DESKTOP_SESSION"}
CREDENTIAL_FILES = [
    ".git-credentials", ".config/gh/hosts.yml", ".docker/config.json", ".netrc", ".npmrc", ".pypirc",
    ".aws/credentials", ".config/gcloud/credentials.db", ".azure/accessTokens.json", ".kube/config",
    ".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".huggingface/token", ".cache/huggingface/token",
    ".config/rclone/rclone.conf",
]

results = []


def report(state, check, text):
    results.append({"state": state, "check": check, "name": text})
    print("%s  %s: %s" % (state, check, text), flush=True)


def mounts():
    out = []
    with open("/proc/mounts", encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 3:
                out.append((p[0], p[1].replace("\\040", " "), p[2]))
    return out


def check_host_files(data):
    bad = [(src, tgt, fs) for src, tgt, fs in mounts() if fs in HOST_FS]
    for src, tgt, fs in bad:
        report("FAIL", "host-files", "%s is mounted at %s (%s): a filesystem of the host" % (src, tgt, fs))
    letters = [d for d in "cdefghijklmnopqrstuvwxyz" if os.path.isdir("/mnt/%s" % d) and os.listdir("/mnt/%s" % d)]
    for d in letters:
        report("FAIL", "host-files", "/mnt/%s exists and is not empty: the host's drive %s" % (d, d.upper()))
    if not bad and not letters:
        report("PASS", "host-files", "no filesystem of the host is mounted, and no /mnt/<drive> holds anything")
    if not data:
        report("FAIL", "host-files", "the control: PROBES names no data directory for the series")
        return
    try:
        fd, path = tempfile.mkstemp(dir=data)
        os.write(fd, b"control")
        os.close(fd)
        os.unlink(path)
        report("PASS", "host-files", "the control: the series' data directory %s is there and writable" % data)
    except OSError as e:
        report("FAIL", "host-files", "the control: the series' data directory %s is not writable (%s)" % (data, e.strerror))


def try_mount(fstype, source, target, opts=None):
    cmd = ["mount", "-t", fstype] + (["-o", opts] if opts else []) + [source, target]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    if r.returncode == 0:
        subprocess.run(["umount", target], capture_output=True)
        return True, ""
    # The first line mount says is the reason; util-linux adds a line about
    # dmesg after it.
    said = [l.strip() for l in (r.stderr or r.stdout).splitlines() if l.strip()]
    return False, said[0] if said else "refused"


def check_host_mount():
    if os.geteuid() != 0:
        report("FAIL", "host-mount", "the check is not running as root, so root's reach was not tried")
        return
    target = tempfile.mkdtemp(prefix="isolation-")
    try:
        for fstype, source, opts in (("drvfs", "C:", None), ("9p", "drvfs", "trans=fd,rfdno=3,wfdno=3"),
                                     ("9p", "C:", "trans=virtio")):
            ok, why = try_mount(fstype, source, target, opts)
            if ok:
                report("FAIL", "host-mount", "root mounted %s %s: the host's drive is reachable" % (fstype, source))
            else:
                report("PASS", "host-mount", "root cannot mount %s %s (%s)" % (fstype, source, why or "refused"))
        ok, why = try_mount("tmpfs", "tmpfs", target, "size=1m")
        if ok:
            report("PASS", "host-mount", "the control: root can mount a tmpfs, so the refusals above are the host's, not mount's")
        else:
            report("FAIL", "host-mount", "the control: root cannot mount even a tmpfs (%s), so the refusals prove nothing" % why)
    finally:
        os.rmdir(target)


def check_host_programs():
    bad = 0
    misc = "/proc/sys/fs/binfmt_misc"
    if os.path.isdir(misc):
        for name in sorted(os.listdir(misc)):
            if name in ("register", "status"):
                continue
            try:
                text = open(os.path.join(misc, name), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if text.startswith("enabled") and ("4d5a" in text.lower() or "interop" in name.lower() or "/init" in text):
                bad += 1
                report("FAIL", "host-programs", "binfmt_misc entry %s starts Windows executables" % name)
    for var in ("WSL_INTEROP", "WSL_DISTRO_NAME"):
        if var in os.environ:
            bad += 1
            report("FAIL", "host-programs", "%s is set: the environment knows a way to the host" % var)
    for d in ("/run/WSL",):
        if os.path.isdir(d) and any(n.endswith("_interop") for n in os.listdir(d)):
            bad += 1
            report("FAIL", "host-programs", "%s holds an interop socket" % d)
    exes = []
    for _, tgt, _ in mounts():
        for cand in ("Windows/System32/cmd.exe", "windows/system32/cmd.exe"):
            p = os.path.join(tgt, cand)
            if os.path.exists(p):
                exes.append(p)
    for p in exes:
        bad += 1
        report("FAIL", "host-programs", "%s is reachable" % p)
    if not bad:
        report("PASS", "host-programs", "no binfmt entry, interop socket or Windows executable reaches the host")
    r = subprocess.run(["/bin/sh", "-c", "echo control"], capture_output=True, text=True)
    if r.stdout.strip() == "control":
        report("PASS", "host-programs", "the control: a program of the environment runs")
    else:
        report("FAIL", "host-programs", "the control: /bin/sh did not run, so nothing above was tried")


def homes():
    out = {"/root"}
    try:
        for line in open("/etc/passwd", encoding="utf-8", errors="replace"):
            p = line.split(":")
            if len(p) > 5 and p[5].startswith("/home/"):
                out.add(p[5])
    except OSError:
        pass
    if os.environ.get("HOME"):
        out.add(os.environ["HOME"])
    return sorted(h for h in out if os.path.isdir(h))


def check_credentials():
    names = sorted(n for n in os.environ if SECRET_NAME.search(n) and n not in HARMLESS)
    for n in names:
        report("FAIL", "credentials", "an environment variable named %s is set (its value is not printed)" % n)
    found = [os.path.join(h, rel) for h in homes() for rel in CREDENTIAL_FILES if os.path.exists(os.path.join(h, rel))]
    for p in found:
        report("FAIL", "credentials", "%s exists" % p)
    try:
        r = subprocess.run(["git", "config", "--system", "--get-all", "credential.helper"], capture_output=True, text=True)
        helpers = r.stdout.split()
    except OSError:
        helpers = []
    for h in homes():
        try:
            r = subprocess.run(["git", "config", "--file", os.path.join(h, ".gitconfig"), "--get-all", "credential.helper"],
                               capture_output=True, text=True)
            helpers += r.stdout.split()
        except OSError:
            pass
    if helpers:
        report("FAIL", "credentials", "a git credential helper is configured (%d)" % len(helpers))
    if not names and not found and not helpers:
        report("PASS", "credentials", "no secret-named variable, no credential file in %d home directories, no git credential helper"
               % len(homes()))


def reach(host, port, timeout=3.0):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True, ""
    except OSError as e:
        return False, e.__class__.__name__


def check_network(phase, probes):
    allows = [(h, p) for kind, h, p, flag in probes if kind == "allow" and (phase == "prepare" or flag == "series")]
    denies = [(h, p) for kind, h, p, _ in probes if kind == "deny"]
    if phase == "series":
        denies += [(h, p) for kind, h, p, flag in probes if kind == "allow" and flag != "series"]
    if not denies:
        report("FAIL", "network", "PROBES names nothing the environment must not reach")
    for h, p in denies:
        ok, _ = reach(h, p)
        report("FAIL" if ok else "PASS", "network", "%s %s:%s %s" % (
            "reached" if ok else "refused", h, p, "in the %s phase" % phase))
    if not allows:
        report("FAIL", "network", "the control: PROBES names nothing the environment must reach in the %s phase" % phase)
    for h, p in allows:
        ok, why = reach(h, p)
        report("PASS" if ok else "FAIL", "network", "the control: %s:%s %s" % (
            h, p, "answers" if ok else "does not answer (%s), so the refusals above prove nothing" % why))


def read_probes(path):
    probes, data = [], None
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        if line[0] == "data" and len(line) == 2:
            data = line[1]
        elif line[0] in ("allow", "deny") and len(line) in (3, 4) and line[2].isdigit():
            probes.append((line[0], line[1], line[2], line[3] if len(line) == 4 else ""))
        else:
            sys.exit("PROBES line %d is not 'allow|deny HOST PORT [series]' or 'data PATH'" % n)
    return probes, data


def main(argv):
    if len(argv) not in (2, 3) or argv[0] not in ("prepare", "series"):
        sys.exit(__doc__)
    phase = argv[0]
    probes, data = read_probes(argv[1])
    check_host_files(data)
    check_host_mount()
    check_host_programs()
    check_credentials()
    check_network(phase, probes)
    failed = sum(1 for r in results if r["state"] == "FAIL")
    if len(argv) == 3:
        json.dump({"phase": phase, "checks": results, "failed": failed}, open(argv[2], "w"), indent=2)
    print("%d checks: %d passed, %d failed" % (len(results), len(results) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
