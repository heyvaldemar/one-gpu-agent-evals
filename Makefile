# make check   the static checks and the recomputation, each shown its breaks (no cluster)
# make up      the verified flagship release, the weights, and a kind cluster
# make test    the CPU row measured on that cluster, every number recomputed
# make down    the kind cluster gone (the release and the weights stay in .cache/)
SHELL := /bin/bash
export PATH := $(CURDIR)/.cache/bin:$(PATH)
FLAGSHIP_DIR = $(shell ./scripts/sources.sh path flagship)

.PHONY: tools check up test down

tools:
	@./scripts/install-tools.sh >/dev/null

check: tools
	./scripts/validate.sh
	FLAGSHIP="$(FLAGSHIP_DIR)" PLANTS=tests/static-plants.tsv python3 -I -u tests/plant-violations.py -- bash scripts/validate.sh
	./tests/recompute.sh
	FLAGSHIP="$(FLAGSHIP_DIR)" PLANTS=tests/recompute-plants.tsv python3 -I -u tests/plant-violations.py -- bash tests/recompute.sh

up: tools
	./scripts/up.sh

test: tools
	./tests/e2e.sh

down:
	./scripts/down.sh
