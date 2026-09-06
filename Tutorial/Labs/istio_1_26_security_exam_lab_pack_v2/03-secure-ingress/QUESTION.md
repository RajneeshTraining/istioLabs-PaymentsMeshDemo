# LAB 3 — HTTPS Ingress + JWT + Backend mTLS

## Scenario
Expose `https://api.example.test/payment`.

## Requirements
1. HTTPS is mandatory at the Istio ingress gateway.
2. TLS terminates at the gateway.
3. /payment requires a valid JWT.
4. /payment/admin requires role=admin.
5. Backend workloads use STRICT mTLS.
6. Use a self-signed certificate for this lab.

## Task
Create the TLS Secret, Gateway, VirtualService, RequestAuthentication, AuthorizationPolicy and PeerAuthentication.

## Critical exam distinction
Gateway `SIMPLE` means TLS terminates at the gateway. `PASSTHROUGH` means the gateway does not terminate application TLS.

## Preparation
```bash
kubectl apply -f ../00-common/base.yaml
kubectl apply -f payment-config.yaml
./create-cert.sh
kubectl -n security-labs rollout status deployment/payment
```
