# LAB 5 — Solution

Four defects are intentional:

1. Fraud trusts `caller-sa`, but requirement is `payment-sa`.
2. JWT issuer is wrong.
3. JWT audience is wrong.
4. AuthorizationPolicy expects the wrong JWT request principal.

Apply:
```bash
kubectl apply -f fixed.yaml
```

Generate:
```bash
USER_TOKEN=$(python3 ../02-jwt/make-token.py user)
ADMIN_TOKEN=$(python3 ../02-jwt/make-token.py admin)
```

Validate payment -> fraud:
```bash
kubectl -n security-labs exec deploy/payment -c nginx -- curl -sS -o /dev/null -w '%{http_code}\n' http://fraud.security-labs.svc.cluster.local/
```
Expected 200.

caller -> fraud expected 403.

user -> payment expected 200.

user -> payment/admin expected 403.

admin -> payment/admin expected 200.

Troubleshooting principle:
A 403 can be caused by AuthorizationPolicy even when the JWT itself is valid. Separate TLS/mTLS, JWT authentication, policy selector, principal, claim, method and path.
