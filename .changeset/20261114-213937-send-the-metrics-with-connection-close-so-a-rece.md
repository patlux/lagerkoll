---
type: fixed
bump: patch
---

Send the metrics with Connection: close, so a receiver that answers 204 and keeps the connection (VictoriaMetrics) no longer holds the run for a minute; end a run that takes longer than --timeout seconds (default 120), and flush the log after every step.
