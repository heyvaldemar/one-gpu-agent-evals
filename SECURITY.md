# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to connect@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

## What this repository is

Measurements and the scripts that make them, not a hosted service. A report here is most likely one of these: a way to make `scripts/recompute.py` accept numbers its records do not carry, a way to make `scripts/sources.sh` accept a release it should refuse, a way to make `scripts/models.sh` keep weights whose hash or licence it should refuse, or something published here that names or locates the machine a series ran on. A weakness in the flagship's server, load generator or tools belongs to [kubernetes-air-gapped-ai-agent](https://github.com/heyvaldemar/kubernetes-air-gapped-ai-agent); one in llama.cpp to [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp).

## Supply chain

- The flagship's release is pinned in `sources.lock` by tag and sha256, and is read only after its cosign signature and its SLSA provenance verify.
- Container images are pinned by digest in `images.lock`, and the static checks fail on one that is not, or that is not the flagship's.
- Model weights are pinned by revision and sha256 in `models.lock`, downloaded only from the publisher, and hashed again by the server's pod before the server starts.
- GitHub Actions are pinned by commit SHA; CLI tools by version and sha256 (`tools.lock`).

## Credentials

None. The models are open weights, CI stores no credential, and the environment a series runs in on the workstation holds none either ([ADR 3](docs/decisions/0003-the-host-lends-the-gpu-the-environment-holds-nothing.md)).
