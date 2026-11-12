# 2. The flagship's load, server and weights, as released

- Status: accepted
- Date: 2026-11-12

## Context

A row for an RTX 4090 next to the flagship's rows for an L4, an A10G and a CPU is worth reading only if the card is what differs. The flagship measures with its own load generator (`scripts/capacity.py`: the first call of every eval task, as the agent sends it, at rising concurrency), its own server (llama.cpp's llama-server, by digest, with its own arguments), and its own weights (GGUF files pinned by revision and sha256 in `models/models.lock`). A copy of any of them could drift.

## Decision

All three come from the flagship's release, and this repository holds itself to it.

- **The release, verified first.** `sources.lock` pins the flagship's release by tag and archive sha256. `scripts/sources.sh` refuses the archive unless its sha256 is the pinned one, cosign verifies its signature as made by the flagship's release workflow on that tag, and slsa-verifier verifies its provenance for that tag. Nothing from the release is read before all three pass. The same release and hash as [agent-security-benchmark](https://github.com/heyvaldemar/agent-security-benchmark) pins.
- **The load generator unchanged.** `loadgen/calls.py` imports capacity.py from the verified release and wraps two of its functions to record what they did, handing back exactly what they returned (ADR 1).
- **The server and the weights the release's.** `images.lock` pins the release's CPU and CUDA llama-server, its Python and its busybox by the digests the release pins. `models.lock` carries the release's lines for the models both serve, byte for byte. The CPU server runs with the release's arguments for its evals. `scripts/validate.sh` fails on any difference (checks `pins`, `models`, `args`), and `tests/static-plants.tsv` shows it each difference.
- **The weights checked twice.** `scripts/models.sh` downloads a file only by its line in `models.lock`, from the publisher's URL at the pinned revision, refuses one whose sha256 differs, and refuses a licence that is not a permissive OSI one. The server's pod hashes the file again before the server starts, and every e2e run shows that a pod told another sha256 refuses the same file.

## Consequences

- Moving to a new flagship release is a change to `sources.lock` and, where the release moved a pin, to `images.lock` or `models.lock` in the same commit; the static checks say which.
- Models the flagship does not ship (the sizes of the size curve, a fine-tuned model) get lines of their own in `models.lock`, in the same format and held to the same download rules, and say so.
- The GPU server's arguments are the flagship's GPU server's (`manifests/inference/llama-gpu.yaml` there). They differ from the CPU server's on purpose, and the README names both.

## Alternatives

- **A load generator of this repository's own.** It would measure something the flagship's rows did not.
- **Vendor the flagship's files.** A copy drifts without anyone noticing; a verified release does not.

## How this is explained to a customer

When the question is "what does this card change", everything but the card is held fixed and shown to be fixed: the same signed release, the same image digests, the same weights' hashes, checked by a machine on every run.
