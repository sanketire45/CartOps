#!/usr/bin/env bash
# =============================================================================
# setup-kibana-m13.sh — M13: Kibana data view + saved searches
# =============================================================================
# Run from repo root:
#   GitOps/elastic/ilm/setup-kibana-m13.sh
#
# What it does:
#   1. Creates data view logs-ecom-* (index pattern for Kibana Discover)
#   2. Creates saved search: Ecom - All App Logs (ecom namespace filter)
#   3. Creates saved search: Ecom - Errors (SeverityNumber >= 17 = OTel ERROR)
#   4. Creates saved search: Ecom - Trace ID Lookup (replace TRACE_ID_HERE)
#
# OTel SeverityNumber mapping (semconv):
#   1-4   TRACE   9-12  DEBUG   13-16 INFO
#   17-20 WARN    21-24 ERROR   21-24 FATAL (ES exporter maps FATAL→17)
#   Use SeverityNumber >= 17 to catch all ERROR/FATAL logs.
#
# Trace ID lookup:
#   After M17, copy a TraceId from Jaeger/Tempo, open this saved search,
#   replace TRACE_ID_HERE with that value → see all logs for that request.
# =============================================================================
set -euo pipefail

NS=observability

echo "==> Getting credentials..."
KB_PASS=$(kubectl get secret -n "$NS" ecom-logs-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)
KB_POD=$(kubectl get pod -n "$NS" -l kibana.k8s.elastic.co/name=ecom-logs \
  -o jsonpath='{.items[0].metadata.name}')

kb() {
  kubectl exec -n "$NS" "$KB_POD" -- \
    curl -sk -u "elastic:${KB_PASS}" \
    -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    "$@"
}

echo "==> 1. Create data view logs-ecom-* ..."
DATA_VIEW=$(kb -X POST 'https://localhost:5601/api/data_views/data_view' \
  -d '{"data_view":{"title":"logs-ecom-*","timeFieldName":"@timestamp","name":"Ecom Application Logs"}}')
DATA_VIEW_ID=$(echo "$DATA_VIEW" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Data view ID: $DATA_VIEW_ID"

echo ""
echo "==> 2. Saved search: All App Logs..."
kb -X POST 'https://localhost:5601/api/saved_objects/search' \
  -d "{\"attributes\":{\"title\":\"Ecom - All App Logs\",\"columns\":[\"Body\",\"Resource.k8s.namespace.name\",\"Resource.k8s.pod.name\"],\"sort\":[[\"@timestamp\",\"desc\"]],\"kibanaSavedObjectMeta\":{\"searchSourceJSON\":\"{\\\"index\\\":\\\"${DATA_VIEW_ID}\\\",\\\"query\\\":{\\\"match_phrase\\\":{\\\"Resource.k8s.namespace.name\\\":\\\"ecom\\\"}},\\\"filter\\\":[]}\"}}}
" | grep -o '"id":"[^"]*"' | head -1

echo ""
echo "==> 3. Saved search: Errors (SeverityNumber>=17)..."
kb -X POST 'https://localhost:5601/api/saved_objects/search' \
  -d "{\"attributes\":{\"title\":\"Ecom - Errors (SeverityNumber>=17)\",\"columns\":[\"Body\",\"Resource.k8s.pod.name\",\"SeverityNumber\"],\"sort\":[[\"@timestamp\",\"desc\"]],\"kibanaSavedObjectMeta\":{\"searchSourceJSON\":\"{\\\"index\\\":\\\"${DATA_VIEW_ID}\\\",\\\"query\\\":{\\\"range\\\":{\\\"SeverityNumber\\\":{\\\"gte\\\":17}}},\\\"filter\\\":[]}\"}}}
" | grep -o '"id":"[^"]*"' | head -1

echo ""
echo "==> 4. Saved search: Trace ID Lookup..."
kb -X POST 'https://localhost:5601/api/saved_objects/search' \
  -d "{\"attributes\":{\"title\":\"Ecom - Trace ID Lookup\",\"description\":\"Replace TRACE_ID_HERE with a TraceId from Jaeger/Tempo\",\"columns\":[\"Body\",\"Resource.k8s.pod.name\",\"@timestamp\"],\"sort\":[[\"@timestamp\",\"asc\"]],\"kibanaSavedObjectMeta\":{\"searchSourceJSON\":\"{\\\"index\\\":\\\"${DATA_VIEW_ID}\\\",\\\"query\\\":{\\\"match\\\":{\\\"TraceId\\\":\\\"TRACE_ID_HERE\\\"}},\\\"filter\\\":[]}\"}}}
" | grep -o '"id":"[^"]*"' | head -1

echo ""
echo "==> Done. Verify at: kubectl port-forward -n observability svc/ecom-logs-kb-http 5601:5601"
echo "    Open: https://localhost:5601 (login: elastic / <secret>)"
echo "    Discover → Data view: Ecom Application Logs → saved searches listed above"
