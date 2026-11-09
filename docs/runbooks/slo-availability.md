# Runbook: SLO burn — availability

**Alert**: `ProductCategoryAvailability` / `OrderServiceAvailability`
**Fires when**: multi-window burn rate exceeds threshold (see [M8 ladder](#the-4-alert-ladder)).

## What this means

A service is returning 5xx responses faster than the SLO's monthly error budget allows. Users ARE being hurt right now.

## Immediate confirm (30 sec)

```bash
# 1. Open the SLO dashboard — is burn rate still climbing or recovering?
kubectl port-forward -n observability svc/kube-prom-stack-grafana 3000:80
# Grafana → Ecom → "SLO — Ecom Services" → pick the service in dropdown

# 2. Which endpoint is erroring?
kubectl logs -n ecom -l app=<service> --tail=100 | grep -iE 'error|exception|5[0-9]{2}'
```

## First response

| Symptom | Likely fix |
|---|---|
| Just started, recent deploy | `kubectl rollout undo deployment/<service> -n ecom` |
| 503 Service Unavailable | Pod not ready — `kubectl get pods -n ecom` |
| 500 Internal Server Error on DB endpoints | DB health: `kubectl get pods mysql-0 -n ecom` |
| 5xx on one endpoint only | Likely a downstream dependency — check its own SLO dashboard |

## Deeper investigation

1. **Trace**: Grafana → Explore → Tempo → filter by `service.name=<service>` and `status=error`
2. **Logs**: Kibana (once M12 lands) → filter by `k8s.namespace=ecom` + `level>=ERROR`
3. **Metrics**: on dashboard, check Request Rate (traffic surge?) and p99 Latency (slow cascade?)

## The 4-alert ladder

| Burn | Short/Long | Severity |
|---|---|---|
| 14.4× | 5m + 1h | CRITICAL — page |
| 6× | 30m + 6h | CRITICAL — page |
| 3× | 2h + 1d | WARNING — ticket |
| 1× | 6h + 3d | WARNING — ticket |

A critical fire means ~2% of monthly budget burned in the short window — act now.
