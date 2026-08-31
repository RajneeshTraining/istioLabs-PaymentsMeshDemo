#!/usr/bin/env bash
# Presetup for LAB 2.2 - End-user JWT auth + claim-based authz + defense-in-depth
#
# NOTE ON THE JWT ISSUER: the lab scenario refers to a fictional
# "https://auth.example.com" issuer. Since that issuer doesn't actually
# exist, this script instead wires you up with Istio's own well-known
# PUBLIC TEST issuer/JWKS (used throughout Istio's official docs and
# samples) so you have REAL tokens you can curl with:
#   issuer:   testing@secure.istio.io
#   jwksUri:  https://raw.githubusercontent.com/istio/istio/release-1.26/security/tools/jwt/samples/jwks.json
# Sample signed tokens (including one with "groups"/"admin"-like claims)
# are downloaded locally for you to use with `curl -H "Authorization: Bearer $(cat token)"`.
# When you write your RequestAuthentication/AuthorizationPolicy, substitute
# these real values in place of the fictional issuer from the lab scenario.
#
# Usage: ./presetup-lab2.2-jwt-authz.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

JWT_SAMPLES_DIR="$SCRIPT_DIR/.lab22-jwt-samples"
RAW_BASE="https://raw.githubusercontent.com/istio/istio/release-1.26/security/tools/jwt/samples"

echo "== LAB 2.2 prerequisite check =========================="
check_kubectl
check_istioctl
check_istio_control_plane
check_no_incluster_operator

echo
echo "-- Checking ingress gateway is deployed --"
if kubectl get pods -n istio-system -l istio=ingressgateway --no-headers 2>/dev/null | grep -q Running; then
  PASS "istio-ingressgateway is running"
else
  FAIL "No running istio-ingressgateway pod found (istio=ingressgateway). Install the gateway component before this lab, e.g.: istioctl install --set profile=demo -y"
fi

echo
echo "-- Building lab scenario --"
ensure_namespace prod
label_injection_on prod

kubectl -n prod create serviceaccount orders-service >/dev/null 2>&1 || true
kubectl -n prod get deploy orders-service >/dev/null 2>&1 || \
  kubectl -n prod create deployment orders-service --image=kennethreitz/httpbin --port=80 >/dev/null
kubectl -n prod patch deployment orders-service -p \
  '{"spec":{"template":{"metadata":{"labels":{"app":"orders-service"}},"spec":{"serviceAccountName":"orders-service"}}}}' >/dev/null
kubectl -n prod expose deployment orders-service --port=8080 --target-port=80 >/dev/null 2>&1 || true
wait_rollout prod orders-service

INGRESS_SA=$(kubectl get pods -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null)
INGRESS_NS="istio-system"
INFO "Ingress gateway ServiceAccount detected as: ${INGRESS_SA:-istio-ingressgateway-service-account} (ns: $INGRESS_NS)"
INFO "Use principal 'cluster.local/ns/${INGRESS_NS}/sa/${INGRESS_SA:-istio-ingressgateway-service-account}' in Lab 2.2 step 4."

cat <<EOF > /tmp/lab22-gateway.yaml
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
    - "api.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-vs
  namespace: prod
spec:
  hosts:
  - "api.example.com"
  gateways:
  - "istio-system/main-gateway"
  http:
  - match:
    - uri:
        prefix: /orders
    route:
    - destination:
        host: orders-service.prod.svc.cluster.local
        port:
          number: 8080
EOF
kubectl apply -f /tmp/lab22-gateway.yaml >/dev/null && PASS "Gateway + baseline VirtualService for /orders created (routing works, auth is NOT yet configured - that's your lab task)"

echo
echo "-- Downloading sample JWTs / JWKS for real testing --"
mkdir -p "$JWT_SAMPLES_DIR"
for f in jwks.json demo.jwt; do
  if [ ! -f "$JWT_SAMPLES_DIR/$f" ]; then
    curl -sL "$RAW_BASE/$f" -o "$JWT_SAMPLES_DIR/$f" && PASS "Downloaded $f" || WARN "Could not download $f (check internet access) - you can still complete the lab using your own JWT issuer"
  else
    INFO "$f already present locally"
  fi
done
INFO "Sample token (if downloaded): $JWT_SAMPLES_DIR/demo.jwt"
INFO "Sample JWKS   (if downloaded): $JWT_SAMPLES_DIR/jwks.json"

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 2.2:
  1. RequestAuthentication on the ingressgateway workload using:
       issuer:  testing@secure.istio.io
       jwksUri: https://raw.githubusercontent.com/istio/istio/release-1.26/security/tools/jwt/samples/jwks.json
  2. AuthorizationPolicy DENY with notRequestPrincipals: ["*"] to actually reject missing tokens.
  3. Claim-based ALLOW policy for DELETE (adjust claim key/value to match your token, or mint your
     own test token with a custom "role" claim using the jwt.io debugger + the sample private key
     under istio's security/tools/jwt/samples/ if you need a specific claim value).
  4. AuthorizationPolicy on orders-service restricting callers to the ingress gateway's SA:
       cluster.local/ns/istio-system/sa/<the SA printed above>

Test:
  curl -i http://api.example.com/orders
  curl -i -H "Authorization: Bearer $(cat .lab22-jwt-samples/demo.jwt)" http://api.example.com/orders

Cleanup when done:
  kubectl delete -f /tmp/lab22-gateway.yaml
  kubectl delete ns prod
EOF
