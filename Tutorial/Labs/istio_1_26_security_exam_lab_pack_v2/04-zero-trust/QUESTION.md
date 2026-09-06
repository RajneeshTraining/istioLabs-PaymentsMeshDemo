# LAB 4 — Zero-Trust Service-to-Service Authorization

## Scenario
Communication matrix:

| Source | Destination | Result |
|---|---|---|
| caller | payment | ALLOW |
| payment | fraud | ALLOW |
| caller | fraud | DENY |

## Requirements
- STRICT mTLS in the namespace.
- Authorization based on ServiceAccount/workload identity.
- No pod IPs.
- No application authentication.

## Task
Implement the policies and prove all three cases.

## Preparation
```bash
kubectl apply -f ../00-common/base.yaml
```

Expected principals:
`cluster.local/ns/security-labs/sa/caller-sa`
`cluster.local/ns/security-labs/sa/payment-sa`
