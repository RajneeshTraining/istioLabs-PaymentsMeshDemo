# LAB 1 — STRICT mTLS + Workload Identity Authorization

## Scenario
`payment`, `fraud`, and `caller` run in namespace `security-labs`.

## Requirements
1. All workload-to-workload traffic in the namespace must use STRICT mTLS.
2. payment -> fraud must be allowed.
3. caller -> fraud must be denied.
4. Authorization must use Kubernetes ServiceAccount/workload identity.
5. Do not use IP addresses or modify the application.

## Task
Create the minimum Istio security configuration and prove the positive and negative cases.

## Prerequisites
Istio 1.26 is installed.

```bash
kubectl apply -f ../00-common/base.yaml
kubectl -n security-labs wait --for=condition=available deployment/payment --timeout=120s
kubectl -n security-labs wait --for=condition=available deployment/fraud --timeout=120s
kubectl -n security-labs wait --for=condition=available deployment/caller --timeout=120s
```

Inspect the starting state:
```bash
kubectl get pods,svc,sa -n security-labs
kubectl get peerauthentication,authorizationpolicy -n security-labs
```

Expected:
payment -> fraud = ALLOW
caller -> fraud = DENY
