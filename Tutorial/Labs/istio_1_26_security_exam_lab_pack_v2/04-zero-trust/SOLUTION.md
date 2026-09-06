# LAB 4 — Solution

```bash
kubectl apply -f solution.yaml
```

caller -> payment:
```bash
kubectl -n security-labs exec deploy/caller -c curl -- curl -sS -o /dev/null -w '%{http_code}\n' http://payment.security-labs.svc.cluster.local/
```
Expected 200.

payment -> fraud:
```bash
kubectl -n security-labs exec deploy/payment -c nginx -- curl -sS -o /dev/null -w '%{http_code}\n' http://fraud.security-labs.svc.cluster.local/
```
Expected 200.

caller -> fraud:
```bash
kubectl -n security-labs exec deploy/caller -c curl -- curl -sS -o /dev/null -w '%{http_code}\n' http://fraud.security-labs.svc.cluster.local/
```
Expected 403.

Use `principals` for mTLS/workload identity. Use `requestPrincipals` for JWT identity.
