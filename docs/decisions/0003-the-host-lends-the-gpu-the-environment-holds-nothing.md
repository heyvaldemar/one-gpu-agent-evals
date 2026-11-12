# 3. The host lends the GPU, and the environment holds nothing

- Status: accepted. The probes chose a Hyper-V guest with GPU-P, and the isolation check passed on it closed after failing on it open ("On the workstation, 2026-11-12" below).
- Date: 2026-11-12

## Context

The workstation is a Windows 11 machine with an RTX 4090, and it is somebody's machine first. Its GPU serves other work most of the day, its disks hold things this repository must never read, and its power can go off in the middle of a run. A series of measurements runs there for minutes to hours, fetches public code and weights, and writes results that are published only after review.

Two kinds of environment can give a Linux series that GPU on Windows 11:

- **A Hyper-V guest with GPU-P** (GPU partitioning). Its own kernel, its own virtual switch and network, its own Docker, no driver for the host's filesystems and no way to start the host's programs, and checkpoints to start every series from the same state. For a Linux guest on a Windows client the GPU path is not supported by Microsoft or NVIDIA: the guest needs the `dxgkrnl` module and a copy of the host driver's user-mode libraries, and both have to be brought back in line after every driver update on the host.
- **A WSL2 distribution.** CUDA there is supported by NVIDIA. But every WSL2 distribution runs in one utility VM with one kernel, shares its network with the other distributions on the machine, and is given the host's drives by a file server on the host: `automount = false` and `interop = false` are settings, and root inside can mount a drive and register a way to start the host's programs again. Its boundary is weaker, and a series run there would say so.

## Decision

- **A Hyper-V guest with GPU-P.** Two probes on the workstation, one of each kind above, decided it (below). The guest has one adapter, on a switch that carries nothing but it and the host, with no NAT and no route out; the host's firewall refuses everything that comes in from that switch. The guest boots Microsoft's WSL2 kernel, which carries `dxgkrnl`, with Ubuntu's kernel kept as the fallback; Secure Boot is off for that reason. The host driver's user-mode libraries are copied in, and the host compares the driver, the libraries and the kernel with the guest's manifest before every block, and copies them again when one has changed.
- **Started by the host's scheduler.** A block is started by a scheduled task on the host, never by an interactive session: a session can end, and take what it started with it.
- **A closed environment.** The series run in an environment of their own on the workstation. It has no path to the host's files, starts no program of the host's, and holds no credential of any kind. It reaches no network, ever: not while a series runs and not while it is being prepared.
- **Everything it runs is carried in as files.** The packages, the images by digest, the weights by sha256 and the flagship's release are fetched outside it, each checked against its signature or its pinned hash where it was fetched, copied in, and checked again inside before anything uses it. The list of what was carried in, with each file's hash and where it came from, goes into every series' manifest. This is the flagship's own way across an air gap (its ADR 8): one set of files, each checked on the far side. A proxy on the host for the environment to fetch through was considered and not built: it would be a service of the host the environment can reach, and a hole in the wall in the one place the wall is shown to be closed.
- **Results leave only when the host collects them**, over a connection the host opens.
- **Checked before every series.** `workstation/isolation_check.py` runs as root before each series and its result goes into the series' manifest. It tries each thing the environment must not do, each beside a control that must succeed: find a filesystem of the host mounted or a drive under `/mnt` (control: the series' data directory is writable); mount the host's drives itself (control: a tmpfs mounts, so a refusal is the host's and not mount's); start a program of the host; find a credential (by name only, never printing a value); reach an address its probes deny: the host on every port, the local network, the outside (control: a service of its own answers). The probes name addresses and live only in the environment; `workstation/probes.example` shows their form. In CI, `tests/isolation.sh` shows the check a closed container, the same with the variables a systemd session sets, and nine ways of opening it, each of which it must name, and `tests/isolation-plants.tsv` breaks the check eight ways. On the workstation it is trusted only after it has failed on the environment before it was closed.
- **The host lends the GPU.** The environment cannot take the GPU. The host takes it from its other users for a fixed time, starts the environment, and gives the GPU back when the series ends or its time runs out, whichever comes first. The GPU's power limit for long series is set by the host and recorded in the manifest.
- **A series survives the power going off.** A series is a list of units: a level of concurrency, an attempt of a task, a step of training. Each finished unit is on disk before the next starts. After an interruption the series continues from the first unit not finished; a level of concurrency is measured again whole, since a rate is read from one unbroken window. Every interruption is recorded with its time.
- **Published after review.** The host keeps the results privately. They are checked against their hashes, cleaned of anything that would name or locate the workstation or its network, refused if anything of that kind is left, and only then committed here, where CI recomputes them (ADR 1).
- **Only open weights under permissive licences**, pinned by revision and sha256 in `models.lock` (ADR 2). Nothing the host keeps for its own use is read.

## On the workstation, 2026-11-12

- **A WSL2 distribution under the same Windows account** (the first probe), closed by `wsl.conf` and given nothing: it shared one network namespace with Docker Desktop's distribution, so another distribution's services on loopback answered it; root mounted the host's system drive with `drvfs` although automount was off; its memory was the one utility VM's. Starting a program of the host failed, since the host did not serve the interop channel. The isolation check failed on it, as it had to: host-mount, network (another distribution's loopback service, the host, the outside), host-files (the host's driver store, mounted read-only) and host-programs (the interop channel). That run also took the D-Bus session address for a secret, which led to the list of variables a systemd session sets.
- **A Hyper-V guest with GPU-P** (the second probe), installed from Ubuntu 24.04.5's server image after its checksum file's signature and the image's sha256 were checked, with no network. It booted the WSL2 kernel on the first try; `nvidia-smi` in it named the RTX 4090 with the host's UUID, and the driver's libraries were found with no path given.
  - **Open** (the host's firewall rule off, and a temporary second adapter on a NAT switch): the check failed, 8 of 24, on the host on two ports, the local network and the outside.
  - **Closed** (that adapter removed, the rule on, and root inside adding a default route through the host first, as a hostile guest would): the check passed, 24 of 24. No IPv6 address on the guest's adapter.
- Not yet measured: whether the host's memory holds the guest's demand under load (the first try did not touch the pages it asked for), and a CUDA computation in the guest (only `nvidia-smi` ran).

## Consequences

- No number from the workstation is published before the isolation check has passed there.
- A series can take longer in calendar time than it does on the card: it waits for the GPU, and starts again after a power cut.
- The environment's manifest names what ran (releases, digests, hashes, driver, power limit) and nothing about where.

## Alternatives

- **Run the series on the host directly.** Simpler, and everything on the host would be one bug away from the series.
- **A runner on the workstation.** Refused in ADR 1.

## How this is explained to a customer

The same rules hold on a customer's GPU servers: the measurement runs in a box that holds no secret and can reach only what it was told to, the owner of the hardware decides when it gets the GPU, and what leaves is reviewed before anyone publishes it.
