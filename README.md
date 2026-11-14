# ikea-checker

Watches whether the articles of a shopping list are in stock in one IKEA store, in the needed
quantity, and pushes changes to the phone through ntfy. Zig 0.17.1, no dependencies outside the
standard library.

One call is one check. A scheduler (cron, a launchd agent, a systemd timer, a periodic Nomad job)
calls it regularly; the program itself has no loop, no listener and no daemon. Store, articles and
ntfy server come from a configuration file you keep outside the repository.

Not affiliated with IKEA. It reads the same unofficial API the product pages of ikea.com use; IKEA
can change or close it at any time. Keep the interval moderate (every 30 minutes is plenty: IKEA
updates the figures a few times a day). The pushes are in German.

## What it pushes

| When | Push |
| --- | --- |
| First successful run (no state yet) | `IKEA <store_name>: Überwachung aktiv`, how many articles are there and what is missing |
| An article reaches the needed quantity | `IKEA <store_name>: <name> verfügbar` (or `N Artikel verfügbar`), with the quantity |
| IKEA announces a delivery for a missing article for the first time | `IKEA <store_name>: Nachlieferung angekündigt`, with the date range |
| The third failed request in a row | `IKEA-Prüfung gestört`, once |
| The first good request after that warning | `IKEA-Prüfung läuft wieder` |

Every push about stock ends with what is still missing (`Noch offen: …`) or with
`Alles auf der Liste ist verfügbar.` Nothing else is pushed: the same stock again, an article that
drops below the needed quantity, or a delivery date that moves bring no push. An article that drops
below and comes back is announced again.

If the answer lacks an article (not in the store's range, missing from the answer), the run keeps
what the last run knew about it, so a gap in an answer never announces an article that never left.

## Data source

`GET https://api.ingka.ikea.com/cia/availabilities/sto/<store>?itemNos=<…>&expand=Restocks`
with the header `X-Client-Id` of the IKEA website and `Accept: application/json;version=2`.
This is the API the product pages of ikea.com use; IKEA does not document it. What the program
reads:

- `buyingOption.cashCarry.availability.quantity`: pieces in the store;
- `buyingOption.cashCarry.range.inRange`: whether the store sells the article at all;
- `buyingOption.cashCarry.availability.restocks[]`: announced deliveries (`earliestDate`,
  `latestDate`); without an entry IKEA has no delivery planned in its system, which does not
  prove that none comes.

The stock figures are updated several times a day; the answer has its own `updateDateTime`.

## Commands

```sh
mise install                       # Zig 0.17.1 and ziglint from mise.toml / mise.lock
make verify                        # changesets, build, zig fmt, tests (Debug and ReleaseSafe), ziglint
make dry-run LIST=config.json      # one live request for your list, sends nothing, writes nothing
make build-release                 # zig-out/bin/ikea-checker, ReleaseSafe

zig-out/bin/ikea-checker check --config config.json --state state.json [--dry-run]
zig-out/bin/ikea-checker --version
```

`--dry-run` prints the report and the push the run would send, sends nothing and writes no state;
it needs no ntfy section and no credentials. Exit codes: `0` checked (and pushed if needed), `1`
failed (config, state, IKEA or ntfy; the reason goes to stderr), `2` usage.

## Configuration

A JSON file per list; start from [`config.example.json`](config.example.json). Files named
`/*.json` (except the example), `lists/` and `*.state.json` are ignored by Git, so your list,
state and credentials stay local.

| Field | Meaning |
| --- | --- |
| `store_id` | IKEA's store number (see below) |
| `store_name` | Short name for the pushes, e.g. the town |
| `market` | Optional, default `de/de`: country/language of ikea.com for the link in a push (`at/de`, `gb/en`, …) |
| `items[]` | `item_no` (`306.300.88` or `30630088`), `name` (for the pushes), `quantity` (needed) |
| `ntfy.url` | `https://` server root (optional for `--dry-run`) |
| `ntfy.topic` | Topic for the pushes |
| `ntfy.credentials_file` | File with `user:password` or an access token `tk_…`; must not be readable by group or others |
| `client_id`, `api_url` | Optional; default to the website's client id and `https://api.ingka.ikea.com` |

### Finding the store number

ikea.com lists the stores of a country with their numbers (`id`):

```sh
curl -s https://www.ikea.com/de/de/meta-data/informera/stores-suggested-detailed.json \
  | python3 -c 'import json,sys; [print(s["id"], s["name"]) for s in json.load(sys.stdin)]'
```

Replace `de/de` with your country/language. The article number is the eight-digit number on the
price tag or the product page (`123.456.78`).

## State

The state file (JSON, mode 0600, replaced atomically) keeps per article whether it was available
and whether a delivery was announced, the count of failed runs in a row and whether the warning
went out. If a push fails, the run keeps the old article states, so the next run finds the same
change and tries again. A state file that does not parse stops the run with an error instead of
being overwritten.

## Architecture

| File | Owns |
| --- | --- |
| `src/main.zig` | CLI, the run: config → state → IKEA → evaluation → push → state |
| `src/config.zig` | Parsing and validating the list |
| `src/ikea.zig` | Request URL, request, parsing the answer |
| `src/check.zig` | The rules: status per article, what changed, the push text (pure, no I/O) |
| `src/state.zig` | Loading and atomically saving the state |
| `src/ntfy.zig` | Credentials file, JSON publishing |

The tests use fixed data (`src/testdata/availability.json` is a trimmed real answer) and a
loopback HTTP server for the ntfy request; they make no request to IKEA or ntfy.

## Limitations

- `std.http.Client` in Zig 0.17.1 checks host name, dates and signatures of the server's chain,
  but not whether an issuing certificate is a CA. Someone who can intercept the connection and
  holds any publicly trusted certificate could impersonate a server. The IKEA data is public; for
  ntfy, prefer a server you reach over a private network.
- `std.http.Client` 0.17.1 never sends `privileged_headers`; the credentials go in the
  `Authorization` header with redirects switched off instead (`src/ntfy.zig`).
- The quantity is IKEA's figure for the store, not a reservation. Whether the pieces are in the
  shelf when you arrive is not part of the answer.

## Running it regularly

Any scheduler works; keep the state file on persistent storage and the credentials file private.
Example crontab line:

```sh
*/30 7-21 * * * /usr/local/bin/ikea-checker check --config /etc/ikea-checker/config.json --state /var/lib/ikea-checker/state.json
```

### Container image

`scripts/image.py` writes a linux/amd64 image without Docker: the static binary
(x86_64-linux-musl, ReleaseSafe) and a CA bundle, user 65534, as a reproducible `docker save`
archive; crane pushes it unchanged. Mount the config, the credentials file and a writable state
directory:

```sh
make image-build   IMAGE_REPOSITORY=registry.example.org/ikea-checker   # zig-out/image/…tar, pushes nothing
make image-publish IMAGE_REPOSITORY=registry.example.org/ikea-checker   # released version only; prints the digest
```

`image-publish` runs only on a clean `main` whose version has a `CHANGELOG.md` section and never
overwrites an existing tag. CA bundle and crane come from the nixpkgs revision pinned as `NIXPKGS`
in the `Makefile` (needs Nix).

## License

MIT, see [LICENSE](LICENSE). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
