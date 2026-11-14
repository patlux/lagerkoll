# Contributing and releases

Changes are collected as changesets, versioned together in a release, and installed only from a
release. The tool is `scripts/changeset.py`: Python 3.11+, Git and Make, no packages and no hook
manager.

## Once per clone

```sh
make hooks-install
```

The installer refuses to replace an existing hook or a configured `core.hooksPath`. With a hook
manager, call `python3 -B scripts/changeset.py check-staged` from its pre-commit step instead.

## Every commit carries a new changeset

```sh
make changeset                                                  # interactive
python3 -B scripts/changeset.py add --type fixed --bump patch "Count a failed push as a failed run."
python3 -B scripts/changeset.py add --empty                     # docs, tests, tooling, refactoring
```

Stage the new file in `.changeset/` with the change it describes. Write the note for readers of
the changelog, not as a copy of the commit message.

| Field | Values |
| --- | --- |
| `type` | `added`, `changed`, `fixed`, `removed`: the changelog section |
| `bump` | `patch`: compatible fix, `minor`: compatible feature, `major`: incompatible change |

An empty changeset is exactly two `---` lines: no changelog entry and no version bump. The
highest pending bump wins; bumps do not add up.

The hook (`check-staged`) rejects a commit without a new changeset, an invalid note, a deleted
pending note and a version change outside a release. Never bypass the hook (`--no-verify`).

## Version

The single version is the `.version` line of `build.zig.zon`; `build.zig` reads it for
`--version` and the User-Agent header. Do not change it by hand: only `make version` does.

## Release

Only when a release is wanted, on a clean `main`:

```sh
make changeset-status       # the pending notes and the next version
make version                # build.zig.zon .version, CHANGELOG.md, consumes the notes
git diff                    # review
make verify
git add build.zig.zon CHANGELOG.md
git add -u .changeset
git commit -m "version bump to vX.Y.Z"
```

`make version` never commits, tags or pushes. No push, tag or hosted release without an explicit
request. Deploy only a released version.

## Checks

`make verify` runs the changeset tests and status, the build, `zig fmt --check`, the tests in
Debug and ReleaseSafe and ziglint. After changing the changeset tool, `make changeset-test`.
