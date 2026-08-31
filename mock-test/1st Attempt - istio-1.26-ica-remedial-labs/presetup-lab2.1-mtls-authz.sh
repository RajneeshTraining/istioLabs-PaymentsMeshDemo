#!/usr/bin/env bash
# Presetup for LAB 2.1 - Mesh-wide STRICT mTLS with one PERMISSIVE exception + deny-by-default authz
#
# Builds:
#   ns/prod    (injection ON)   -> frontend, backend, reviews (each with its own ServiceAccount)
#   ns/legacy  (injection OFF)  -> legacy-ingester (no sidecar, simulates a legacy plaintext caller)
#
# Usage: ./presetup-lab2.1-mtls-authz.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "== LAB 2.1 prerequisite check =========================="
check_kubectl
check_istioctl
check_istio_control_plane
check_no_incluster_operator

echo
echo "-- Building lab scenario --"
ensure_namespace prod
label_injection_on prod
ensure_namespace legacy
label_injection_off legacy

for svc in frontend backend reviews; do
  kubectl -n prod create serviceaccount "$svc" >/dev/null 2>&1 || true
  kubectl -n prod get deploy "$svc" >/dev/null 2>&1 || \
    kubectl -n prod create deployment "$svc" --image=kennethreitz/httpbin --port=80 >/dev/null
  kubectl -n prod patch deployment "$svc" -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"app\":\"$svc\"}},\"spec\":{\"serviceAccountName\":\"$svc\"}}}}" >/dev/null
  kubectl -n prod expose deployment "$svc" --port=8080 --target-port=80 >/dev/null 2>&1 || true
done
PASS "Deployed frontend, backend, reviews in ns/prod with individual ServiceAccounts"

kubectl -n legacy create serviceaccount legacy-ingester >/dev/null 2>&1 || true
kubectl -n legacy get deploy legacy-ingester >/dev/null 2>&1 || \
  kubectl -n legacy create deployment legacy-ingester --image=curlimages/curl --port=80 -- sleep infinity >/dev/null
kubectl -n legacy patch deployment legacy-ingester -p \
  '{"spec":{"template":{"spec":{"serviceAccountName":"legacy-ingester"}}}}' >/dev/null
PASS "Deployed legacy-ingester in ns/legacy (no sidecar, plaintext-only caller)"

wait_rollout prod frontend backend reviews
wait_rollout legacy legacy-ingester

echo
echo "-- Sanity: confirm current mTLS/authz posture is clean (no leftover policies) --"
kubectl get peerauthentication -A 2>/dev/null | grep -E 'prod|istio-system' && \
  WARN "Existing PeerAuthentication resources found - the lab expects a clean slate. Consider removing old ones." || \
  PASS "No conflicting PeerAuthentication resources found"
kubectl get authorizationpolicy -n prod 2>/dev/null | grep -q . && \
  WARN "Existing AuthorizationPolicy resources found in ns/prod - remove before starting for a clean baseline" || \
  PASS "No conflicting AuthorizationPolicy resources found in ns/prod"

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 2.1:
  1. Apply mesh-wide STRICT PeerAuthentication in istio-system.
  2. Apply workload-level PERMISSIVE PeerAuthentication for backend in ns/prod.
  3. Apply deny-all + scoped ALLOW AuthorizationPolicy in ns/prod.
  4. Verify with: istioctl x describe pod <backend-pod> -n prod
              and: istioctl x authz check <backend-pod>.prod

Cleanup when done:
  kubectl delete ns prod legacy
EOF
