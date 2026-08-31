#!/usr/bin/env bash
# Presetup for LAB 3.1 - Diagnosing 503 (UC) from a broken DestinationRule subset
#
# Deliberately deploys a BROKEN DestinationRule (v2 subset selector doesn't
# match the real pod labels) so you have a genuine bug to troubleshoot -
# do not "fix" this file, that's the lab itself.
#
# Usage: ./presetup-lab3.1-subset-mismatch.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "== LAB 3.1 prerequisite check =========================="
check_kubectl
check_istioctl
check_istio_control_plane
check_no_incluster_operator

echo
echo "-- Building lab scenario (reviews v1/v2/v3) --"
ensure_namespace prod
label_injection_on prod

for ver in v1 v2 v3; do
  kubectl -n prod get deploy "reviews-$ver" >/dev/null 2>&1 || \
    kubectl -n prod create deployment "reviews-$ver" --image=kennethreitz/httpbin --port=80 >/dev/null
  kubectl -n prod patch deployment "reviews-$ver" -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"app\":\"reviews\",\"version\":\"$ver\"}}}}}" >/dev/null
done
kubectl -n prod get svc reviews >/dev/null 2>&1 || \
  kubectl -n prod expose deployment reviews-v1 --name=reviews --port=9080 --target-port=80 >/dev/null
# make sure the service actually selects all 3 versions, not just v1
kubectl -n prod patch svc reviews -p '{"spec":{"selector":{"app":"reviews"}}}' >/dev/null
wait_rollout prod reviews-v1 reviews-v2 reviews-v3
PASS "Deployed reviews-v1, reviews-v2, reviews-v3 (labels app=reviews, version=v1/v2/v3) behind svc/reviews"

echo
echo "-- Injecting the intentional bug: DestinationRule subset mismatch --"
cat <<'EOF' > /tmp/lab31-destinationrule.yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: prod
spec:
  host: reviews.prod.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2-canary   # BUG: real pods are labeled version=v2, not v2-canary
  - name: v3
    labels:
      version: v3
EOF
cat <<'EOF' > /tmp/lab31-virtualservice.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews
  namespace: prod
spec:
  hosts:
  - reviews.prod.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.prod.svc.cluster.local
        subset: v1
      weight: 90
    - destination:
        host: reviews.prod.svc.cluster.local
        subset: v2
      weight: 10
EOF
kubectl apply -f /tmp/lab31-destinationrule.yaml >/dev/null && PASS "Applied (deliberately broken) DestinationRule"
kubectl apply -f /tmp/lab31-virtualservice.yaml >/dev/null && PASS "Applied VirtualService (90/10 split v1/v2)"

echo
echo "-- Deploying a client pod to generate traffic/logs from --"
kubectl -n prod get deploy sleep >/dev/null 2>&1 || \
  kubectl -n prod create deployment sleep --image=curlimages/curl --port=80 -- sleep infinity >/dev/null
wait_rollout prod sleep

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 3.1. Generate some traffic to reproduce the bug:
  SLEEP_POD=$(kubectl get pod -n prod -l app=sleep -o jsonpath='{.items[0].metadata.name}')
  for i in $(seq 1 20); do
    kubectl exec -n prod "$SLEEP_POD" -- curl -s -o /dev/null -w "%{http_code}\n" http://reviews.prod.svc.cluster.local:9080/get
  done
  # You should see intermittent non-200s roughly ~10% of the time (the v2 slice).

Then troubleshoot with istioctl proxy-config cluster/endpoint as described in the lab.

Cleanup when done:
  kubectl delete ns prod
  rm -f /tmp/lab31-destinationrule.yaml /tmp/lab31-virtualservice.yaml
EOF
