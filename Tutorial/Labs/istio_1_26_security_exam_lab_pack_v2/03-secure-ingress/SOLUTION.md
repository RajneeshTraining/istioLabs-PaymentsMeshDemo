# LAB 3 — Solution

Apply the application and certificate:
```bash
kubectl apply -f ../00-common/base.yaml
kubectl apply -f payment-config.yaml
./create-cert.sh
```

Apply Istio:
```bash
kubectl apply -f solution.yaml
```

Find ingress:
```bash
kubectl -n istio-system get svc istio-ingressgateway
```

Generate JWTs:
```bash
USER_TOKEN=$(python3 ../02-jwt/make-token.py user)
ADMIN_TOKEN=$(python3 ../02-jwt/make-token.py admin)
```

Test with a self-signed certificate:
```bash
curl -k -i -H 'Host: api.example.test' https://<INGRESS_ADDRESS>:<HTTPS_PORT>/payment
```
No JWT must be denied.

User:
```bash
curl -k -i -H 'Host: api.example.test' -H "Authorization: Bearer $USER_TOKEN" https://<INGRESS_ADDRESS>:<HTTPS_PORT>/payment
```
Expected 200.

User on admin expected 403; admin on admin expected 200.

Inspect:
```bash
kubectl get gateway,virtualservice -n security-labs
kubectl get peerauthentication,requestauthentication,authorizationpolicy -n security-labs
istioctl analyze -A
```

Exam traps:
SIMPLE = Gateway TLS termination.
PASSTHROUGH = Gateway does not terminate application TLS.
Gateway TLS and backend mTLS are separate traffic segments.
