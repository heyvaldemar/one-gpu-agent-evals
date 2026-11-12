# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Numbers measured on a workstation with an RTX 4090, each with the record it was computed from, and CI's recomputation of each. Every sentence in the README that says something holds is a check that runs in CI: `scripts/validate.sh`, `tests/recompute.sh`, `tests/e2e.sh`, or a plant table that breaks one of them. A claim with no check is not written. A number names its series or its run.

## Before changing anything

- Read the decision record that covers it, under `docs/decisions/`. A change that alters a decision amends that record or adds one, in the same format, ending with how the choice is explained to a customer.
- `make check` runs the static checks and the recomputation and shows each its breaks (`tests/static-plants.tsv`, `tests/recompute-plants.tsv`). It must stay all caught, none missed, none stale.

## A check is trusted only after it has failed

A new or changed check ships with the break it exists for, as a row in one of the plant tables. A copy with nothing planted in it has to pass first. A check of the environment on the workstation is trusted only after it has failed on the environment before it was closed.

## The flagship is a release

- The load generator, the tasks and tool table it sends, the server's images and arguments, and the models' lines are read only from where `scripts/sources.sh` unpacked the release `sources.lock` pins, after its sha256, its cosign signature and its SLSA provenance have passed. Never from a branch or a checkout.
- Nothing in the release's tree is edited. `loadgen/calls.py` wraps two functions of capacity.py and hands back what they returned.
- Moving to a new release changes `sources.lock` and, in the same commit, whatever pin the static checks say moved with it.

## Numbers

- No number is typed by hand. It is computed by `scripts/recompute.py` from a series' records, and the README's figures are checked against that.
- A workstation number says "measured on a workstation with an RTX 4090". It never stands in a row with a cloud card's, and no word of cadence (daily, weekly) is ever attached to it.
- When two series differ, find what changed (the driver, the power limit, the release, the weights, the load on the machine) before calling it noise.
- No price per call until the machine's draw at the wall and a tariff are measured.

## The workstation

- Nothing published here names or locates the workstation or its network: no host name, no domain, no address, no network, no tunnel, no VPN, no location or country, no account, and no build number of its operating system. The machine is "a workstation with an RTX 4090", or "a Windows 11 workstation with an RTX 4090" where the operating system matters (ADR 3). A driver version is recorded in a series' manifest for what it changes, never beside anything that would identify the machine.
- A series runs only in the closed environment of ADR 3, after its isolation check has passed, with the GPU lent by the host. No runner runs there, and nothing from a pull request ever does.
- Only open weights under permissive OSI licences, by their lines in `models.lock`. Nothing else on the machine is read.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` in the same commit as the change.
- Tag only a commit whose E2E is green, and say in the release notes what is new, what was found while building it, and how it was checked.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, series, commits and files. Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Print a secret, or put one in a file, a log or an argument. This repository holds none.
- Turn off or weaken a check, a plant or a control to get a run green.
- Publish a workstation number without its records, or before the recomputation passes on it.
- Edit a file inside `.cache/sources/`, or read the flagship from anywhere else.
- Add a self-hosted runner, or anything that runs this repository's code on the workstation from GitHub.
