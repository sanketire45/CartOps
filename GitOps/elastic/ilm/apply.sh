#!/usr/bin/env bash
# =============================================================================
# apply.sh — M12: Bootstrap ILM policy, index template, and write alias
# =============================================================================
# Run from repo root:
#   GitOps/elastic/ilm/apply.sh
#
# What it does:
#   1. Creates (or updates) the ILM policy logs-ecom-policy
#   2. Creates (or updates) the index template logs-ecom-template
#   3. Deletes the flat logs-ecom index (dev data — refills in seconds)
#   4. Bootstraps logs-ecom-000001 with the write alias logs-ecom
#      so ILM rollover works going forward
#
# After this, the OTel ES exporter continues writing to logs-ecom (alias).
# ILM rolls over at 5GB or 1 day → creates logs-ecom-000002, etc.
# Indices older than 7 days from rollover are auto-deleted.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS=observability
ES_SVC=ecom-logs-es-http

echo "==> Getting ES password..."
ES_PASS=$(kubectl get secret -n "$NS" ecom-logs-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d)

es() {
  kubectl exec -n "$NS" ecom-logs-es-default-0 -- \
    curl -sk -u "elastic:${ES_PASS}" \
    -H 'Content-Type: application/json' \
    "$@"
}

echo "==> 1. Creating ILM policy logs-ecom-policy..."
es -X PUT 'https://localhost:9200/_ilm/policy/logs-ecom-policy' \
  -d @- < "$SCRIPT_DIR/policy.json" | python3 -m json.tool

echo ""
echo "==> 2. Creating index template logs-ecom-template..."
es -X PUT 'https://localhost:9200/_index_template/logs-ecom-template' \
  -d @- < "$SCRIPT_DIR/index-template.json" | python3 -m json.tool

echo ""
echo "==> 3. Deleting flat logs-ecom index (will be replaced by alias)..."
es -X DELETE 'https://localhost:9200/logs-ecom' | python3 -m json.tool

echo ""
echo "==> 4. Bootstrapping logs-ecom-000001 with write alias..."
es -X PUT 'https://localhost:9200/logs-ecom-000001' -d '{
  "aliases": {
    "logs-ecom": {
      "is_write_index": true
    }
  }
}' | python3 -m json.tool

echo ""
echo "==> Done. Verifying..."
es 'https://localhost:9200/_cat/indices/logs-ecom*?v'
echo ""
es 'https://localhost:9200/_cat/aliases/logs-ecom?v'
echo ""
echo "==> ILM explain (should show logs-ecom-000001 in hot phase):"
es 'https://localhost:9200/logs-ecom-000001/_ilm/explain' | python3 -m json.tool
