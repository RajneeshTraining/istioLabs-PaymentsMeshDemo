# LAB 2 — Solution

Apply:
```bash
kubectl apply -f solution.yaml
```

No token:
```bash
kubectl -n security-labs exec deploy/caller -c curl -- curl -sS -o /dev/null -w '%{http_code}\n' http://payment.security-labs.svc.cluster.local/payment
```
Expected `403`.

User:
```bash
USER_TOKEN=$(python3 make-token.py user)
kubectl -n security-labs exec deploy/caller -c curl -- curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $USER_TOKEN" http://payment.security-labs.svc.cluster.local/payment
```
Expected `200`.

User -> admin expected `403`; admin token -> admin expected `200`.

Key distinction:
RequestAuthentication validates JWT. AuthorizationPolicy requires/authorizes the identity. `requestPrincipals` is JWT identity; `request.auth.claims[role]` accesses the JWT claim.
