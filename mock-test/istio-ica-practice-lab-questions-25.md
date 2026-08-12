# Istio Certified Associate (ICA) — Practice Lab Exam
## Scenario: Payment Mesh Demo — 30 Tasks

**Exam format:** Hands-on, performance-based (matches the real ICA exam style — no multiple choice here; see the separate MCQ document for that). Each task states an objective, requirements, and a verification method. Work directly against a live cluster with `kubectl` / `istioctl`. Each task is graded pass/fail against its verification command(s).

**Time allowance (suggested):** 3 hours total for all 30 tasks (roughly 5-8 minutes each, matching real exam pacing).

**Domain weighting** (aligned to the current ICA exam blueprint):

| Section | Tasks | Approx. weight |
|---|---|---|
| A — Installation & Sidecar Injection | 1–4 | 10% |
| B — Traffic Management | 5–14 | 30% |
| C — Resiliency | 15–19 | 20% |
| D — Security | 20–26 | 25% |
| E — Observability & Troubleshooting | 27–30 | 15% |

---

## Baseline setup (do this before Task 1)

You are given `payment-mesh-all-in-one.yaml`, deploying the following into namespace `payment-mesh` on plain Kubernetes (no Istio resources yet):

| Service | ServiceAccount | Port | Notes |
|---|---|---|---|
| `gateway` | `gateway` | 8080 | Entry point; calls `order-service` and `payment-service` |
| `order-service` | `order-service` | 8081 | |
| `payment-service` (v1, v2, v3) | `payment-service` (shared across all 3 versions) | 8080 | One Service selects `app: payment-service` across all 3 Deployments |
| `fraud-detection-service` | `fraud-detection-service` | 8085 | Called by `payment-service` v2/v3 only |
| `testing-pod` | `default` (no dedicated identity) | n/a | Debug pod for pod-to-pod curl testing, deliberately outside per-service identity |

Apply the baseline and confirm all pods are `1/1 Ready` before starting Task 1. Do not modify `payment-mesh-all-in-one.yaml` for any task — all solutions are **additional** manifests under `deploy/istio/`.

---

# Section A — Installation & Sidecar Injection

### Task 1 — Install Istio and verify the control plane
Install Istio using the `demo` configuration profile. Confirm `istiod`, `istio-ingressgateway`, and `istio-egressgateway` are all `Running` in `istio-system`.

**Verify:**
```istioctl verify-install``` command is deprecated and removed in recent versions of Istio. It is no longer available in v1.30.x.
Instead of verify-install, you can use standard Kubernetes and Istio diagnostic commands to check your mesh health:
1. Run ``` kubectl get all -n istio-system ``` to inspect control plane resources.
2. Use ```istioctl proxy-status``` (or istioctl ps) to check proxy and data plane synchronization.
3. Run ```istioctl x precheck``` before performing installations or upgrades
```bash
kubectl get pods -n istio-system
```

### Task 2 — Enable namespace-wide injection and roll out sidecars
Confirm the `payment-mesh` namespace carries `istio-injection: enabled`, then restart every Deployment so each pod is re-created with a sidecar.

**Verify:**
```bash
kubectl get ns payment-mesh -o jsonpath='{.metadata.labels.istio-injection}'
kubectl get pods -n payment-mesh -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready
```

### Task 3 — Exclude a single pod from sidecar injection
Even with namespace-wide injection enabled, `testing-pod` must remain **without** a sidecar (it needs to represent unmeshed, plaintext traffic for later security tasks). Achieve this using a pod-level annotation rather than removing the namespace label.

**Verify:**
```bash
kubectl get pod testing-pod -n payment-mesh -o jsonpath='{.spec.containers[*].name}'
# expected: only "debug-curl" — no istio-proxy container
```

### Task 4 — Perform a revision-based control plane upgrade
Install a second Istio control plane revision (e.g. `1-2X-1`) alongside the existing one, without touching currently-injected workloads. Demonstrate that both revisions run simultaneously and that switching a namespace to the new revision is a label change, not a reinstall.

**Verify:**
```bash
istioctl tag list
kubectl get pods -n istio-system -l app=istiod --show-labels
```

---

# Section B — Traffic Management

### Task 5 — Ingress Gateway for external access
Create a `Gateway` named `payment-mesh-gateway` bound to `istio-ingressgateway`, listening on port 80 for host `payment.mesh.local`, and a `VirtualService` named `gateway-vs` routing all paths to the `gateway` Service on port 8080. Requests without that `Host` header must not reach `gateway`.

**Verify:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: payment.mesh.local" "http://$INGRESS_HOST/orders/anything"
curl -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_HOST/orders/anything"
```

### Task 6 — TLS termination on the Gateway
Create a Kubernetes TLS secret `payment-mesh-cert` in `istio-system` and update (or add a second server block to) `payment-mesh-gateway` so it terminates HTTPS on port 443 for host `payment.mesh.local`, in addition to the existing HTTP listener.

**Verify:**
```bash
curl -sk -o /dev/null -w "%{http_code}\n" --resolve payment.mesh.local:443:$INGRESS_HOST "https://payment.mesh.local/orders/anything"
```

### Task 7 — DestinationRule subsets for payment-service
Create `payment-service-dr` defining subsets `v1`, `v2`, `v3` on the `version` pod label.

**Verify:**
```bash
kubectl get destinationrule payment-service-dr -n payment-mesh -o yaml
```

### Task 8 — Weighted traffic split
Using a `VirtualService` named `payment-service-vs`, send 70% of default traffic to subset `v1` and 30% to `v2`.

**Verify:** run ~20 requests from `testing-pod` and confirm the approximate 70/30 mix by response body/version header.

### Task 9 — Header-based routing override
Extend `payment-service-vs` so any request carrying `x-canary: v3` is routed 100% to subset `v3`, regardless of the weighted split, without breaking Task 8's default behavior.

**Verify:**
```bash
kubectl exec -n payment-mesh testing-pod -- curl -s -H "x-canary: v3" http://payment-service:8080/version
```

### Task 10 — Traffic mirroring
Configure `payment-service-vs` to mirror (shadow) 20% of production traffic destined for `v1` to subset `v3`, without the mirrored response affecting the caller in any way.

**Verify:** confirm `v3` pod logs show mirrored requests while the client only ever receives `v1`'s response, using `kubectl logs deploy/payment-service-v3`.

### Task 11 — Fault injection: delay
Add an HTTP fault injection rule on a **test-only** `VirtualService` for `payment-service` subset `v3` that injects a fixed 5s delay on 50% of requests, so you can observe how Task 16's timeout/retry settings behave under induced latency.

**Verify:**
```bash
time kubectl exec -n payment-mesh testing-pod -- curl -s -H "x-canary: v3" http://payment-service:8080/version
```

### Task 12 — Fault injection: abort
On the same test rule, additionally inject an HTTP 500 abort on 30% of requests to subset `v3`.

**Verify:** run repeated requests with `x-canary: v3` and confirm a mix of normal responses and forced `500`s.

### Task 13 — ServiceEntry for external egress
`fraud-detection-service` needs to call an external fraud-scoring API at `https://fraud-api.example.com` on port 443. By default Istio's outbound traffic policy blocks unregistered external hosts. Create a `ServiceEntry` named `fraud-api-external` that permits this specific external host over HTTPS.

**Verify:**
```bash
kubectl exec -n payment-mesh deploy/fraud-detection-service -c fraud-detection-service -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://fraud-api.example.com/
```

### Task 14 — Scope egress config with a Sidecar resource
Reduce configuration overhead and blast radius by creating a `Sidecar` resource for `order-service` that restricts its Envoy's outbound listeners to only the `payment-mesh` namespace and the `istio-system` namespace (no visibility into other namespaces in the mesh).

**Verify:**
```bash
istioctl proxy-config listener deploy/order-service.payment-mesh | wc -l
# compare listener count before/after applying the Sidecar resource
```

---

# Section C — Resiliency

### Task 15 — Request timeout
On a `VirtualService` named `order-service-vs`, set an overall request timeout of 5s for calls to `order-service`.

**Verify:**
```bash
time kubectl exec -n payment-mesh testing-pod -- curl -s -o /dev/null -w "%{http_code}\n" http://order-service:8081/orders/1
```

### Task 16 — Retry policy
Extend `order-service-vs` with a retry policy: 3 attempts, 2s per-try timeout, `retryOn: 5xx,reset,connect-failure`.

**Verify:** induce a transient failure (e.g. scale a dependency down briefly) and confirm the call still succeeds within the 5s overall timeout from Task 15.

### Task 17 — Connection pool limits
On `payment-service-dr`, add `trafficPolicy.connectionPool` settings: max 100 TCP connections, max 10 concurrent HTTP/1.1 requests per connection, max 1 pending request.

**Verify:**
```bash
kubectl get destinationrule payment-service-dr -n payment-mesh -o jsonpath='{.spec.trafficPolicy.connectionPool}'
```

### Task 18 — Outlier detection (circuit breaking)
Add outlier detection to `payment-service-dr`: `consecutive5xxErrors: 3`, `interval: 10s`, `baseEjectionTime: 30s`, `maxEjectionPercent: 50`. Trigger `payment-service-v3`'s chaos flags and confirm the endpoint gets ejected.

**Verify:**
```bash
istioctl proxy-config endpoint deploy/gateway.payment-mesh --cluster "outbound|8080||payment-service.payment-mesh.svc.cluster.local"
```

### Task 19 — Load balancing policy
Change `payment-service-dr`'s load balancing policy from Istio's default (`ROUND_ROBIN`) to `LEAST_CONN`, and explain (in a short comment in the manifest) when this would matter more than round robin for this service.

**Verify:**
```bash
kubectl get destinationrule payment-service-dr -n payment-mesh -o jsonpath='{.spec.trafficPolicy.loadBalancer}'
```

---

# Section D — Security

### Task 20 — Namespace-wide STRICT mTLS
Create a `PeerAuthentication` named `default` in `payment-mesh` enforcing `STRICT` mTLS for the whole namespace.

**Verify:**
```bash
kubectl get peerauthentication -n payment-mesh
```

### Task 21 — Workload-level PERMISSIVE override
Suppose `testing-pod` (unmeshed, per Task 3) must still be able to reach `order-service` in plaintext for a specific diagnostic scenario, without weakening mTLS for any other caller. Create a workload-specific `PeerAuthentication` selecting only `order-service` that sets `mtls.mode: PERMISSIVE`, overriding the namespace-wide `STRICT` policy from Task 20 for that one workload only.

**Verify:**
```bash
kubectl exec -n payment-mesh testing-pod -- curl -s -o /dev/null -w "%{http_code}\n" http://order-service:8081/orders/1
```

### Task 22 — Authorization allow-list across three services
Using `AuthorizationPolicy` resources, ensure: `order-service` only accepts callers using the `gateway` ServiceAccount; `payment-service` only accepts callers using the `gateway` ServiceAccount; `fraud-detection-service` only accepts callers using the `payment-service` ServiceAccount.

**Verify:**
```bash
kubectl exec -n payment-mesh deploy/gateway -c gateway -- curl -s -o /dev/null -w "%{http_code}\n" http://order-service:8081/orders/1
```

### Task 23 — Explicit DENY policy
Independent of Task 22's implicit default-deny, write an explicit `AuthorizationPolicy` with `action: DENY` that blocks any request to `payment-service` where the source principal is `cluster.local/ns/payment-mesh/sa/default` (i.e., `testing-pod`), and explain why an explicit DENY is evaluated before ALLOW policies.

**Verify:**
```bash
kubectl exec -n payment-mesh testing-pod -- curl -s -o /dev/null -w "%{http_code}\n" http://payment-service:8080/charge
```

### Task 24 — JWT validation at the ingress gateway
Create a `RequestAuthentication` on `gateway` (selector-based) that validates JWTs issued by `https://issuer.example.com` using its published JWKS, and an `AuthorizationPolicy` requiring `requestPrincipals: ["https://issuer.example.com/*"]` for any request through the ingress path.

**Verify:**
```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: payment.mesh.local" "http://$INGRESS_HOST/orders/1"
# expected: 401/403 without a valid token
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: payment.mesh.local" -H "Authorization: Bearer <valid-jwt>" "http://$INGRESS_HOST/orders/1"
# expected: 200
```

### Task 25 — Restrict egress to registry-only
Change the mesh-wide outbound traffic policy so that **any** external destination not explicitly registered via a `ServiceEntry` is blocked by default (rather than Istio's default `ALLOW_ANY`), and confirm Task 13's `fraud-api-external` `ServiceEntry` is the only external host still reachable.

**Verify:**
```bash
kubectl exec -n payment-mesh deploy/fraud-detection-service -c fraud-detection-service -- curl -s -o /dev/null -w "%{http_code}\n" https://fraud-api.example.com/
kubectl exec -n payment-mesh deploy/fraud-detection-service -c fraud-detection-service -- curl -s -o /dev/null -w "%{http_code}\n" https://not-registered.example.com/
```

### Task 26 — Verify mTLS certificates and identity
Using `istioctl`, inspect the actual TLS certificate Envoy presents for `order-service` and confirm the SPIFFE identity encoded in it matches the `order-service` ServiceAccount.

**Verify:**
```bash
istioctl proxy-config secret deploy/order-service.payment-mesh
```

---

# Section E — Observability & Troubleshooting

### Task 27 — Diagnose a broken VirtualService with istioctl analyze
You are handed this broken manifest, already applied:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: fraud-vs
  namespace: payment-mesh
spec:
  hosts:
  - fraud-detection-service.payment-mesh
  http:
  - route:
    - destination:
        host: fraud-detetcion-service.payment-mesh.svc.cluster.local
        port:
          number: 8085
```

Use `istioctl analyze -n payment-mesh` to find and explain **all** issues, then fix the manifest.

**Verify:**
```bash
istioctl analyze -n payment-mesh
```

### Task 28 — Enable structured access logging
Enable Envoy access logging mesh-wide (or at minimum for the `payment-mesh` namespace) using the JSON log format, so every request through a sidecar produces a structured log line including response code and upstream cluster.

**Verify:**
```bash
kubectl logs -n payment-mesh deploy/gateway -c istio-proxy --tail=20
```

### Task 29 — Diagnose a stale sidecar configuration
A teammate reports that `order-service` isn't picking up a newly-applied `VirtualService`. Use `istioctl proxy-status` to determine whether the sidecar's configuration is synced (`SYNCED`) or stale (`STALE`/`NOT SENT`), and describe the likely root cause and fix if it is not synced.

**Verify:**
```bash
istioctl proxy-status
```

### Task 30 — Verify trace-context header propagation
Confirm that `gateway` correctly propagates distributed-tracing headers (`x-request-id`, `x-b3-traceid`, `x-b3-spanid`, `x-b3-parentspanid`, `x-b3-sampled`) downstream to `order-service`, which is required for trace stitching in tools like Jaeger/Zipkin even before any tracing backend is installed.

**Verify:**
```bash
kubectl exec -n payment-mesh testing-pod -- curl -s -H "x-canary: v3" -D - -o /dev/null http://gateway:8080/orders/1 | grep -i x-b3
```

---

## Submission checklist

For each task, place your manifest(s) under `deploy/istio/`, one file per Istio resource kind, matching this project's existing naming convention, and confirm `kubectl apply -f deploy/istio/` applies cleanly from a fresh baseline with no `istioctl analyze` errors.
