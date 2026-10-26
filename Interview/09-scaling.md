# 09 — Scaling & Autoscaling

> Tags: **[G]** conceptual · **[S]** scenario
> Project: HPA (#24), Cluster Autoscaler (#26a), Karpenter (#26b), KEDA (#25)

---

## 1. HPA — Horizontal Pod Autoscaler

> Scales pod replicas based on CPU/memory or custom metrics,
> requires metrics-server, `minReplicas`/`maxReplicas`,
> cooldown periods, scale-down stabilisation window.

<!-- ADD QUESTIONS HERE — fill when task #24 is done -->

---

## 2. VPA — Vertical Pod Autoscaler

> Adjusts CPU/memory requests on existing pods (resizes them),
> Off/Initial/Auto modes, why VPA + HPA conflict on CPU metrics,
> when to use VPA vs HPA.

<!-- ADD QUESTIONS HERE -->

---

## 3. Cluster Autoscaler

> Scales the number of nodes based on pending pods,
> works with ASG, reads node group min/max, scale-down delay,
> why it's simpler but slower than Karpenter.

<!-- ADD QUESTIONS HERE — fill when task #26a is done -->

---

## 4. Karpenter

> AWS-native node provisioner, provisions exactly the right instance type
> for pending pods (no fixed node groups), bin-packing,
> NodePool + EC2NodeClass CRDs, consolidation (removes underutilised nodes).

<!-- ADD QUESTIONS HERE — fill when task #26b is done -->

---

## 5. KEDA — Event-driven autoscaling

> Scales pods based on external event sources (SQS queue depth, Kafka lag, etc.),
> ScaledObject CRD, scales to zero when queue is empty,
> use case: notification-worker scales with SQS message count.

<!-- ADD QUESTIONS HERE — fill when task #25 is done -->

---

## 6. Scaling best practices

> Resource requests must be set for HPA to work (scheduler needs them for bin-packing),
> PodDisruptionBudget during scale-down, anti-affinity to spread replicas across AZs,
> readiness probe must pass before pod receives traffic after scale-up.

<!-- ADD QUESTIONS HERE -->
