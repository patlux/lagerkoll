.PHONY: help verify build build-release test lint image-test image-build image-publish dry-run changeset changeset-status changeset-test hooks-install version

PYTHON ?= python3
ZIG := mise x -- zig
# Your list (config.example.json shows the format); not part of the repository.
LIST ?=
# Compared with, never written by --dry-run. Without the file the run counts as the first.
STATE ?= zig-out/no-state.json
# Where the image goes, without a tag, e.g. registry.example.org/ikea-checker.
IMAGE_REPOSITORY ?=
# CA bundle and crane for the image, from one pinned nixpkgs revision.
NIXPKGS ?= github:NixOS/nixpkgs/2efa67fd26b6df417c33e4603185c701f260dd83
CA_BUNDLE = $$(nix build --no-link --print-out-paths $(NIXPKGS)\#cacert)/etc/ssl/certs/ca-no-trust-rules-bundle.crt
CRANE = $$(nix build --no-link --print-out-paths $(NIXPKGS)\#crane)/bin/crane

help:
	@printf '%s\n' 'make verify            changeset tests and status, build, fmt, tests (Debug, ReleaseSafe), ziglint'
	@printf '%s\n' 'make build-release     zig-out/bin/ikea-checker with -Doptimize=ReleaseSafe'
	@printf '%s\n' 'make image-build       IMAGE_REPOSITORY=…: zig-out/image/ikea-checker-VERSION.tar (linux/amd64), pushes nothing'
	@printf '%s\n' 'make image-publish     IMAGE_REPOSITORY=…: push the released version, print the digest'
	@printf '%s\n' 'make dry-run           LIST=…: ask IKEA once for LIST against STATE; sends nothing, writes nothing'
	@printf '%s\n' 'make changeset         add a release note or an intentional empty changeset'
	@printf '%s\n' 'make changeset-status  validate pending notes and preview the next version'
	@printf '%s\n' 'make changeset-test    test the changeset tool and its hook in disposable repositories'
	@printf '%s\n' 'make hooks-install     install the changeset pre-commit hook once per clone'
	@printf '%s\n' 'make version           prepare a release on a clean main (no commit, tag or push)'

verify: changeset-test changeset-status image-test build test lint

build:
	$(ZIG) build
	$(ZIG) fmt --check build.zig build.zig.zon src

test:
	$(ZIG) build test
	$(ZIG) build test -Doptimize=ReleaseSafe

lint:
	mise x -- ziglint

image-test:
	$(PYTHON) -B scripts/test_image.py

image-build:
	@test -n "$(IMAGE_REPOSITORY)" || { echo 'set IMAGE_REPOSITORY, e.g. registry.example.org/ikea-checker' >&2; exit 2; }
	$(PYTHON) -B scripts/image.py build --repository "$(IMAGE_REPOSITORY)" --ca-bundle "$(CA_BUNDLE)"

# Only a released, committed version on main; never overwrites an existing tag.
image-publish:
	@test -n "$(IMAGE_REPOSITORY)" || { echo 'set IMAGE_REPOSITORY, e.g. registry.example.org/ikea-checker' >&2; exit 2; }
	$(PYTHON) -B scripts/image.py publish --repository "$(IMAGE_REPOSITORY)" --ca-bundle "$(CA_BUNDLE)" --crane "$(CRANE)"

build-release:
	$(ZIG) build -Doptimize=ReleaseSafe

# Live request to IKEA's API; no push, no state written.
dry-run: build
	@test -n "$(LIST)" || { echo 'set LIST to your list, e.g. make dry-run LIST=config.json (format: config.example.json)' >&2; exit 2; }
	./zig-out/bin/ikea-checker check --config $(LIST) --state $(STATE) --dry-run

changeset:
	$(PYTHON) -B scripts/changeset.py add

changeset-status:
	$(PYTHON) -B scripts/changeset.py status

changeset-test:
	$(PYTHON) -B scripts/test_changeset.py

hooks-install:
	$(PYTHON) -B scripts/changeset.py install-hook

version:
	$(PYTHON) -B scripts/changeset.py version
