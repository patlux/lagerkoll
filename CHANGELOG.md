# Changelog

Versions follow SemVer. Entries come from the Markdown changesets in `.changeset/`.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the local release workflow.

## 0.4.1 - 2026-11-14

### Fixed

- Send the metrics with Connection: close, so a receiver that answers 204 and keeps the connection (VictoriaMetrics) no longer holds the run for a minute; end a run that takes longer than --timeout seconds (default 120), and flush the log after every step.

## 0.4.0 - 2026-11-14

### Added

- Optional run metrics: with a metrics section, every run POSTs a few gauges in the Prometheus text format (last run and last success, failures in a row, push sent, stock per article, duration, CPU, memory) to VictoriaMetrics, a Pushgateway or a similar receiver, so a history and an alert on stalled runs become possible.

## 0.3.0 - 2026-11-14

### Added

- Log every step of a run in order (state, IKEA's answer with the age of its figures, each change, the ntfy message id, the saved state) and end each run with a key=value summary line that includes duration, CPU time and peak memory; errors now go to stdout as error: lines.

## 0.2.0 - 2026-11-14

### Added

- Choose the ikea.com country for the link in a push (market, default de/de), start from config.example.json, and keep your own lists, state and credentials out of Git; the image target takes the registry as IMAGE_REPOSITORY.

### Changed

- The project is now called lagerkoll: the binary, the image and the User-Agent use the new name. The README starts with a quick start.

## 0.1.0 - 2026-11-14

### Added

- Check the stock of a shopping list in one IKEA store and push to ntfy when an article reaches the needed quantity or a delivery is announced, with a dry run that sends nothing.
