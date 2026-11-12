# 3. The host lends the GPU, and the environment holds nothing

- Status: proposed. It becomes accepted when the isolation check below has passed on the workstation, after first failing on an environment that was not yet closed.
- Date: 2026-11-12

## Context

The workstation is somebody's machine first. Its GPU serves other work most of the day, its disks hold things this repository must never read, and its power can go off in the middle of a run. A series of measurements runs there for minutes to hours, fetches public code and weights, and writes results that are published only after review.

## Decision

- **A closed environment.** The series run in an environment of their own on the workstation. It has no path to the host's files and starts no program of the host's. It holds no credential of any kind: public code and weights are fetched anonymously, and the results leave it only when the host collects them. While it is being prepared it reaches the outside only through an allowlist of the hosts it fetches from; during a series it reaches nothing.
- **Checked before every series.** `workstation/isolation_check.py` runs as root before each series and its result goes into the series' manifest. It tries each thing the environment must not do, each beside a control that must succeed: find a filesystem of the host mounted or a drive under `/mnt` (control: the series' data directory is writable); mount the host's drives itself (control: a tmpfs mounts, so a refusal is the host's and not mount's); start a program of the host; find a credential (by name only, never printing a value); reach an address its probes deny (control: an address they allow answers). The probes name addresses and live only in the environment; `workstation/probes.example` shows their form. In CI, `tests/isolation.sh` shows the check a closed container and eight ways of opening it, each of which it must name, and `tests/isolation-plants.tsv` breaks the check seven ways. On the workstation it is trusted only after it has failed on the environment before it was closed.
- **The host lends the GPU.** The environment cannot take the GPU. The host takes it from its other users for a fixed time, starts the environment, and gives the GPU back when the series ends or its time runs out, whichever comes first. The GPU's power limit for long series is set by the host and recorded in the manifest.
- **A series survives the power going off.** A series is a list of units: a level of concurrency, an attempt of a task, a step of training. Each finished unit is on disk before the next starts. After an interruption the series continues from the first unit not finished; a level of concurrency is measured again whole, since a rate is read from one unbroken window. Every interruption is recorded with its time.
- **Published after review.** The host keeps the results privately. They are checked against their hashes, cleaned of anything that would name or locate the workstation or its network, refused if anything of that kind is left, and only then committed here, where CI recomputes them (ADR 1).
- **Only open weights under permissive licences**, pinned by revision and sha256 in `models.lock` (ADR 2). Nothing the host keeps for its own use is read.

## Consequences

- No number from the workstation is published before the isolation check has passed there.
- A series can take longer in calendar time than it does on the card: it waits for the GPU, and starts again after a power cut.
- The environment's manifest names what ran (releases, digests, hashes, driver, power limit) and nothing about where.

## Alternatives

- **Run the series on the host directly.** Simpler, and everything on the host would be one bug away from the series.
- **A runner on the workstation.** Refused in ADR 1.

## How this is explained to a customer

The same rules hold on a customer's GPU servers: the measurement runs in a box that holds no secret and can reach only what it was told to, the owner of the hardware decides when it gets the GPU, and what leaves is reviewed before anyone publishes it.
