#!/usr/bin/env bash
# Presetup for LAB 3.2 - Diagnosing a silent Gateway/VirtualService binding failure
#
# Deliberately deploys a VirtualService that references its Gateway WITHOUT
# the required namespace/name qualification, so the route silently never
# binds - reproducing an Envoy-level 404 at the ingress. Do not "fix" the
# generated YAML yourself before starting; that's the lab task.
#
# Usage: ./presetup-lab3.2-gateway-mismatch.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "== LAB 3.2 prerequisite check =========================="
check_kubectl
check_istioctl
check_istio_control_plane
check_no_incluster_operator

echo
echo "-- Checking ingress gateway is deployed --"
if kubectl get pods -n istio-system -l istio=ingressgateway --no-headers 2>/dev/null | grep -q Running; then
  PASS "istio-ingressgateway is running"
else
  FAIL "No running istio-ingressgateway pod found. Install the gateway component before this lab, e.g.: istioctl install --set profile=demo -y"
fi

echo
echo "-- Building lab scenario --"
ensure_namespace prod
label_injection_on prod

kubectl -n prod get deploy api-backend >/dev/null 2>&1 || \
  kubectl -n prod create deployment api-backend --image=kennethreitz/httpbin --port=80 >/dev/null
kubectl -n prod expose deployment api-backend --port=8080 --target-port=80 >/dev/null 2>&1 || true
wait_rollout prod api-backend
PASS "Deployed api-backend in ns/prod"

echo
echo "-- Deploying a working control host on the same shared Gateway (so you can compare working vs broken) --"
cat <<'EOF' > /tmp/lab32-gateway.yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: control-vs
  namespace: prod
spec:
  hosts:
  - "control.example.com"
  gateways:
  - "istio-system/main-gateway"
  http:
  - route:
    - destination:
        host: api-backend.prod.svc.cluster.local
        port:
          number: 8080
EOF
kubectl apply -f /tmp/lab32-gateway.yaml >/dev/null && PASS "Applied shared Gateway + a WORKING control VirtualService (control.example.com)"

echo
echo "-- Injecting the intentional bug: broken VirtualService for api.example.com --"
cat <<'EOF' > /tmp/lab32-broken-vs.yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-vs
  namespace: prod
spec:
  hosts:
  - "api.example.com"
  gateways:
  - "main-gateway"   # BUG: missing "istio-system/" namespace qualifier, silently never binds
  http:
  - match:
    - uri:
        prefix: /v1
    route:
    - destination:
        host: api-backend.prod.svc.cluster.local
        port:
          number: 8080
EOF
kubectl apply -f /tmp/lab32-broken-vs.yaml >/dev/null && PASS "Applied (deliberately broken) api-vs VirtualService for api.example.com"

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 3.2. Reproduce the bug:
  INGRESS_POD=$(kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
  # working host, for comparison:
  kubectl exec -n istio-system "$INGRESS_POD" -c istio-proxy -- curl -s -o /dev/null -w "%{http_code}\n" -H "Host: control.example.com" http://localhost:80/
  # broken host (should return Envoy's own 404, not the app's):
  kubectl exec -n istio-system "$INGRESS_POD" -c istio-proxy -- curl -s -o /dev/null -w "%{http_code}\n" -H "Host: api.example.com" http://localhost:80/v1/status

Then troubleshoot with istioctl proxy-config routes / istioctl analyze -A as described in the lab.

Cleanup when done:
  kubectl delete ns prod
  kubectl delete -f /tmp/lab32-gateway.yaml
  rm -f /tmp/lab32-broken-vs.yaml
EOF
