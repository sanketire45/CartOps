# 10 — Observability & Monitoring

> Tags: **[G]** conceptual · **[S]** scenario
> Project: Spring Boot Actuator endpoints, Prometheus + Grafana + Loki planned (after Phase 3 stable),
> Falco runtime security events → see [01-kubernetes-core.md § Security Layer 6](01-kubernetes-core.md)

---

## Sections
1. [The Three Pillars](#1-the-three-pillars)
2. [Prometheus](#2-prometheus)
3. [Grafana](#3-grafana)
4. [Loki & Log Aggregation](#4-loki--log-aggregation)
5. [Spring Boot Actuator](#5-spring-boot-actuator)
6. [Alerting Strategy](#6-alerting-strategy)
7. [Golden Signals](#7-golden-signals)

---

## 1. The Three Pillars

### Cheat Sheet

| Pillar | Tool | Answers |
|---|---|---|
| Metrics | Prometheus + Grafana | WHAT is wrong — numbers over time |
| Logs | Loki + Fluent Bit | WHY it's wrong — text events |
| Traces | Tempo / Jaeger / X-Ray | WHERE in the call chain — request path |

**The interview one-liner:**
> "Metrics tell you WHAT is broken, logs tell you WHY, traces tell you WHERE in the distributed call chain."

### Questions

**[G] Why do you need all three pillars? Can't logs tell you everything?**
Logs tell you what happened on one service at one moment. Metrics tell you trends and thresholds across all services over time — you can alert on them before users notice. Traces connect a single user request across 5 microservices showing exactly where the 3-second latency is (product-svc took 2.8s of that). Logs alone can't do either. Example: "p99 latency increased 40% after deploy" — only metrics detect this pattern. "Which service caused it" — only traces answer this. "What was the error message in that service" — only logs answer this.

**[G] What is the difference between observability and monitoring?**
Monitoring: you define in advance what to watch (CPU > 80% = alert). Works for known failure modes. Observability: you can ask arbitrary questions about your system's internal state by examining its outputs (metrics, logs, traces) — even for failures you didn't predict. High-observability systems let you debug novel failures because the data is rich enough to form and test hypotheses. Low-observability systems only alert on what you knew to watch for.

---

## 2. Prometheus

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Pull-based | Prometheus scrapes `/metrics` endpoints — services don't push to it |
| PromQL | Time-series query language — `rate(http_requests_total[5m])` |
| ServiceMonitor CRD | kube-prometheus-stack — tells Prometheus which services to scrape |
| TSDB | Time-series database — efficient for metric data, not for logs |
| Alertmanager | Routes alerts to Slack/PagerDuty based on labels and severity |
| Retention | Default 15 days local storage — export to S3/Thanos for long-term |

### Questions

**[G] Push vs pull — why does Prometheus pull instead of services pushing metrics?**
Pull-based: Prometheus knows exactly which services exist (via service discovery) and can detect when a service disappears (scrape fails). If a service dies and stops pushing, a push-based system sees nothing — silent failure. With pull: the scrape fails → Prometheus fires a "target down" alert. Also: a misconfigured service that pushes too fast can overwhelm a push-based server. With pull, Prometheus controls the rate. The trade-off: short-lived jobs (Kubernetes Jobs) may finish before being scraped — use Pushgateway for those.

**[G] What is a ServiceMonitor?**
A CRD from kube-prometheus-stack that tells Prometheus which services to scrape and how. Without it you'd have to manually edit Prometheus's config file to add every new service. ServiceMonitor selects services by label: `selector: matchLabels: app: product-category` + the metrics path and port. When you add a new microservice, you add a ServiceMonitor for it — Prometheus automatically picks it up via its operator. Our Spring Boot services expose `/actuator/prometheus` which returns all Micrometer metrics in Prometheus format.

<!-- Fill with project-specific answers when monitoring is implemented -->

---

## 3. Grafana

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Data sources | Connects to Prometheus (metrics), Loki (logs), Tempo (traces) — all in one UI |
| Dashboard | Visual panels — graphs, gauges, tables — from PromQL queries |
| Pre-built dashboards | node-exporter dashboard (node CPU/mem), kube-state-metrics (pod states) — import by ID |
| Alerting | Grafana can alert on Prometheus queries — alternative to Alertmanager |
| Spring Boot dashboard | ID 12900 — pre-built dashboard for Spring Boot Actuator + Micrometer metrics |

### Questions

**[G] Grafana vs just using Prometheus UI — why use Grafana?**
Prometheus UI is for ad-hoc PromQL queries — not shareable, not persistent, not combined with other data sources. Grafana: persistent dashboards, multi-data-source panels (Prometheus + Loki side by side), team sharing, variables (drop-down to switch between services), annotations (mark when a deploy happened on a graph). For operations teams — Grafana is the single pane of glass. Prometheus UI is for debugging.

<!-- Fill with project-specific answers when monitoring is implemented -->

---

## 4. Loki & Log Aggregation

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Loki | Like Prometheus but for logs — label-based indexing, not full-text |
| Fluent Bit | DaemonSet — one pod per node — ships logs from node's `/var/log/containers/` to Loki |
| LogQL | Loki's query language — `{app="product-category"} |= "ERROR"` |
| Label-based | Only indexes labels (namespace, pod, app) — not full log text. Cheaper storage. |
| Correlate with Grafana | Click a spike in Prometheus → jump to Loki logs for that time window |

### Questions

**[G] Loki vs Elasticsearch for log aggregation — what's the difference?**
Elasticsearch: full-text indexed — every word in every log is indexed and searchable. Fast queries, expensive storage and compute. Loki: only indexes labels (app, namespace, pod name). Log content is compressed and stored unindexed. To search content you filter by label first, then grep the content. Much cheaper to run. Trade-off: Loki is slower for content searches, Elasticsearch is faster. For Kubernetes logs where you always filter by pod/app first anyway, Loki's model is efficient and cost-effective.

**[G] How does Fluent Bit ship logs to Loki?**
Fluent Bit runs as a DaemonSet — one pod per node. It tails `/var/log/containers/*.log` on the node's filesystem (all container logs land here via the container runtime). It parses the JSON log format, adds K8s metadata labels (pod name, namespace, app label), and forwards to Loki. Loki stores the log lines with those labels. No application changes needed — the app just writes to stdout, everything else is infrastructure.

<!-- Fill with project-specific answers when monitoring is implemented -->

---

## 5. Spring Boot Actuator

### Cheat Sheet

| Endpoint | Purpose |
|---|---|
| `/actuator/health/liveness` | Is the app alive? Fail = kubelet restarts pod |
| `/actuator/health/readiness` | Is the app ready for traffic? Fail = removed from Service endpoints |
| `/actuator/prometheus` | All Micrometer metrics in Prometheus format — JVM, HTTP requests, custom |
| `/actuator/info` | Build info, git commit, version |
| Management port | Expose Actuator on a separate port (e.g. 8081) — NOT via Ingress to the internet |

### Questions

**[G] Why separate the management port from the application port?**
The Actuator endpoints must never be exposed to the internet via Ingress. `/actuator/health` returns info about the app's internal state. `/actuator/env` can expose config values. `/actuator/threaddump` is a debug tool. If exposed via the main Ingress port (8080), anyone can call them. Separate management port (8081) → exposed only inside the cluster for Prometheus scraping and K8s probe calls — not reachable via the NLB.

**[G] How do liveness and readiness probes use Actuator?**
Liveness probe calls `/actuator/health/liveness` — Spring sets this to DOWN only if the app is in an unrecoverable state (deadlocked thread, corrupted internal state). DOWN = kubelet restarts the pod. Readiness probe calls `/actuator/health/readiness` — Spring sets this to DOWN when the app can't serve traffic (warming up, downstream dependency down, DB unavailable). DOWN = removed from Service endpoints, no traffic sent. Readiness recovers automatically when the dependency comes back.

---

## 6. Alerting Strategy

### Cheat Sheet

| Concept | Key Point |
|---|---|
| Alert on symptoms not causes | Alert on "users getting errors", not "CPU is high" |
| Severity levels | Page (wake someone up) vs ticket (fix tomorrow) vs log (just record) |
| Alert fatigue | Too many low-signal alerts → oncall ignores all alerts → real incidents missed |
| Inhibition | Suppress child alerts when parent alert is firing (node down → all pods on it alert = noise) |
| Silence | Suppress alerts during maintenance windows |

### Questions

**[G] What should you alert on vs what should you just record?**
Alert (page someone): user-facing symptoms — error rate > 1%, p99 latency > 2s, availability below SLO. These directly impact users and need immediate response. Record (log or dashboard): causes — CPU > 80%, disk > 70%, GC time increasing. These are early warning signs, not emergencies. Alerting on causes creates alert fatigue: CPU spikes constantly, disk fills predictably, GC runs every minute. Alert on the symptom (errors, latency) — the cause investigation happens after you know users are affected.

---

## 7. Golden Signals

### Cheat Sheet

> The four golden signals (Google SRE Book) — the minimum viable set of metrics for any service.

| Signal | What to Measure | PromQL idea |
|---|---|---|
| Latency | How long requests take (p50, p95, p99) | `histogram_quantile(0.99, rate(http_duration_bucket[5m]))` |
| Traffic | How many requests per second | `rate(http_requests_total[5m])` |
| Errors | What fraction of requests fail | `rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])` |
| Saturation | How full is the system (CPU %, memory %, queue depth) | `container_cpu_usage_seconds_total` |

### Questions

**[G] What are the four golden signals and why these four?**
Google SRE defines these as the minimum metrics that capture all user-visible service health: (1) Latency — slow requests are a form of failure. (2) Traffic — context for errors and saturation (high error rate at 10 RPS is different from 10,000 RPS). (3) Errors — the direct user impact. (4) Saturation — leading indicator before failure. If all four are healthy, users are happy. If any degrades, users are affected or will be soon. Start here before adding service-specific metrics.
