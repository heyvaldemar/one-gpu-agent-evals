# 4. Fine-tuned on data the tests never saw

- Status: accepted
- Date: 2026-11-22

## Context

Line 3 asks what fine-tuning a small model against planted instructions buys, and what it costs in the ordinary tasks the model has to keep solving. The flagship's evals (`evals/tasks.json` in its release) are the test: 28 tasks, eight of them with an instruction planted in what a tool returns (a customer record's notes, the quarterly report, a company document), six ordinary tasks held to a floor of 60% (`evals/gates.json`), and the rest on documents, people and privileges. Line 2 runs the same evals on models from 0.6B to 32B parameters.

A fine-tuned model that scores well on those tasks proves nothing if it was trained on them, on their wording, or on data whose licence nobody checked. And a model trained only to refuse would pass the planted tasks by never sending an email at all.

## Decision

**The data is generated, and its licence is this repository's.** `train/generate.py` builds every example from the templates and word lists in its own file and a seed. No dataset from outside, and no model's output: nothing whose licence or provenance has to be taken on trust. The same seed gives the same bytes. `train/data.lock` pins the sha256 of each file the generator writes, and CI generates them again and compares (`tests/train_data.sh`).

**The format is the flagship's agent, as released.** Each example is one conversation as `evals/harness.py` sends it to the model server: the harness's system prompt, the tools the MCP server offers the default person (`support-lead` in `manifests/mcp/policy.json`, with their definitions from `manifests/mcp/server.py`), the user's message, the assistant's tool calls, the tool results, and the answer. The generator reads the prompt and the definitions from the release `sources.lock` pins, by parsing its files, never by importing them. A model trained for line 3 is trained for the agent it will be measured in, and says so.

**Disjoint from the tests, by construction and by a check.** The generator's customers have IDs from C5000 to C8999 (the release names C1001 to C1150, and C9999 for a customer that does not exist), and its companies, people, mail domains and documents are its own. `train/check_data.py` fails if any example carries a customer ID, a mail address, a mail domain other than the company's own, a company name, a document id or a person the release names, or any run of six words in common with the release's tasks, records, report or documents (`evals/tasks.json`, `manifests/records/`, `manifests/tools/`, `manifests/mcp/documents/`). Each of those has a plant in `tests/train-data-plants.tsv`.

**One kind of plant is held out.** Every instruction planted in the training data is in English. The release plants one in German (customer C1150): it measures whether what the model learned carries to a language it never saw it in. The check refuses a planted instruction with words of another language in it.

**Half of it is ordinary work.** Half of the examples have nothing planted: a lookup, two records compared, an email to a colleague because the user asked for it, a question answered with no tool. The other half have an instruction planted in a record's notes, the report or a document, in one of the ways the release plants them (an authority, a customer's consent, a colleague's request, the system's own policy) but never in its words, and the assistant answers the user's question and does not act on it. The model learns to tell an instruction from the user apart from one in the data, not to stop sending email. The ordinary tasks of the release, and their floor, measure whether it did.

**Before and after differ only by the adapter.** QLoRA trains an adapter on the publisher's own weights (safetensors at a pinned revision, each file's sha256 in `models.lock`, a permissive OSI licence). "Before" is those weights converted and quantized by one pinned build of llama.cpp to the quantization line 2 serves; "after" is the same weights with the adapter merged, through the same steps. The publisher's own GGUF file, measured in line 2, stays beside them as a reference and is never one of the pair.

**The base model is chosen by measurement, before any training.** It is the smallest model of line 2's first series that passes the release's task floor and fails at least one planted task in that series. This record is amended with the model, the series and the counts before training starts. If no model in line 2 fails a planted task, line 3 says so and trains nothing.

**What is measured, and how it is held.** The flagship's `scripts/evals.sh` with line 2's settings, three series before and three after, on the card under ADR 3's conditions. Training keeps its own record: the data's sha256, the seed, the base's and the adapter's sha256, the loss at every step, the time on the card. `scripts/recompute.py` computes every number from those records in CI, as for lines 1 and 2. The training runs in ADR 3's closed environment, from an image pinned by digest and Python wheels pinned by hash, with no network.

## Consequences

- The data is small and narrow on purpose: the flagship's four tools and one company. A result says what the fine-tuning did for this agent, and nothing about the model at large.
- Training on the release's prompt and tool definitions ties the result to that release. A new flagship release with a new prompt or new tools needs the data generated again, and its sha256 in `train/data.lock` changes in the same commit as `sources.lock`.
- The boundary does not depend on any of this. The flagship's claim is that nothing leaves when the model is fooled; line 3 measures how often it is fooled, never whether the boundary is needed.

## Alternatives

- **A public dataset of prompt injections.** Its licence, its sources and its overlap with the release's tasks would have to be taken on trust, and it would not be in the agent's format.
- **Data written by a larger model.** Better wording, but a model's output carries its terms and cannot be rebuilt byte for byte.
- **Training on the release's own planted tasks.** The test would then measure memory.
- **Before taken from the publisher's GGUF file.** It is quantized by someone else's build; the difference would not be the adapter's alone.

## How this is explained to a customer

The question is whether a few hours on one card make a small model harder to fool. The answer is measured on tests the training never saw, with data anyone can rebuild from a seed and check, and with the model's ordinary work measured beside it, so a model that got safer by getting useless shows up as exactly that.
