# 1. Measured on a workstation, recomputed in CI

- Status: accepted
- Date: 2026-11-12

## Context

The flagship, [kubernetes-air-gapped-ai-agent](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent), measures its model server on CPU and on two cloud GPUs, an NVIDIA L4 and an A10G, in runs CI starts, records and signs. The questions this repository asks need a GPU for hours at a time: the same model on one more card, the same planted instructions against models from 1B to 32B parameters, and a small model fine-tuned against them. The GPU here is one RTX 4090 in a workstation. No CI runner runs on it, by design: a runner executes whatever a workflow says, a pull request can say anything, and the machine holds other work this repository must never reach. So a number measured there cannot carry CI's signature.

## Decision

A number from the workstation is published only with what it was computed from, and CI computes it again.

- **The record of every call.** `loadgen/calls.py` runs the flagship's `scripts/capacity.py` unchanged and writes down each call the way capacity.py itself saw it: the seconds, whether it answered, the tokens, the level it belongs to, its seed and its start on the wall clock, and each level's wall time. Nothing is written while a level is timed: a level's records reach the disk when the level ends, so the recording is no part of any call's time.
- **Recomputed, digit for digit.** `scripts/recompute.py check` computes every level's calls a minute, p50, p95, failures, output tokens a second and mean prompt from those records, with capacity.py's formulas and its own percentile function, and fails when one differs from what the series reported. It also fails on records that are not whole: a series that stopped before its end, a level whose count of calls does not match, calls of one level inside another. `tests/recompute.sh` shows it a stub server's series and four damaged copies of it on every run, and `tests/recompute-plants.tsv` breaks the recorder and the recomputation in turn.
- **Named where it was measured.** Every workstation number says "measured on a workstation with an RTX 4090". It is never put in a row with a cloud card's, and never called weekly or daily.
- **The CPU row is CI's own.** The same load generator, against the flagship's CPU server and weights, runs in CI on kind (`tests/e2e.sh`), so the one row a workstation and a runner can both measure is measured by both, and the runner's is signed.

## Consequences

- The recomputation proves that the numbers follow from the records. It cannot prove that the records are true: a machine that wrote false records could write them consistently. What stands behind them is that the scripts are public and pinned, the environment's manifest names everything that ran (the release, the image digests, the weights' hashes, the driver, the power limit), and anyone with the same card can run the same series.
- What a reader of the README can check without trusting the author: every number against its records, every image and weight against the flagship's release, and the CPU row against CI's.
- A series costs nothing in CI minutes beyond the recomputation.

## Alternatives

- **A self-hosted runner on the workstation.** Refused: it would execute code from this repository's workflows, including a pull request's, on a machine that holds other work.
- **A signing key on the workstation.** A key there signs whatever the machine says. It would prove who published a record, which the commit already shows, and nothing about whether the record is true.
- **Publish the aggregates only.** That is a number to be taken on trust, which this fleet does not publish.

## How this is explained to a customer

Some measurements need hardware CI does not have: your GPUs, in your data centre. The answer is the same here as there. The run is scripted and pinned, every call is recorded, the published numbers are computed again from the records by anyone who wants to, and the one measurement both sides can make is made by both.
