# LAB 1 — Solution

Apply:
```bash
kubectl apply -f solution.yaml
```

Allowed test:
```bash
kubectl -n security-labs exec deploy/payment -c nginx -- curl -sS -o /dev/null -w '%{http_code}\n' http://fraud.security-labs.svc.cluster.local/
```
Expected: `200`.

Denied test:
```bash
kubectl -n security-labs exec deploy/caller -c curl -- curl -sS -o /dev/null -w '%{http_code}\n' http://fraud.security-labs.svc.cluster.local/
```
Expected: `403`.

Inspect:
```bash
istioctl analyze -n security-labs
istioctl x describe pod $(kubectl get pod -n security-labs -l app=fraud -o jsonpath='{.items[0].metadata.name}') -n security-labs
```

Key exam point:
PeerAuthentication controls connection/mTLS posture; AuthorizationPolicy controls access. `principals` is workload identity. Do not confuse it with JWT `requestPrincipals`.
