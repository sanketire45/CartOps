# Runbook: DbPoolExhausted

**Alert**: `DbPoolExhausted`
**Fires when**: `db_client_connections_pending_requests > 0` for 5+ minutes for any service.

## What this means

Threads in the app are waiting to acquire a HikariCP connection from the pool. Pool is fully used, incoming requests are queueing. Latency is already climbing even if no error has fired yet — this is the **leading indicator** before the availability/latency SLO burns.

## Immediate confirm (30 sec)

```bash
# Golden Signals dashboard → pick the alerting service →
# look at "DB Pool connections (active/idle/pending/max)" panel.
# - `active` at the `max` dashed red line AND `pending` > 0 = confirmed exhaustion.
```

## First response — pick the right cause

| Cause | Signal | Fix |
|---|---|---|
| Traffic surge (fine, expand pool) | Request Rate panel also up | Bump `spring.datasource.hikari.maximumPoolSize` + redeploy |
| Slow queries holding connections | `db_client_connections_use_time_milliseconds` p99 up | Identify slow query (Tempo span `db.statement`), add index / rewrite |
| Long transactions (app code) | Use-time histogram p99 >> typical query | Find the `@Transactional` holding too long; split |
| Downstream DB saturated | MySQL CPU/IO high (RDS console / node-exporter) | Scale DB; cache; add read replicas |
| Pool size mis-set (startup default) | Pool `max` shows `<10` for a prod service | Set `maximumPoolSize = 2 * cpu_cores + spindle_count` as baseline |

## Deeper investigation

1. **Which pod?** `sum by (pod) (db_client_connections_pending_requests{service_name="<svc>"})` — single-pod issue (kill that pod) vs all pods (systemic)
2. **Which query?** Tempo traces where `db.statement` present + `duration > 1s`
3. **MySQL side**: `kubectl exec -n ecom mysql-0 -- mysql -e "show processlist"` — are slow queries stuck?

## Why not just make the pool huge?

Each connection = memory in both app and DB. DB has its own `max_connections` ceiling — more app-side connections just moves the queue from app to DB and makes diagnosis harder. Prefer: fix the slow query, not the pool size.
