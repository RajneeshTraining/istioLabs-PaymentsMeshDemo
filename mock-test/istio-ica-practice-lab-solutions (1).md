# Istio Certified Associate (ICA) — Practice Lab Solutions
## Scenario: Payment Mesh Demo — 30 Tasks

One valid, complete solution per task from `istio-ica-practice-lab-questions.md`. File paths follow `deploy/istio/<resource>.yaml`.

---

## Baseline setup — solution steps

```bash
kubectl apply -f payment-mesh-all-in-one.yaml
kubectl wait --for=condition=ready pod --all -n payment-mesh --timeout=180s
```

---

# Section A — Installation & Sidecar Injection

## Task 1 — Install Istio

```bash
istioctl install --set profile=demo -y
istioctl verify-install
kubectl get pods -n istio-system
```
Expected: `istiod-*`, `istio-ingressgateway-*`, `istio-egressgateway-*` all `Running`, `1/1` or `2/2` depending on profile.

## Task 2 — Enable injection & roll out

```bash
kubectl label namespace payment-mesh istio-injection=enabled --overwrite
kubectl rollout restart deployment -n payment-mesh
kubectl get pods -n payment-mesh
```
All app Deployment pods (`order-service`, `fraud-detection-service`, `payment-service-v1/v2/v3`, `gateway`) should show `2/2 Ready`. `testing-pod` is a bare Pod, unaffected by `rollout restart` — it must be recreated manually if you want to test injection defaults on it (see Task 3, which excludes it deliberately).

## Task 3 — Exclude a pod from injection

`deploy/istio/testing-pod-patch.yaml` (or edit the baseline pod's annotations before re-creating it — do not touch the original baseline file itself, apply this as an override):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: testing-pod
  namespace: payment-mesh
  labels:
    app: testing-pod
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  containers:
  - name: debug-curl
    image: nicolaka/netshoot
    command: [sleep, infinity]
```

```bash
kubectl delete pod testing-pod -n payment-mesh --ignore-not-found
kubectl apply -f deploy/istio/testing-pod-patch.yaml
kubectl get pod testing-pod -n payment-mesh -o jsonpath='{.spec.containers[*].name}'
# expected: debug-curl (no istio-proxy)
```

**Exam note:** `sidecar.istio.io/inject: "false"` on the pod template always wins over the namespace-wide `istio-injection: enabled` label — pod-level annotations take precedence over namespace-level labels.

## Task 4 — Revision-based canary upgrade

```bash
istioctl install --set profile=demo --set revision=1-2X-1 -y
istioctl tag list
kubectl get pods -n istio-system -l app=istiod --show-labels
# two istiod deployments now coexist, e.g. istiod-default and istiod-1-2X-1

# to migrate payment-mesh to the new revision later (not required for this task):
kubectl label namespace payment-mesh istio-injection- istio.io/rev=1-2X-1 --overwrite
```

**Exam note:** revision labels (`istio.io/rev=<rev>`) and the plain `istio-injection=enabled` label are mutually exclusive on a namespace — only one injection mechanism applies at a time.

---

# Section B — Traffic Management

## Task 5 — `deploy/istio/gateway.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: payment-mesh-gateway
  namespace: payment-mesh
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "payment.mesh.local"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: gateway-vs
  namespace: payment-mesh
spec:
  hosts:
  - "payment.mesh.local"
  gateways:
  - payment-mesh-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: gateway.payment-mesh.svc.cluster.local
        port:
          number: 8080
```

## Task 6 — `deploy/istio/gateway-tls.yaml`

```bash
kubectl create secret tls payment-mesh-cert \
  --cert=payment.mesh.local.crt --key=payment.mesh.local.key \
  -n istio-system
```

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: payment-mesh-gateway
  namespace: payment-mesh
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "payment.mesh.local"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: payment-mesh-cert
    hosts:
    - "payment.mesh.local"
```

**Exam note:** `credentialName` requires the secret to live in the **same namespace as the ingress gateway workload** (typically `istio-system` for the default gateway), not in `payment-mesh` — a common exam trap.

## Task 7 — `deploy/istio/payment-service-destinationrule.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-service-dr
  namespace: payment-mesh
spec:
  host: payment-service.payment-mesh.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
```

## Task 8 & 9 — `deploy/istio/payment-service-virtualservice.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-service-vs
  namespace: payment-mesh
spec:
  hosts:
  - payment-service.payment-mesh.svc.cluster.local
  http:
  - match:
    - headers:
        x-canary:
          exact: v3
    route:
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v3
  - route:
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v1
      weight: 70
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v2
      weight: 30
```

**Exam note:** the header-matched rule must precede the weighted default rule — `http` rules are evaluated top-to-bottom, first match wins.

## Task 10 — Traffic mirroring (extends `payment-service-virtualservice.yaml`)

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-service-vs
  namespace: payment-mesh
spec:
  hosts:
  - payment-service.payment-mesh.svc.cluster.local
  http:
  - match:
    - headers:
        x-canary:
          exact: v3
    route:
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v3
  - route:
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v1
      weight: 70
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v2
      weight: 30
    mirror:
      host: payment-service.payment-mesh.svc.cluster.local
      subset: v3
    mirrorPercentage:
      value: 20.0
```

**Exam note:** `mirror`/`mirrorPercentage` sit at the same level as `route` inside one `http` rule (not as a separate rule) — mirrored traffic is fire-and-forget; the response from `v3` is discarded and never returned to the original caller.

## Task 11 & 12 — `deploy/istio/payment-service-fault-test.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-service-fault-test
  namespace: payment-mesh
spec:
  hosts:
  - payment-service.payment-mesh.svc.cluster.local
  http:
  - match:
    - headers:
        x-canary:
          exact: v3
    fault:
      delay:
        percentage:
          value: 50.0
        fixedDelay: 5s
      abort:
        percentage:
          value: 30.0
        httpStatus: 500
    route:
    - destination:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v3
```

**Exam note:** this rule must be scoped (here, via the `x-canary: v3` header match) so it doesn't interfere with `payment-service-vs`'s general 70/30 split — in production you would never leave a fault-injection VirtualService unscoped and permanently applied; it's a temporary testing tool, typically removed after the resiliency policies (Tasks 15-19) are validated.

## Task 13 — `deploy/istio/fraud-api-external.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: fraud-api-external
  namespace: payment-mesh
spec:
  hosts:
  - fraud-api.example.com
  location: MESH_EXTERNAL
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
```

## Task 14 — `deploy/istio/order-service-sidecar.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: order-service-sidecar
  namespace: payment-mesh
spec:
  workloadSelector:
    labels:
      app: order-service
  egress:
  - hosts:
    - "payment-mesh/*"
    - "istio-system/*"
```

**Exam note:** `Sidecar.spec.egress[].hosts` uses `<namespace>/<host>` syntax; `*` for the host portion means "every service in that namespace." This directly reduces the number of Envoy listeners/clusters pushed to that one workload's sidecar, verifiable via a drop in `istioctl proxy-config listener` output.

---

# Section C — Resiliency

## Task 15 & 16 — `deploy/istio/order-service-virtualservice.yaml`

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: order-service-vs
  namespace: payment-mesh
spec:
  hosts:
  - order-service.payment-mesh.svc.cluster.local
  http:
  - timeout: 5s
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx,reset,connect-failure
    route:
    - destination:
        host: order-service.payment-mesh.svc.cluster.local
        port:
          number: 8081
```

## Task 17 — Connection pool (extends `payment-service-destinationrule.yaml`)

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-service-dr
  namespace: payment-mesh
spec:
  host: payment-service.payment-mesh.svc.cluster.local
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 10
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
  - name: v3
    labels:
      version: v3
```

## Task 18 — Outlier detection (extends the same `DestinationRule`)

```yaml
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 1
        maxRequestsPerConnection: 10
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

Trigger and verify:

```bash
kubectl -n payment-mesh set env deployment/payment-service-v3 CHAOS_ENABLED=true CHAOS_FAILURE_RATE=0.6
istioctl proxy-config endpoint deploy/gateway.payment-mesh \
  --cluster "outbound|8080||payment-service.payment-mesh.svc.cluster.local"
```

## Task 19 — Load balancer policy (extends the same `DestinationRule`)

```yaml
  trafficPolicy:
    loadBalancer:
      simple: LEAST_CONN
    # LEAST_CONN matters more than ROUND_ROBIN here because payment-service
    # requests can have very different processing times (v3 includes an
    # optional fraud-check call), so round robin can overload a pod that's
    # still busy with a slow prior request while an idle pod sits unused.
```

---

# Section D — Security

## Task 20 — `deploy/istio/peer-authentication.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: payment-mesh
spec:
  mtls:
    mode: STRICT
```

**Exam note:** naming it `default` with no `selector` makes it the namespace-wide policy.

## Task 21 — `deploy/istio/order-service-peer-authentication.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: order-service-permissive
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: order-service
  mtls:
    mode: PERMISSIVE
```

**Exam note:** the most specific `PeerAuthentication` wins — workload-level (has a `selector`) overrides namespace-level (`default`, no selector), which in turn overrides the mesh-level policy in `istio-system`. This lets `testing-pod` (still plaintext, per Task 3) reach `order-service` while every other workload in the namespace remains `STRICT`.

## Task 22 — `deploy/istio/authorization-policies.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: order-service-authz
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: order-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/payment-mesh/sa/gateway"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payment-service-authz
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: payment-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/payment-mesh/sa/gateway"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: fraud-detection-service-authz
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: fraud-detection-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/payment-mesh/sa/payment-service"]
```

## Task 23 — `deploy/istio/payment-service-deny-testing-pod.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payment-service-deny-default-sa
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: payment-service
  action: DENY
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/payment-mesh/sa/default"]
```

**Exam note:** Istio evaluates `CUSTOM`, then `DENY`, then `ALLOW` policies, in that fixed order, regardless of which was applied to the cluster first or which resource has the "more specific" match. An explicit `DENY` always short-circuits before any `ALLOW` is even considered — so Task 23's rule and Task 22's implicit default-deny both block `testing-pod`, but for different reasons: Task 22 blocks it because no ALLOW matches; Task 23 would block it even if some ALLOW rule accidentally did match.

## Task 24 — `deploy/istio/gateway-jwt.yaml`

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: gateway-jwt
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: gateway
  jwtRules:
  - issuer: "https://issuer.example.com"
    jwksUri: "https://issuer.example.com/.well-known/jwks.json"
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: gateway-require-jwt
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: gateway
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://issuer.example.com/*"]
```

**Exam note:** `RequestAuthentication` alone only validates a JWT **if present** — it does not by itself require one. Requests with no token at all still pass `RequestAuthentication` (as "unauthenticated"), which is why the separate `AuthorizationPolicy` requiring `requestPrincipals` is mandatory to actually enforce "a valid JWT is required."

## Task 25 — `deploy/istio/mesh-outbound-policy.yaml`

```bash
istioctl install --set profile=demo --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
```
or, equivalently, patch the existing `IstioOperator`/`istio` ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
```

**Exam note:** with `REGISTRY_ONLY`, only hosts known to Istio's service registry — i.e., real in-mesh Services, plus any `ServiceEntry` like `fraud-api-external` from Task 13 — are reachable; everything else gets `502`/connection refused at the sidecar, which is exactly the desired "deny by default" egress posture for a payments system.

## Task 26 — verification only, no new manifest

```bash
istioctl proxy-config secret deploy/order-service.payment-mesh
```
Expected: a `default` secret entry whose certificate chain, when decoded, encodes the SPIFFE URI `spiffe://cluster.local/ns/payment-mesh/sa/order-service` as its SAN — confirming Istio issued this workload's identity from the `order-service` ServiceAccount, not a shared or default identity.

---

# Section E — Observability & Troubleshooting

## Task 27 — Troubleshooting solution

`istioctl analyze -n payment-mesh` against the broken manifest reports two distinct problems:

1. **Unresolved destination host:** `spec.http[].route[].destination.host` is misspelled (`fraud-detetcion-service...`), so no Service in the mesh matches it — `analyze` flags this as an unresolved/dangling host reference.
2. **Inconsistent host formatting:** `spec.hosts` uses the short form (`fraud-detection-service.payment-mesh`) while `destination.host` uses the fully-qualified form — legal, but flagged as a best-practice warning since it's exactly what caused the typo to go unnoticed.

Corrected `deploy/istio/fraud-vs.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fraud-vs
  namespace: payment-mesh
spec:
  hosts:
  - fraud-detection-service.payment-mesh.svc.cluster.local
  http:
  - route:
    - destination:
        host: fraud-detection-service.payment-mesh.svc.cluster.local
        port:
          number: 8085
```

## Task 28 — `deploy/istio/mesh-access-logging.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio
  namespace: istio-system
data:
  mesh: |
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON
```

or, scoped only to `payment-mesh` via a `Telemetry` resource:

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: access-logging
  namespace: payment-mesh
spec:
  accessLogging:
  - providers:
    - name: envoy
```

**Exam note:** the `Telemetry` API (namespace- or mesh-scoped) is the current recommended way to control access logging/metrics/tracing per-workload or per-namespace, superseding older mesh-wide-only `accessLogFile` settings for anything beyond a blunt on/off toggle.

## Task 29 — Troubleshooting solution

```bash
istioctl proxy-status
```
Look for `order-service-xxxx.payment-mesh` in the output:
- `SYNCED` — sidecar has the latest config; if the VirtualService still "isn't working," recheck the manifest itself (wrong host, wrong selector) rather than propagation.
- `STALE` — Envoy has an older config version than `istiod` last pushed; usually a transient push failure or an overloaded `istiod` — restarting the pod or checking `istiod` logs for push errors is the fix.
- `NOT SENT` — `istiod` has nothing queued for that proxy at all, often because the pod's sidecar never established its xDS connection (check `istio-proxy` container logs in that pod for connection errors to `istiod:15012`).

## Task 30 — Verification-only task

```bash
kubectl exec -n payment-mesh testing-pod -- \
  curl -s -H "x-canary: v3" -D - -o /dev/null http://gateway:8080/orders/1 | grep -i x-b3
```
Expected: Envoy auto-generates and forwards `x-request-id`, `x-b3-traceid`, `x-b3-spanid`, `x-b3-sampled` (and `x-b3-parentspanid` on downstream hops) automatically for any request passing through a sidecar — **the application itself must still forward these headers on any outbound call it makes**, since Envoy cannot invent the causal parent-child span relationship on its own; this is a very common real-world gap between "Istio does it for me" expectations and reality, and a frequent exam trap.

---

## Full apply order (reference)

```bash
kubectl apply -f payment-mesh-all-in-one.yaml
kubectl apply -f deploy/istio/gateway.yaml
kubectl apply -f deploy/istio/gateway-tls.yaml
kubectl apply -f deploy/istio/payment-service-destinationrule.yaml
kubectl apply -f deploy/istio/payment-service-virtualservice.yaml
kubectl apply -f deploy/istio/fraud-api-external.yaml
kubectl apply -f deploy/istio/order-service-sidecar.yaml
kubectl apply -f deploy/istio/order-service-virtualservice.yaml
kubectl apply -f deploy/istio/peer-authentication.yaml
kubectl apply -f deploy/istio/order-service-peer-authentication.yaml
kubectl apply -f deploy/istio/authorization-policies.yaml
kubectl apply -f deploy/istio/payment-service-deny-testing-pod.yaml
kubectl apply -f deploy/istio/gateway-jwt.yaml
kubectl apply -f deploy/istio/fraud-vs.yaml
istioctl analyze -n payment-mesh
```
