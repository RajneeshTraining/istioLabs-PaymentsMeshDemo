# Payment Mesh Demo — Student Quick Start

A small microservices checkout app, purpose-built for practicing
**Istio** service mesh concepts (traffic splitting, resilience,
security, observability). Deploy it once, then apply your own Istio
configuration on top of it.

---

## 1. Deploy

Requires: any Kubernetes cluster + `kubectl`. Images are already public
on Docker Hub — nothing to build.

```bash
kubectl apply -f payment-mesh-all-in-one.yaml
kubectl rollout status deployment -n payment-mesh --timeout=120s
kubectl get pods -n payment-mesh
```

You should see 6 pods, all `Running` in the `payment-mesh` namespace.

## 2. Access it

No ingress is set up yet (that's part of your own Istio practice), so
reach it via port-forward:

```bash
kubectl port-forward -n payment-mesh svc/gateway 8080:8080
```

## 3. Services and request flow

| Service | Role |
|---|---|
| `gateway` | Single entry point. Orchestrates the checkout flow |
| `order-service` | Creates the order |
| `payment-service` (v1, v2, v3) | Processes the payment — 3 versions, useful for traffic-splitting practice |
| `fraud-detection-service` | Simple rule-based check, called only by `payment-service` v2/v3 |

```
Client
  │
  ▼
gateway  ──POST /orders──▶  order-service
  │
  └──POST /payments──▶  payment-service (v1, v2, or v3)
                              │
                              └──POST /fraud-check──▶  fraud-detection-service
                                 (v2 and v3 only; v1 skips this call)
```

Without any Istio traffic rules applied, `payment-service` v1/v2/v3 are
all called through one plain Kubernetes Service, which load-balances
across all three at random — a good baseline to observe before you
apply your own `VirtualService`/`DestinationRule` to control it.

## 4. Try it

```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```

Sample response:
```json
{
  "orderId": "3f1c2b4e-7a91-4e2d-9c3a-1a2b3c4d5e6f",
  "paymentStatus": "APPROVED",
  "servedBy": "payment-service-v1",
  "reason": "Approved without fraud check (v1 behavior)"
}
```

Run it several times and watch `servedBy` — it should cycle between
`payment-service-v1`, `-v2`, and `-v3` with no pattern. That randomness
is exactly what Istio traffic rules let you control.

**A rejected response** (try `amount` above `10000`, or card number
`4000-0000-0000-0002`) will show `"paymentStatus": "REJECTED"` when
routed to v2/v3 — v1 always approves, since it skips the fraud check
entirely.

## 5. Endpoint reference

| Endpoint | Method | Notes |
|---|---|---|
| `/checkout` | POST | On `gateway` — the only endpoint you need for most exercises |
| `/orders` | POST | On `order-service`, port 8081 (internal) |
| `/payments` | POST | On `payment-service`, port 8080 (internal) |
| `/fraud-check` | POST | On `fraud-detection-service`, port 8085 (internal) |
| `/actuator/health` | GET | On every service — useful for readiness checks |

## 6. What's next

This is the plain Kubernetes baseline — no Istio installed yet. From
here, install Istio yourself and start layering on:
- Sidecar injection + an Ingress Gateway
- `VirtualService` / `DestinationRule` traffic splitting across
  `payment-service` v1/v2/v3
- Timeouts, retries, circuit breaking, fault injection
- `PeerAuthentication` (mTLS) and `AuthorizationPolicy`
- Observability (Kiali, Grafana, Prometheus, Jaeger)
- Rate limiting

Every service's response includes a `servedBy` field naming exactly
which version answered — the fastest way to visually confirm any
routing rule you apply actually worked.
