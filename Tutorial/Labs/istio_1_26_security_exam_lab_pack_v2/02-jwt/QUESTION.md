# LAB 2 — JWT Authentication + Claim-Based Authorization

## Scenario
The payment API exposes:
- GET /payment
- GET /payment/admin

JWT:
- issuer = https://issuer.example.test
- audience = payment-api
- claim = role
- role=user or role=admin

## Requirements
1. Istio validates the JWT.
2. No JWT may access the API.
3. user may call /payment.
4. Only admin may call /payment/admin.
5. A valid user JWT must receive denial on /payment/admin.
6. Authentication is implemented by Istio, not application code.

## Task
Configure RequestAuthentication and AuthorizationPolicy.

## Prerequisites
```bash
kubectl apply -f ../00-common/base.yaml
kubectl apply -f payment-config.yaml
kubectl -n security-labs rollout status deployment/payment
```

Generate tokens:
```bash
USER_TOKEN=$(python3 make-token.py user)
ADMIN_TOKEN=$(python3 make-token.py admin)
```
