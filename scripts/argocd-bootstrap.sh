#!/usr/bin/env bash
# =============================================================================
#  argocd-bootstrap.sh — run ONCE after terraform apply + images are in ECR
#
#  What it does:
#    1. Pushes root-app.yaml → ArgoCD picks up GitOps/apps/ → deploys ecom-dev
#    2. Port-forwards ArgoCD UI → http://localhost:8080
#    3. Prints the admin password
#
#  Usage:
#    bash scripts/argocd-bootstrap.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Applying root-app (app-of-apps)..."
kubectl apply -f "$REPO_ROOT/GitOps/root-app.yaml"

echo ""
echo "==> Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

echo ""
echo "==> ArgoCD admin password:"
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
echo ""

echo ""
echo "==> Starting port-forward → http://localhost:8080"
echo "    Login: admin / (password above)"
echo "    Press Ctrl+C to stop"
echo ""
kubectl port-forward svc/argocd-server -n argocd 8080:443
