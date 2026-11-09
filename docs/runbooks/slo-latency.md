# Runbook: SLO burn — latency

**Alert**: `ProductCategoryLatency` / `OrderServiceLatency`
**Fires when**: multi-window burn rate on "requests slower than threshold" exceeds budget.

## What this means

More requests are completing above the latency threshold than the SLO allows. Service is "slow but working" — the availability SLO may still be green.

## Immediate confirm (30 sec)

```bash
# Open the SLO dashboard → pick service → select SLO "requests-latency"
# Burn Rate (1h) stat tells you fast-burn (page) vs slow drift (ticket)

# Which endpoint is slow?
kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80
# Grafana → Ecom → "Golden Signals" → look at Request Latency (p50/p95/p99) panel
# p99 only climbing → tail problem; all climbing → systemic
```

## First response

| Pattern | Likely cause | Fix |
|---|---|---|
| p99 only spiked | Specific slow code path | Find trace in Tempo (M14), optimize that endpoint |
| All percentiles rising | DB saturation | Check DB Pool Used % on golden-signals dashboard |
| Started after deploy | Code regression | `kubectl rollout undo deployment/<service> -n ecom` |
| Correlates with pod restarts | JVM warmup / cold cache | HPA, reduce pod restarts |
| DB pool pending > 0 | Connection exhaustion | See [db-pool-exhausted.md](db-pool-exhausted.md) |

## Deeper investigation

1. **Tempo trace**: filter by `service.name=<service>` and `duration > 300ms` — look for the slow span
2. **DB queries**: p99 of `db_client_connections_use_time_milliseconds` for this service — individual query time
3. **GC pauses**: `rate(jvm_gc_duration_seconds_sum[5m])` — long GCs stall every request

## Why latency SLOs matter

Availability catches hard errors. Latency catches *silent* degradation — the user who waits 5 seconds then abandons without you ever seeing a 5xx.
