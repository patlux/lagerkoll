# lagerkoll

**Get a push on your phone when the IKEA articles on your list are in stock at your store.**

You have a shopping list for a wardrobe, and two of the parts are sold out at your IKEA. lagerkoll
checks the store's stock for the whole list on a schedule. It sends a message through
[ntfy](https://ntfy.sh) when a missing article reaches the quantity you need, or when IKEA
announces a delivery for it. A small static CLI in Zig, with no dependencies outside the standard
library.

```text
IKEA Musterstadt: Flisberget Tür verfügbar

Jetzt da:
- Flisberget Tür: 72 Stück (du brauchst 9)

Noch offen:
- Översidan 46cm: 0/4
```

*lagerkoll* is Swedish for “stock check” (*lager* = stock, *koll* = check).

> Not affiliated with IKEA. lagerkoll reads the same unofficial availability API that the product
> pages of ikea.com use. IKEA can change or close it at any time. Keep the interval moderate:
> IKEA updates the figures only a few times a day, so every 30 minutes is plenty.
> The push texts are in German.

## Quick start

**1. Build.** You need [Zig 0.17.1](https://ziglang.org/download/). With [mise](https://mise.jdx.dev),
`mise install` installs the pinned toolchain.

```sh
zig build -Doptimize=ReleaseSafe          # → zig-out/bin/lagerkoll
```

**2. Find your store number.** ikea.com lists the stores of a country with their numbers (`id`):

```sh
curl -s https://www.ikea.com/de/de/meta-data/informera/stores-suggested-detailed.json \
  | python3 -c 'import json,sys; [print(s["id"], s["name"]) for s in json.load(sys.stdin)]'
```

Replace `de/de` with your country and language, e.g. `at/de`, `ch/de`, `gb/en`, `se/sv`.

**3. Write your list.** Copy [`config.example.json`](config.example.json) to `config.json`. Fill in
the store, and for each article the eight-digit number from the price tag or the product page
(`123.456.78`), a name for the pushes and how many pieces you need:

```json
{
  "store_id": "123",
  "store_name": "Musterstadt",
  "items": [
    { "item_no": "123.456.78", "name": "Flisberget Tür", "quantity": 9 },
    { "item_no": "876.543.21", "name": "Översidan 46cm", "quantity": 4 }
  ]
}
```

**4. Try it.** A dry run asks IKEA once and shows what it would push. It sends nothing and writes
nothing:

```sh
zig-out/bin/lagerkoll check --config config.json --state state.json --dry-run
```

```text
2026-11-14T20:15:33Z lagerkoll 0.3.0 --dry-run
state: none, first run
IKEA: HTTP 200, 2 of 2 articles in the answer, figures updated 2026-11-14T17:27:14.000Z to 2026-11-14T19:21:12.000Z
IKEA Musterstadt (123): 1 of 2 available
  out    12345678        0/9  Flisberget Tür  (delivery 19.11.–26.11.)
  ok     87654321       45/4  Översidan 46cm
push: dry run, not sent: IKEA Musterstadt: Überwachung aktiv
…
summary result=ok push=dry_run available=1/2 new_available=0 new_restock=0 duration_ms=242 cpu_ms=37 maxrss_kib=15040
```

**5. Connect ntfy and run it on a schedule.** Add the `ntfy` section (see
[Configuration](#configuration)), subscribe to the topic in the ntfy app, and let a scheduler
call `lagerkoll check` without `--dry-run` (see [Running it regularly](#running-it-regularly)).

## What it pushes

| When | Push |
| --- | --- |
| First successful run (no state yet) | `IKEA <store>: Überwachung aktiv`: how many articles are there, what is missing |
| An article reaches the needed quantity | `IKEA <store>: <article> verfügbar` (or `N Artikel verfügbar`), with the quantity |
| IKEA announces a delivery for a missing article for the first time | `IKEA <store>: Nachlieferung angekündigt`, with the date range |
| The third failed check in a row | `IKEA-Prüfung gestört`, once |
| The first good check after that warning | `IKEA-Prüfung läuft wieder` |

Every push about stock ends with what is still missing (`Noch offen: …`), or with
`Alles auf der Liste ist verfügbar.` If exactly one article became available, tapping the push opens
the search for it on ikea.com.

Nothing else is pushed. The same stock again, an article that drops below the needed quantity, or
a delivery date that moves bring no push. An article that drops below and comes back is announced
again. If IKEA's answer lacks an article, the run keeps what it knew before, so a gap in one
answer never announces an article that never left.

## Configuration

One JSON file per list. Git ignores `/*.json` (except the example), `lists/` and `*.state.json`,
so your list, your state and your credentials stay local.

| Field | Meaning |
| --- | --- |
| `store_id` | IKEA's store number ([Quick start](#quick-start), step 2) |
| `store_name` | Short name for the pushes, e.g. the town |
| `items[]` | `item_no` (`123.456.78` or `12345678`), `name` (for the pushes), `quantity` (pieces needed); up to 50 |
| `market` | Optional, default `de/de`: ikea.com country/language for the link in a push |
| `ntfy.url` | `https://` server root, e.g. `https://ntfy.sh` or your own server |
| `ntfy.topic` | Topic for the pushes |
| `ntfy.credentials_file` | Path to a file that holds `user:password` or an ntfy access token `tk_…` |
| `metrics.url` | Optional: `http(s)://` endpoint that takes the Prometheus text format, see [Metrics](#metrics) |
| `metrics.job` | Optional, default `lagerkoll`: value of the `job` label |
| `client_id`, `api_url` | Optional; default to the website's client id and `https://api.ingka.ikea.com` |

The `ntfy` section is needed for real runs only. lagerkoll refuses a credentials file that group
or others may read (`chmod 600`). It sends the credentials only to the configured server and never
follows a redirect with them.

**State.** The state file holds, per article, whether it was available and whether a delivery was
announced. It also counts the failed checks in a row. It is written atomically with mode 0600.
If a push fails, the run keeps the old states, so the next run finds the same change and tries
again. A state file that does not parse stops the run instead of being overwritten.

**Logs.** Every run writes its report to stdout, in order: a header with time and version, the
state it starts from, IKEA's answer (HTTP status, how many articles came back, when IKEA last
updated the figures), one line per article (`NEW: available`, `NEW: delivery announced` mark the
changes), what was pushed (with ntfy's message id) and the saved state. Errors appear in the same
stream as `error: …`. The last line is always a `summary` with `key=value` pairs, so a scheduler's
log can be checked with one grep:

```text
summary result=ok push=sent ntfy_id=hR3x9 available=21/22 new_available=1 new_restock=0 failures=0 duration_ms=812 cpu_ms=41 maxrss_kib=15040
```

| Key | Meaning |
| --- | --- |
| `result` | `ok` or `failed` (same as the exit code) |
| `push` | `none`, `sent`, `failed`, `dry_run` |
| `ntfy_id` | ntfy's id of the message that was sent |
| `error` | why the run failed: `config`, `state`, `credentials`, `ntfy`, or the error of the IKEA request |
| `available` | articles with the needed quantity / articles on the list |
| `new_available`, `new_restock` | articles that became available / got a delivery announced in this run |
| `failures` | failed runs in a row after this run |
| `metrics` | `sent`, `failed`, `skipped` (dry run); absent without a `metrics` section |
| `duration_ms`, `cpu_ms`, `maxrss_kib` | wall time, CPU time and peak memory of the run |

**Timeout.** `--timeout SECONDS` (default 120) ends a run that hangs, e.g. on a server that
stops answering, so a scheduler that prevents overlapping runs is not blocked.

**Exit codes.** `0` checked (and pushed if needed), `1` failed (config, state, IKEA or ntfy; the
reason is in the log), `2` usage (the usage goes to stderr).

## Running it regularly

lagerkoll has no loop and no daemon: every call is one check. Keep the state file on persistent
storage.

**cron**

```sh
*/30 7-21 * * * /usr/local/bin/lagerkoll check --config /etc/lagerkoll/config.json --state /var/lib/lagerkoll/state.json
```

**systemd timer**

```ini
# /etc/systemd/system/lagerkoll.service
[Service]
Type=oneshot
DynamicUser=yes
StateDirectory=lagerkoll
LoadCredential=ntfy:/etc/lagerkoll/ntfy
ExecStart=/usr/local/bin/lagerkoll check --config /etc/lagerkoll/config.json --state /var/lib/lagerkoll/state.json

# /etc/systemd/system/lagerkoll.timer
[Timer]
OnCalendar=*-*-* 07..21:00/30
[Install]
WantedBy=timers.target
```

With `LoadCredential`, set `ntfy.credentials_file` to `/run/credentials/lagerkoll.service/ntfy`.

**Container (Podman, Docker, Nomad, Kubernetes CronJob)**

The image holds only the static binary and a CA bundle, and runs as user 65534 by default. Mount
the config, the credentials file and a state directory. The simplest way to get the permissions
right is to run as your own user, who owns the files (`chmod 600 ntfy-credentials`):

```sh
mkdir -p state
podman run --rm --userns=keep-id --user "$(id -u):$(id -g)" \
  -v ./config.json:/config.json:ro \
  -v ./ntfy-credentials:/secrets/ntfy:ro \
  -v ./state:/state \
  registry.example.org/lagerkoll:0.1.0 \
  check --config /config.json --state /state/state.json
```

With Docker, drop `--userns=keep-id`. In the config, `ntfy.credentials_file` is then
`/secrets/ntfy`.

There is no public image yet. Build it yourself (needs Nix for the pinned CA bundle and crane; no
Docker):

```sh
make image-build   IMAGE_REPOSITORY=registry.example.org/lagerkoll   # zig-out/image/…tar, pushes nothing
make image-publish IMAGE_REPOSITORY=registry.example.org/lagerkoll   # released version only; prints the digest
```

`scripts/image.py` writes the linux/amd64 image as a reproducible `docker save` archive: the same
tree and CA bundle give the same bytes. `image-publish` runs only on a clean `main` whose version
has a `CHANGELOG.md` section, and it never overwrites an existing tag.

## Metrics

A scheduler's logs usually last hours or days, and nobody notices a job that silently stops.
With a `metrics` section, lagerkoll POSTs a few gauges in the Prometheus text format after every
run, also after a failed one. It sends them without timestamps, so they work with VictoriaMetrics
(`…/api/v1/import/prometheus`), a Prometheus Pushgateway (`…/metrics/job/lagerkoll`) and other
receivers of the format. A failed metrics request is logged and does not fail the run.

```json
"metrics": { "url": "http://victoriametrics.example:8428/api/v1/import/prometheus" }
```

| Metric | Meaning |
| --- | --- |
| `lagerkoll_last_run_timestamp_seconds` | Unix time of the run |
| `lagerkoll_last_success_timestamp_seconds` | Unix time of the last successful run (0 if none) |
| `lagerkoll_run_success`, `lagerkoll_consecutive_failures` | result of this run, failed runs in a row |
| `lagerkoll_push_sent` | 1 if this run sent a push |
| `lagerkoll_articles`, `lagerkoll_articles_available` | articles on the list / with the needed quantity |
| `lagerkoll_article_quantity{item_no,name}`, `lagerkoll_article_needed{item_no,name}` | stock and need per article |
| `lagerkoll_run_duration_seconds`, `lagerkoll_run_cpu_seconds`, `lagerkoll_run_max_rss_bytes` | resources of the run |

Every series carries `job` and `store` labels. An alert on
`time() - max_over_time(lagerkoll_last_success_timestamp_seconds[3h]) > 7200` notices both failing
runs and runs that stopped altogether.

## How it works

One request per run, for all articles of the list:

```text
GET https://api.ingka.ikea.com/cia/availabilities/sto/<store>?itemNos=<a>,<b>,…&expand=Restocks
X-Client-Id: <client id of the ikea.com website>
Accept: application/json;version=2
```

lagerkoll reads three fields per article:

- `buyingOption.cashCarry.availability.quantity`: pieces in the store.
- `buyingOption.cashCarry.range.inRange`: whether the store sells the article at all.
- `buyingOption.cashCarry.availability.restocks[]`: announced deliveries (`earliestDate`,
  `latestDate`). Without an entry, IKEA has no delivery planned in its system. That does not
  prove that none comes.

An article counts as available when the quantity is at least what you need. Then lagerkoll
compares with the last run and publishes at most one message to ntfy (JSON publishing).

| File | Owns |
| --- | --- |
| `src/main.zig` | CLI and the run: config → state → IKEA → evaluation → push → state |
| `src/config.zig` | Parsing and validating the list |
| `src/ikea.zig` | Request URL, request, parsing the answer |
| `src/check.zig` | The rules: status per article, what changed, the push text (pure, no I/O) |
| `src/state.zig` | Loading and atomically saving the state |
| `src/ntfy.zig` | Credentials file and publishing |
| `src/metrics.zig` | Optional run metrics in the Prometheus text format |

### Limitations

- The quantity is IKEA's figure for the store, not a reservation. Whether the pieces are on the
  shelf when you arrive is not part of the answer.
- The API is not documented. The meaning of the fields comes from their names and from comparing
  the answers with ikea.com.
- `std.http.Client` in Zig 0.17.1 checks the host name, dates and signatures of the server's
  certificate chain, but not whether an issuing certificate is a CA. An attacker who can intercept
  the connection and holds any publicly trusted certificate could impersonate a server. The IKEA
  data is public; for ntfy, prefer a server you reach over a private network.
- `std.http.Client` 0.17.1 never sends `privileged_headers`. lagerkoll sends the credentials in
  the ordinary `Authorization` header instead, with redirects switched off.
- `std.http.Client` 0.17.1 has no timeouts, and it reads the body of a `204 No Content` without
  `Content-Length` until the server closes the connection. lagerkoll ends a run that takes longer
  than `--timeout` seconds (default 120) with exit code 1 and `summary result=failed error=timeout`,
  and sends the metrics with `Connection: close`. A run that times out is not counted as a failure
  in the state; the metrics (`lagerkoll_last_success_timestamp_seconds`) still show it.

## Development

```sh
make verify                    # changesets, build, zig fmt, tests (Debug and ReleaseSafe), ziglint
make dry-run LIST=config.json  # one live request for your list
```

The tests use fixed data and make no request to IKEA or ntfy.
`src/testdata/availability.json` is a trimmed real answer; the ntfy request is tested against a
loopback HTTP server. Every commit carries a changeset; see [CONTRIBUTING.md](CONTRIBUTING.md).
Changes are listed in [CHANGELOG.md](CHANGELOG.md).

## License

MIT, see [LICENSE](LICENSE). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
