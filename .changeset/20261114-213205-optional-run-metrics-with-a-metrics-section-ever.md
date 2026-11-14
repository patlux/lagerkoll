---
type: added
bump: minor
---

Optional run metrics: with a metrics section, every run POSTs a few gauges in the Prometheus text format (last run and last success, failures in a row, push sent, stock per article, duration, CPU, memory) to VictoriaMetrics, a Pushgateway or a similar receiver, so a history and an alert on stalled runs become possible.
