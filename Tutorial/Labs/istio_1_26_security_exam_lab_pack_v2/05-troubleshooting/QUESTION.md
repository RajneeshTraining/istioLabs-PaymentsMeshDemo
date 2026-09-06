# LAB 5 — Expert Security Troubleshooting

## Scenario
The team reports:
- payment -> fraud = 403
- caller -> payment = 403
- admin JWT -> payment/admin = 403

An intentionally broken configuration is supplied.

## Task
1. Apply `broken.yaml`.
2. Reproduce failures.
3. Find every defect.
4. Use `kubectl`, `istioctl analyze`, `istioctl x describe` and proxy-config inspection.
5. Fix without changing application code.
6. Prove:
   payment -> fraud ALLOW
   caller -> fraud DENY
   valid user -> /payment ALLOW
   valid user -> /payment/admin DENY
   valid admin -> /payment/admin ALLOW

## Required diagnostic commands
```bash
kubectl get peerauthentication,requestauthentication,authorizationpolicy -n security-labs
istioctl analyze -n security-labs
istioctl x describe pod <pod> -n security-labs
istioctl proxy-config listener <pod> -n security-labs
istioctl proxy-config cluster <pod> -n security-labs
istioctl proxy-config secret <pod> -n security-labs
```

Do not assume every 403 is a JWT problem.
