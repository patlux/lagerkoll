# AGENTS.md

lagerkoll is a Zig 0.17.1 CLI that checks IKEA store stock for a list and pushes changes
through ntfy. What it does, its commands and its layout are in `README.md`.

## Zig

- Before writing or reviewing Zig code, load the skill `zig` (the shared agent skill for Zig 0.17).
- Never write std or build APIs from memory. Check them in the std source of the toolchain
  (`mise x -- zig env`, `.std_dir`).
- Which source wins: compiler and these rules, then the std source, then the skill.
- The toolchain comes from `mise.toml` and `mise.lock`; run commands through mise (`mise x -- zig …`).
  `minimum_zig_version` is advisory only: Zig does not enforce it.
- No dependencies outside std without asking first.

## Changesets and releases

- Read `CONTRIBUTING.md` before committing. Every commit adds a new changeset in `.changeset/`
  with an explicit `type` and `bump`; docs, tests, tooling and refactoring add an explicit empty
  one (`python3 -B scripts/changeset.py add --empty`). Stage it in the same commit; never bypass
  the pre-commit hook.
- The version is the `.version` line of `build.zig.zon`. Only `make version` changes it, on a clean
  `main` and only when a release is asked for; commit that as `version bump to vX.Y.Z`.
- No push, tag or hosted release without an explicit request.

## Checks

- `make verify` before every commit: changeset tests and status, build, `zig fmt --check`, the
  tests in Debug and ReleaseSafe, and ziglint (fails on any finding; fix the finding, do not
  weaken `.ziglint.zon`).
- Tests use fixed data and no live network. `make dry-run` is the one live check: a read-only
  request to IKEA's API; it sends no push and writes no state.

## Data and deployment

- Lists, state and credentials never enter the repository: they stay in Git-ignored files
  (`/*.json` except `config.example.json`, `lists/`, `*.state.json`). Tests use fixed fixtures.
- Deployment-specific values (registry, hosts, schedules) belong to the deployment, not here:
  `make image-build`/`image-publish` take `IMAGE_REPOSITORY`.
- `make image-publish` pushes to a registry; run it only for a release and only when a deployment
  is asked for. It never overwrites a tag.

## Pushes and secrets

- Real runs push to a real phone. Agents run only `--dry-run` unless a real run is asked for.
- Never read, print or copy the ntfy credentials file. A new or rotated credential goes from its
  source straight into a new 0600 file, never through argv, logs or chat.
- Pushes carry article names and quantities only.

## Never

- No contributions to Zig itself (code, issues, comments, chat) written or found with an LLM:
  the Zig Code of Conduct forbids it.
