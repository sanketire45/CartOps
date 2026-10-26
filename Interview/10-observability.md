# 10 — Observability & Monitoring

> Tags: **[G]** conceptual · **[S]** scenario
> Project: Prometheus + Grafana + Loki (planned after Phase 3 stable),
> Spring Boot Actuator /actuator/prometheus endpoint

---

## 1. The three pillars

> Metrics — numeric time-series (CPU, request rate, error rate) → Prometheus.
> Logs — text events from processes → Loki / CloudWatch.
> Traces — request path across services → Jaeger / Tempo / X-Ray.
> Why you need all three: metrics tell you WHAT is wrong, logs tell you WHY, traces tell you WHERE.

<!-- ADD QUESTIONS HERE -->

---

## 2. Prometheus

> Pull-based scraping model, PromQL, time-series database,
> ServiceMonitor CRD (kube-prometheus-stack), alerting rules,
> Alertmanager for routing alerts (PagerDuty, Slack).

<!-- ADD QUESTIONS HERE — fill when monitoring is implemented -->

---

## 3. Grafana

> Dashboards connecting to Prometheus + Loki data sources,
> pre-built dashboards (node-exporter, kube-state-metrics),
> custom dashboards for Spring Boot Actuator metrics.

<!-- ADD QUESTIONS HERE -->

---

## 4. Loki (log aggregation)

> Like Prometheus but for logs, label-based indexing (not full-text),
> Fluent Bit DaemonSet ships logs from each node to Loki,
> LogQL query language, correlating logs with Grafana metrics panels.

<!-- ADD QUESTIONS HERE -->

---

## 5. Spring Boot Actuator

> `/actuator/health` — liveness/readiness probe endpoint.
> `/actuator/prometheus` — exposes metrics in Prometheus format.
> `/actuator/info` — build/git info.
> Why Actuator endpoints must be on a separate management port in production (not exposed via Ingress).

<!-- ADD QUESTIONS HERE -->

---

## 6. Alerting strategy

> What to alert on vs what to record (SLIs/SLOs),
> alert fatigue, severity levels (page vs ticket vs log),
> golden signals: latency, traffic, errors, saturation.

<!-- ADD QUESTIONS HERE -->

---

## 7. Falco (runtime security observability)

> See [02-security.md](02-security.md) Layer 6 — Falco watches syscalls, sends security events.
> Can forward to Grafana as a security dashboard alongside metrics.
