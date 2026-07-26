# Istio Certified Associate (ICA) — Practice Lab Questions

Practice questions and hands-on lab tasks mapped to the current
**Istio Certified Associate (ICA)** curriculum from the Linux
Foundation/CNCF. Domain weights below are current as of this writing —
always cross-check against the official curriculum before you sit the
real exam, since Linux Foundation exams do get revised.

| Domain | Weight | Questions here |
|---|---|---|
| Traffic Management | 40% | 20 |
| Resilience and Fault Injection | 20% | 10 |
| Securing Workloads | 20% | 10 |
| Advanced Scenarios | 13% | 6 |
| Installation, Upgrade & Configuration | 7% | 4 |
| **Total** | **100%** | **50** |

The real ICA blends multiple-choice and hands-on, performance-based
tasks, so this guide does the same: **[MCQ]** items test terminology and
concepts, **[LAB]** items are hands-on tasks to actually run.

## How to use this with your own cluster

Every **[LAB]** question assumes you have a Kubernetes cluster with
Istio installed, and the **payment-mesh-demo** app already deployed —
see the main `README.md`, Phases 1-10. Since your images are now on
Docker Hub, you can stand this up on literally any cluster (kind,
minikube, Killercoda, or a real cloud cluster) purely with:
```bash
kubectl apply -k deploy/k8s/
kubectl rollout restart deployment -n payment-mesh
```
(with `deploy/k8s/kustomization.yaml` pointed at your Docker Hub images
— see README section 7.4). Apply Istio resources from `deploy/istio/`
as each lab task calls for them.

Answers are hidden in collapsible blocks so you can genuinely test
yourself first — click **Show Answer** to check.

---

## Domain 1: Installation, Upgrade & Configuration (7%)

**Q1. [MCQ]** Which command installs Istio using a profile suitable for
demos and tutorials, including the ingress gateway and telemetry
add-ons out of the box?

A. `istioctl install --set profile=minimal -y`
B. `istioctl install --set profile=demo -y`
C. `kubectl apply -f istio-base.yaml`
D. `helm install istio-base istio/base`

<details><summary>Show Answer</summary>

**Answer: B**

`profile=demo` is the profile this repo's own Phase 4 uses — it
installs `istiod` plus the ingress gateway pre-configured for local
learning. `minimal` installs only the control plane with no gateways.
Helm/`istio-base` alone only installs CRDs, not a working mesh.
</details>

---

**Q2. [MCQ]** What is the key architectural difference between
installing Istio with `istioctl` versus with Helm charts?

A. `istioctl` cannot install the ingress gateway
B. Helm requires manually writing every CRD from scratch
C. They both ultimately render the same underlying resources, but Helm
   integrates better with existing GitOps/Helm-based release pipelines
D. `istioctl` is deprecated in favor of Helm

<details><summary>Show Answer</summary>

**Answer: C**

Both are supported, official installation methods. `istioctl` is
often preferred for quick starts and imperative control (as this repo
uses); Helm is often preferred in organizations that already manage
all their infrastructure declaratively through Helm-based CI/CD.
</details>

---

**Q3. [MCQ]** You need to upgrade Istio from 1.x to 1.(x+1) with zero
downtime, testing the new control plane against a subset of workloads
before committing fully. Which upgrade strategy fits?

A. In-place upgrade
B. Canary upgrade (revision-based)
C. Deleting and reinstalling Istio
D. Upgrading only `istioctl` without touching the cluster

<details><summary>Show Answer</summary>

**Answer: B**

A canary upgrade installs a second, revisioned control plane
(`istioctl install --set revision=1-x-x`) alongside the existing one.
Workloads are migrated gradually by re-labeling their namespace
(`istio.io/rev=1-x-x`) and restarting, so you can validate before
migrating everything. An in-place upgrade replaces the control plane
directly, with less isolation if something goes wrong.
</details>

---

**Q4. [LAB]** Using the Istio release you downloaded for Phase 4,
verify which installation profile is currently active on your
cluster, and list the Istio components actually installed.

<details><summary>Show Answer</summary>

**Version note:** `istioctl profile list`/`dump`/`diff` were **removed
in Istio 1.24** (per the official 1.24.0 change notes). Use this
instead:
```bash
ls istio-*/manifests/profiles/                          # available profiles, read from disk
istioctl manifest generate --set profile=demo > demo.yaml # what "demo" would install
kubectl get pods -n istio-system                          # what's actually running
istioctl version                                           # client + control plane versions
```
There's no single "show me the active profile" command — in practice
you confirm it by generating the manifest a profile *would* produce and
comparing it against what's actually running in `istio-system`
(`istiod`, `istio-ingressgateway`, and for the `demo` profile,
`istio-egressgateway` too).
</details>

---

## Domain 2: Traffic Management (40%)

**Q5. [MCQ]** In this repo's `deploy/istio/ingress-gateway.yaml`, what
is the purpose of the `Gateway` resource specifically (as opposed to
the `VirtualService` in the same file)?

A. It defines which backend service handles the request
B. It opens a port on the ingress gateway workload and defines which
   hosts/protocols it accepts
C. It defines the retry policy for the request
D. It creates the Kubernetes Service for the ingress gateway

<details><summary>Show Answer</summary>

**Answer: B**

A `Gateway` only describes the listener (port, protocol, accepted
hosts/TLS) — it does not route anywhere by itself. Routing is always a
`VirtualService`'s job, which is why our file defines both: the
`Gateway` opens port 80 for any host, and the `VirtualService` then
routes matching requests to the `gateway` (payment-gateway) Service.
</details>

---

**Q6. [MCQ]** A `VirtualService`'s `hosts` field is set to
`payment-service.payment-mesh.svc.cluster.local`. What does this
control?

A. Which cluster the VirtualService applies to
B. The DNS name/host that this routing rule applies to — i.e., "when
   something calls this name, apply these rules"
C. Which pods can receive traffic
D. The TLS certificate hostname for the ingress gateway

<details><summary>Show Answer</summary>

**Answer: B**

`hosts` is what traffic must be addressed to for this VirtualService's
rules to apply — it's the "trigger", not the destination. The actual
destination(s) are specified per-route under `http[].route[].destination`.
</details>

---

**Q7. [MCQ]** What is the relationship between a `DestinationRule`'s
`subsets` and Kubernetes pod labels?

A. Subsets are unrelated to labels — they're an independent Istio concept
B. Each subset is defined by matching one or more pod labels (e.g.
   `version: v2`), letting a VirtualService route to a specific labeled
   group of pods
C. Subsets replace the need for a Kubernetes Service entirely
D. Subsets can only be based on the pod's namespace

<details><summary>Show Answer</summary>

**Answer: B**

This repo's own `destination-rule-payment-service.yaml` defines exactly
this: `v1`, `v2`, `v3` subsets, each matching the `version` pod label
already set on the `payment-service-v1/v2/v3` Deployments back in
Phase 3.
</details>

---

**Q8. [LAB]** Starting from this repo's baseline
(`virtual-service-payment-service-v1.yaml` applied, 100% to v1), modify
the routing to send 70% of traffic to v1 and 30% to v2, without
creating a new file.

<details><summary>Show Answer</summary>

Edit the applied VirtualService's route weights (or copy
`examples/virtual-service-canary-v1-v2.yaml` and change the numbers):
```yaml
route:
  - destination:
      host: payment-service.payment-mesh.svc.cluster.local
      subset: v1
    weight: 70
  - destination:
      host: payment-service.payment-mesh.svc.cluster.local
      subset: v2
    weight: 30
```
Weights across all destinations in one route **must sum to 100**.
Re-apply with `kubectl apply -f <file>` and verify with a loop of
`curl` calls tallying the `servedBy` field, same as README section 9.3.
</details>

---

**Q9. [MCQ]** Two `VirtualService` resources both define
`hosts: ["payment-service.payment-mesh.svc.cluster.local"]`. What
happens?

A. Istio picks one at random every request
B. This is invalid — Istio (via `istioctl analyze`) will typically warn
   about this, and behavior becomes unpredictable/undefined depending
   on version and configuration; in practice you should keep exactly
   one VirtualService per host
C. Both are merged automatically with no warnings, always safely
D. The cluster refuses to start any pods

<details><summary>Show Answer</summary>

**Answer: B**

This is exactly why this repo's Phase 5 `examples/` convention is
"only one VirtualService named `payment-service` is active at a
time" — applying a second one with the same host is a real, common
misconfiguration `istioctl analyze` is designed to catch.
</details>

---

**Q10. [LAB]** Apply this repo's header-based routing example
(`examples/virtual-service-header-beta-v3.yaml`) and confirm that a
request with header `x-user-type: beta` is routed differently than one
without it.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/examples/virtual-service-header-beta-v3.yaml

curl -X POST http://localhost:8080/checkout -H "Content-Type: application/json" \
  -H "x-user-type: beta" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
# servedBy: payment-service-v3

curl -X POST http://localhost:8080/checkout -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
# servedBy: payment-service-v1 (falls through, no header)
```
Match rules are evaluated top-to-bottom, first match wins — the
header-based rule must come before the catch-all fallback route.
</details>

---

**Q11. [MCQ]** What is the key difference between **weighted** routing
and **header-based** routing in a VirtualService?

A. There is no difference — both are configured identically
B. Weighted routing splits traffic by a fixed percentage regardless of
   the caller; header-based routing routes deterministically based on
   request content (e.g., a specific header value)
C. Header-based routing only works with gRPC
D. Weighted routing requires a ServiceEntry

<details><summary>Show Answer</summary>

**Answer: B**

Weighted (canary) routing is probabilistic and caller-agnostic — good
for gradual rollouts. Header/match-based routing is deterministic per
request — good for A/B testing, internal-only access, or opt-in beta
programs, exactly as demonstrated in this repo's Phase 5.
</details>

---

**Q12. [MCQ]** What does **traffic mirroring** (shadowing) in a
VirtualService do?

A. Sends 100% of live traffic to the primary destination, AND a copy to
   a mirror destination, whose responses are discarded (fire-and-forget)
B. Splits traffic 50/50 between two destinations
C. Encrypts traffic between two destinations
D. Automatically fails over to the mirror if the primary is down

<details><summary>Show Answer</summary>

**Answer: A**

Mirroring (`http[].mirror` + `mirrorPercentage`) is used to test a new
version against real production traffic patterns with zero user-facing
risk, since the mirrored response is never returned to the caller.
This repo doesn't implement it, but it's a named field on the same
`http[]` route block used throughout Phase 5's examples.
</details>

---

**Q13. [LAB, bonus/extension]** Add traffic mirroring to this repo's
`payment-service` VirtualService: send 100% of live traffic to `v1`,
and mirror a copy to `v2`.

<details><summary>Show Answer</summary>

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-service
  namespace: payment-mesh
spec:
  hosts:
    - payment-service.payment-mesh.svc.cluster.local
  http:
    - route:
        - destination:
            host: payment-service.payment-mesh.svc.cluster.local
            subset: v1
          weight: 100
      mirror:
        host: payment-service.payment-mesh.svc.cluster.local
        subset: v2
      mirrorPercentage:
        value: 100.0
```
Verify by checking `payment-service-v2`'s logs — it should show
incoming requests even though every `/checkout` response you receive
came from v1.
</details>

---

**Q14. [MCQ]** What is a `ServiceEntry` used for?

A. Registering an external (out-of-mesh) service so in-mesh workloads
   can call it under Istio's routing, security, and observability rules
B. Creating a new Kubernetes Service
C. Defining subsets for an in-mesh service
D. Replacing the need for a Gateway resource

<details><summary>Show Answer</summary>

**Answer: A**

By default, Istio's egress behavior depends on your mesh config
(`ALLOW_ANY` vs `REGISTRY_ONLY`); a `ServiceEntry` is how you
explicitly add an external host (e.g. a third-party API) to Istio's
internal service registry, letting you apply timeouts, retries, or
even mTLS-origination to calls that leave the mesh.
</details>

---

**Q15. [LAB, bonus/extension]** Write a `ServiceEntry` allowing
`payment-service` to call an external exchange-rate API at
`api.exchangerate.host` over HTTPS on port 443.

<details><summary>Show Answer</summary>

```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: exchangerate-api
  namespace: payment-mesh
spec:
  hosts:
    - api.exchangerate.host
  location: MESH_EXTERNAL
  ports:
    - number: 443
      name: https
      protocol: TLS
  resolution: DNS
```
This is exactly the kind of resource the original `currency-service`
idea (mentioned early in this project's planning, ultimately dropped
for simplicity) would have needed.
</details>

---

**Q16. [MCQ]** What is a `Sidecar` resource (`networking.istio.io`) used
for?

A. Injecting the Envoy sidecar container into a pod
B. Restricting a workload's (or namespace's) outbound visibility to only
   the specific hosts/namespaces it actually needs, reducing proxy
   memory usage and blast radius
C. Defining a canary release
D. Enabling mTLS

<details><summary>Show Answer</summary>

**Answer: B**

Don't confuse the `Sidecar` **resource** (a config scoping API) with
"the sidecar" (the Envoy **container**, controlled by the
`istio-injection` namespace label from this repo's Phase 4). The
`Sidecar` resource is an optimization/hardening tool for large meshes.
</details>

---

**Q17. [MCQ]** Istio is increasingly aligning with the Kubernetes
**Gateway API** as the future standard for ingress configuration. What
is the Gateway API's rough equivalent of Istio's own
`Gateway` + `VirtualService` pair?

A. `GatewayClass` + `Ingress`
B. `Gateway` + `HTTPRoute`
C. `Service` + `Endpoint`
D. There is no equivalent — Gateway API only handles TCP

<details><summary>Show Answer</summary>

**Answer: B**

The Kubernetes Gateway API's `Gateway` resource roughly maps to
Istio's `Gateway`, and `HTTPRoute` roughly maps to Istio's
`VirtualService`. This repo uses Istio's own APIs throughout for
simplicity and because they're still fully supported, but the ICA
curriculum expects familiarity with both approaches.
</details>

---

**Q18. [MCQ]** In this repo's `ingress-gateway.yaml`, the `Gateway`
server block sets `hosts: ["*"]`. What does this mean?

A. The gateway rejects all traffic
B. The gateway accepts requests for any Host header, so no custom
   domain or `/etc/hosts` entry is required to test it
C. The gateway only accepts traffic from the `default` namespace
D. `"*"` is invalid and must be a real domain name

<details><summary>Show Answer</summary>

**Answer: B**

This was a deliberate beginner-friendly choice in this repo — see the
comment in `deploy/istio/ingress-gateway.yaml` from Phase 4.
</details>

---

**Q19. [MCQ]** Which TLS mode would you set on a Gateway server block
to terminate TLS at the ingress gateway itself (rather than passing
encrypted traffic straight through to the backend)?

A. `PASSTHROUGH`
B. `SIMPLE`
C. `AUTO_PASSTHROUGH`
D. `DISABLE`

<details><summary>Show Answer</summary>

**Answer: B**

`SIMPLE` terminates TLS at the gateway using a server certificate you
provide. `MUTUAL` additionally requires a client certificate.
`PASSTHROUGH`/`AUTO_PASSTHROUGH` forward the encrypted TCP stream
untouched, terminating TLS only at the backend (common for
multi-cluster mesh federation).
</details>

---

**Q20. [LAB, bonus/extension]** Describe (no need to fully execute) the
steps to add HTTPS with `SIMPLE` TLS termination to this repo's ingress
gateway.

<details><summary>Show Answer</summary>

1. Create a TLS secret in `istio-system` containing your cert + key:
   `kubectl create secret tls payment-mesh-tls --cert=... --key=... -n istio-system`
2. Add a second `server` entry to the `Gateway` in
   `ingress-gateway.yaml`:
   ```yaml
   - port:
       number: 443
       name: https
       protocol: HTTPS
     tls:
       mode: SIMPLE
       credentialName: payment-mesh-tls
     hosts:
       - "*"
   ```
3. Re-apply, then reach the app over `https://` instead of `http://`.
</details>

---

**Q21. [MCQ]** What does `istioctl analyze` do?

A. Deploys a new version of an application
B. Statically checks your applied Istio configuration for common
   misconfigurations (conflicting VirtualServices, missing
   DestinationRule subsets, etc.) before they cause runtime issues
C. Installs Istio
D. Generates a load-testing report

<details><summary>Show Answer</summary>

**Answer: B**

Run it any time after applying config changes, e.g.
`istioctl analyze -n payment-mesh` — a genuinely useful habit for both
the exam and real troubleshooting.
</details>

---

**Q22. [LAB]** Use `istioctl proxy-config` to inspect the actual routes
the `gateway` pod's Envoy sidecar has been programmed with for calls to
`payment-service`.

<details><summary>Show Answer</summary>

```bash
kubectl get pods -n payment-mesh -l app=gateway
istioctl proxy-config routes <gateway-pod-name> -n payment-mesh --name http.8080 -o json
# or, broader:
istioctl proxy-config clusters <gateway-pod-name> -n payment-mesh | grep payment-service
```
This shows you Envoy's actual configuration — the ground truth of what
routing rules are in effect, useful when a VirtualService "should" be
working but isn't.
</details>

---

**Q23. [MCQ]** If no `VirtualService` exists at all for a given
Kubernetes Service, what happens to requests to it within the mesh?

A. All requests are rejected with 404
B. Istio falls back to plain Kubernetes Service round-robin load
   balancing across all matching endpoints
C. The request hangs indefinitely
D. Istio requires at least one VirtualService per Service to route
   anything at all

<details><summary>Show Answer</summary>

**Answer: B**

This is exactly this repo's Phase 3 behavior (before any VirtualService
existed) — plain Kubernetes Service round-robin across whatever pods
match the selector, still proxied through Envoy sidecars once
injected, just without any Istio-level routing intelligence applied.
</details>

---

**Q24. [MCQ]** In a `DestinationRule`, where do you configure
connection pool settings (like `maxConnections`) that apply to a
specific subset only, rather than the whole host?

A. In the top-level `spec.trafficPolicy`
B. Under that specific subset's own `trafficPolicy`, which overrides
   the top-level one for that subset only
C. In the VirtualService instead
D. Connection pool settings can't be scoped to a single subset

<details><summary>Show Answer</summary>

**Answer: B**

This repo's own `destination-rule-payment-service.yaml` does exactly
this in Phase 6: `v1` and `v2` have no special policy, while `v3` alone
gets a `trafficPolicy` with `connectionPool` + `outlierDetection`
nested under that one subset.
</details>

---

## Domain 3: Resilience and Fault Injection (20%)

**Q25. [MCQ]** In a VirtualService route, what's the difference between
the top-level `timeout` field and `retries.perTryTimeout`?

A. They're identical, just different names
B. `timeout` bounds the TOTAL time across all attempts combined;
   `perTryTimeout` bounds each individual attempt
C. `perTryTimeout` overrides `timeout` if larger
D. `timeout` only applies to the first attempt

<details><summary>Show Answer</summary>

**Answer: B**

This repo's `examples/virtual-service-all-v3-resilient.yaml` sets
`timeout: 2s` and `retries.perTryTimeout: 1s` together — the overall
call is bounded at 2s no matter how many retries fit inside that
window.
</details>

---

**Q26. [LAB]** Apply this repo's `virtual-service-all-v3-resilient.yaml`
and this repo's v3 chaos toggle to demonstrate the timeout in action.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/examples/virtual-service-all-v3-resilient.yaml
kubectl set env deployment/payment-service-v3 -n payment-mesh \
  CHAOS_ENABLED=true CHAOS_DELAY_MS=5000 CHAOS_FAILURE_RATE=0

time curl -X POST http://localhost:8080/checkout -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Expect the call to fail at ~2s (the configured timeout) rather than
hang for the full 5s injected delay. See README section 10.2.
</details>

---

**Q27. [MCQ]** Which values are valid entries in a VirtualService's
`retries.retryOn` field? (choose the most complete correct set)

A. Only `5xx`
B. `5xx`, `gateway-error`, `reset`, `connect-failure`, `refused-stream`,
   and others — a comma-separated list of Envoy retry-on policies
C. `retryOn` only accepts HTTP status codes directly (500, 502, 503)
D. `retryOn` is not a real field

<details><summary>Show Answer</summary>

**Answer: B**

`retryOn` takes Envoy's own named retry conditions, not raw status
codes. This repo's resilient VirtualService example uses
`5xx,connect-failure,refused-stream`.
</details>

---

**Q28. [MCQ]** Circuit breaking / outlier detection in Istio is
configured on which resource?

A. VirtualService, under `http[].fault`
B. DestinationRule, under `trafficPolicy.outlierDetection`
   (+ `connectionPool` for connection-level limits)
C. Gateway, under `servers[].tls`
D. PeerAuthentication

<details><summary>Show Answer</summary>

**Answer: B**

Fault injection (delay/abort) lives on the VirtualService. Circuit
breaking lives on the DestinationRule — two different resources for
two different concerns, exactly as this repo separates them across
Phase 5's routing files and Phase 6's `destination-rule-payment-service.yaml`.
</details>

---

**Q29. [LAB]** Using this repo's existing outlier detection config
(`consecutive5xxErrors: 3`, `baseEjectionTime: 30s`), force
`payment-service-v3` to fail consistently and observe the circuit open.

<details><summary>Show Answer</summary>

```bash
kubectl set env deployment/payment-service-v3 -n payment-mesh \
  CHAOS_ENABLED=true CHAOS_DELAY_MS=0 CHAOS_FAILURE_RATE=1.0

for i in $(seq 1 6); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
  sleep 1
done
```
First 3 requests fail with v3's own error; after that, Envoy ejects v3
and further requests fail immediately (no attempt to reach the pod at
all) until the 30s ejection window passes. See README section 10.3.
</details>

---

**Q30. [MCQ]** What does `maxEjectionPercent` on an `outlierDetection`
policy control?

A. The maximum percentage of a single pod's CPU that can be used
B. The maximum percentage of the total endpoints in a subset/host that
   outlier detection is allowed to eject at once
C. The percentage of traffic that gets mirrored
D. The percentage chance a request is retried

<details><summary>Show Answer</summary>

**Answer: B**

With only 1 replica (as `payment-service-v3` has in this demo),
`maxEjectionPercent: 100` means that single pod CAN be fully ejected —
resulting in total (temporary) unavailability rather than graceful
failover, since there's nothing else to fail over to. This is exactly
the caveat called out in this repo's README section 10.3.
</details>

---

**Q31. [MCQ]** What's the essential difference between Istio's
**fault injection** (`VirtualService.http[].fault`) and this repo's
own app-level "chaos mode" (the `CHAOS_ENABLED` env var on
`payment-service-v3`)?

A. There is no real difference between them
B. Fault injection is a mesh-level feature requiring zero application
   code changes; the app-level chaos toggle required writing actual
   application logic
C. Fault injection can only inject delays, never aborts
D. App-level chaos can only be triggered by Istio

<details><summary>Show Answer</summary>

**Answer: B**

This repo deliberately demonstrates both, to make the distinction
concrete — see README section 10.4's "pure Istio superpower" framing:
you can make a perfectly healthy dependency misbehave without touching
its code at all.
</details>

---

**Q32. [LAB]** Apply this repo's `virtual-service-fraud-fault-injection.yaml`
and describe the two independent probabilities at play.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/examples/virtual-service-fraud-fault-injection.yaml
```
`delay` (50% chance, 5s fixed delay) and `abort` (20% chance, HTTP 500)
are evaluated **independently** per request — a single request could
get delayed only, aborted only, both, or neither. This is a commonly
tested nuance on the exam.
</details>

---

**Q33. [MCQ]** By default, what HTTP status code does Envoy return to
the caller when its own configured `timeout` expires before the
upstream responds?

A. 500
B. 502
C. 504
D. 408

<details><summary>Show Answer</summary>

**Answer: C**

`504 Gateway Timeout` — distinct from a `500` the backend itself might
return, which matters when you're debugging whether a failure came
from your app or from Envoy giving up.
</details>

---

**Q34. [MCQ]** With only one replica of a subset (as this repo's
`payment-service-v3` has), why do retries not help against a
**deterministic, fixed** delay-based failure?

A. Retries are disabled by default on single-replica services
B. Every retry attempt lands on the exact same (still-slow) pod, so
   there's no "different, healthier" instance for the retry to reach
C. Retries only work with GET requests
D. Retries require multiple clusters

<details><summary>Show Answer</summary>

**Answer: B**

This is explicitly called out in this repo's README section 10.2:
retries earn their keep against intermittent failures, or when a retry
might land on a different, healthy replica — neither applies with one
replica and a guaranteed delay. Timeouts (bounding the damage) are the
correct tool for that specific case, not retries (avoiding the
damage).
</details>

---

## Domain 4: Securing Workloads (20%)

**Q35. [MCQ]** What are the three valid `mtls.mode` values on a
`PeerAuthentication` resource?

A. `ON`, `OFF`, `AUTO`
B. `STRICT`, `PERMISSIVE`, `DISABLE`
C. `ENFORCE`, `WARN`, `NONE`
D. `MUTUAL`, `SIMPLE`, `NONE`

<details><summary>Show Answer</summary>

**Answer: B**

`STRICT` requires mTLS. `PERMISSIVE` accepts both mTLS and plaintext
(useful during migration). `DISABLE` turns mTLS off entirely for the
selected scope. This repo's Phase 7 uses `STRICT` namespace-wide.
</details>

---

**Q36. [MCQ]** Conceptually, what is the core difference between what
mTLS (`PeerAuthentication`) proves versus what `AuthorizationPolicy`
proves?

A. They prove the same thing, just at different layers of the OSI model
B. mTLS proves the connection itself is between trusted, authenticated
   mesh members; AuthorizationPolicy additionally decides whether THIS
   SPECIFIC caller is allowed to call THIS SPECIFIC service
C. AuthorizationPolicy replaces the need for mTLS
D. mTLS only applies to ingress traffic, never internal traffic

<details><summary>Show Answer</summary>

**Answer: B**

This exact framing is central to this repo's README section 11 — a
caller can pass mTLS (valid mesh identity) and still get a clean `403`
from AuthorizationPolicy, because those are two different questions.
</details>

---

**Q37. [LAB]** Apply this repo's `peer-authentication.yaml` (STRICT)
and prove it blocks a caller with no sidecar at all.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/peer-authentication.yaml

kubectl run debug-curl-external -n default --image=curlimages/curl --restart=Never -- sleep 3600
kubectl exec -n default debug-curl-external -- \
  curl -s -m 5 http://order-service.payment-mesh.svc.cluster.local:8081/orders/anything
```
Expect a hang/timeout or connection reset — a plaintext HTTP client
from a namespace with no Istio sidecar has no certificate to offer at
all, so it never even reaches the AuthorizationPolicy layer. See
README section 11.6.
</details>

---

**Q38. [MCQ]** What are the valid `action` values on an
`AuthorizationPolicy`?

A. `ALLOW`, `DENY`, `AUDIT`, `CUSTOM`
B. `PERMIT`, `BLOCK`
C. `STRICT`, `PERMISSIVE`
D. `ACCEPT`, `REJECT`, `IGNORE`

<details><summary>Show Answer</summary>

**Answer: A**

This repo only uses `ALLOW` throughout (the simplest, most common
case), but the exam expects you to know `DENY` (explicit deny rules,
evaluated before ALLOW), `AUDIT` (log but don't enforce), and `CUSTOM`
(delegates the decision to an external authorizer) exist too.
</details>

---

**Q39. [LAB]** Apply this repo's `authorization-policy-order-service.yaml`
and prove it blocks a caller with valid mTLS but the wrong identity.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/authorization-policy-order-service.yaml

kubectl run debug-curl -n payment-mesh --image=curlimages/curl --restart=Never -- sleep 3600
kubectl exec -n payment-mesh debug-curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://order-service:8081/orders/anything
```
Expect `403` — this pod is inside the mesh (valid mTLS, since it's in
the `payment-mesh` namespace with sidecar injection on) but runs under
the `default` ServiceAccount, not `gateway`, so `order-service`'s
allow-list rejects it. See README section 11.5.
</details>

---

**Q40. [MCQ]** `AuthorizationPolicy` rules identify callers primarily
by:

A. Their pod's IP address only
B. Their Kubernetes ServiceAccount-derived identity (SPIFFE principal),
   e.g. `cluster.local/ns/payment-mesh/sa/gateway`
C. Their container image name
D. A shared API key

<details><summary>Show Answer</summary>

**Answer: B**

This is exactly why this repo's Phase 7 had to introduce a dedicated
ServiceAccount per service first — without distinct identities,
principal-based rules would be meaningless, since every pod would
share the namespace's `default` identity.
</details>

---

**Q41. [MCQ]** What is `RequestAuthentication` used for?

A. Validating end-user JWTs presented in incoming requests (e.g. from a
   logged-in user's browser/mobile app), separate from service-to-service
   mTLS identity
B. Configuring mTLS between services
C. Defining which ServiceAccount a pod uses
D. Rate limiting requests

<details><summary>Show Answer</summary>

**Answer: A**

`RequestAuthentication` + a companion `AuthorizationPolicy` rule
(checking `requestPrincipals`) is how you'd require, say, a valid
Auth0/Okta-issued JWT on specific routes — an "end user" identity layer
on top of (not instead of) the service-to-service mTLS this repo
already enforces. Not implemented in this repo, but a real exam topic.
</details>

---

**Q42. [LAB, conceptual/design exercise]** Sketch the resources you'd
need to require a valid JWT (issued by `https://example-issuer.com`)
on all calls to `gateway`'s `/checkout` endpoint.

<details><summary>Show Answer</summary>

```yaml
apiVersion: security.istio.io/v1beta1
kind: RequestAuthentication
metadata:
  name: gateway-jwt
  namespace: payment-mesh
spec:
  selector:
    matchLabels:
      app: gateway
  jwtRules:
    - issuer: "https://example-issuer.com"
      jwksUri: "https://example-issuer.com/.well-known/jwks.json"
---
apiVersion: security.istio.io/v1beta1
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
            requestPrincipals: ["https://example-issuer.com/*"]
```
Note: `RequestAuthentication` alone only *validates* a JWT if present —
it doesn't *require* one. The `AuthorizationPolicy` with
`requestPrincipals` is what actually enforces "a valid JWT is
mandatory."
</details>

---

**Q43. [MCQ]** A mesh-wide (root namespace) `PeerAuthentication` sets
`STRICT`, but a namespace-scoped `PeerAuthentication` in `payment-mesh`
sets `PERMISSIVE`. Which wins for workloads in `payment-mesh`?

A. Mesh-wide always wins
B. The more specific (namespace-scoped) policy wins for that namespace
C. They conflict and Istio refuses to apply either
D. Whichever was applied most recently wins, regardless of scope

<details><summary>Show Answer</summary>

**Answer: B**

Istio resolves `PeerAuthentication` (and `AuthorizationPolicy`) by
specificity: workload-level > namespace-level > mesh-level. This is
why this repo's Phase 7 applies its `STRICT` policy directly in the
`payment-mesh` namespace rather than relying on any mesh-wide default.
</details>

---

**Q44. [MCQ]** Once at least one `AuthorizationPolicy` with
`action: ALLOW` selects a given workload, what happens to requests
that don't match any of that policy's rules?

A. They're allowed by default, since no explicit DENY exists
B. They're denied by default — any ALLOW policy selecting a workload
   makes that workload implicitly deny-by-default for anything not
   explicitly matched
C. They're queued until a matching rule is added
D. This scenario is invalid and Istio rejects the policy

<details><summary>Show Answer</summary>

**Answer: B**

This is a frequently misunderstood point and a good exam trap: adding
one narrow ALLOW rule doesn't just "add an exception" — it flips the
entire workload into default-deny for everything else, as this repo's
`authorization-policy-order-service.yaml` comment explains directly.
</details>

---

## Domain 5: Advanced Scenarios (13%)

**Q45. [MCQ]** In Istio's **Ambient Mesh** mode, what replaces the
per-pod Envoy sidecar for L4 (mTLS/routing) functionality?

A. A node-level proxy called `ztunnel`, shared across all pods on that node
B. Nothing — Ambient mode still uses per-pod sidecars
C. A DaemonSet running a full Envoy per node with all L7 features
D. Ambient mode removes Envoy entirely, using only kernel-level eBPF

<details><summary>Show Answer</summary>

**Answer: A**

Ambient mode splits the data plane in two: a per-node `ztunnel` handles
mTLS/L4 for every pod on that node (no sidecar needed), and an
optional per-namespace **waypoint proxy** handles L7 features (like the
VirtualService/AuthorizationPolicy routing this repo relies on
throughout) only where actually needed. This repo uses classic sidecar
mode throughout, but Ambient is an explicit ICA curriculum topic.
</details>

---

**Q46. [MCQ]** What is a **waypoint proxy** in Ambient Mesh?

A. The node-level component handling mTLS for every pod
B. An optional, explicitly-deployed proxy that layers L7 features
   (routing, AuthorizationPolicy by HTTP method/path, etc.) on top of
   ztunnel's baseline L4 mTLS, for namespaces/workloads that need them
C. A synonym for the ingress gateway
D. A CLI tool for installing Istio

<details><summary>Show Answer</summary>

**Answer: B**

The key idea tested here: in Ambient mode, L4 security is "free"
(every pod gets it via ztunnel with no extra deployment), while L7
features cost you an explicit waypoint deployment — a meaningfully
different operational model than sidecar mode, where every pod always
pays the L7 sidecar cost whether it needs L7 features or not.
</details>

---

**Q47. [MCQ]** In a multi-cluster Istio mesh, what is the difference
between a **primary-remote** topology and a **multi-primary** topology?

A. They're the same thing with different names
B. Primary-remote has one cluster running the control plane
   (`istiod`) serving all clusters; multi-primary runs an independent
   control plane in each cluster, with cross-cluster trust/discovery
   configured between them
C. Multi-primary only supports 2 clusters maximum
D. Primary-remote requires a service mesh interface (SMI) layer

<details><summary>Show Answer</summary>

**Answer: B**

Primary-remote centralizes control-plane operations (simpler to
operate, but the primary cluster is a single point of failure for
config changes). Multi-primary is more resilient per-cluster but needs
more coordination (shared root CA, cross-cluster service discovery).
</details>

---

**Q48. [LAB]** Apply this repo's rate-limiting `EnvoyFilter` and prove
it enforces a limit before any backend service is even reached.

<details><summary>Show Answer</summary>

```bash
kubectl apply -f deploy/istio/envoy-filter-rate-limit-gateway.yaml

for i in $(seq 1 15); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 100, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
done
```
First 10 return `200`, the rest `429` — enforced entirely at the
ingress gateway (see README section 14).
</details>

---

**Q49. [MCQ]** What's the essential difference between **local** rate
limiting and **global** rate limiting in Istio/Envoy?

A. Local only works on ingress traffic; global only works internally
B. Local rate limiting keeps an independent token bucket per Envoy
   proxy instance (no shared state); global rate limiting uses a
   shared external service (+ store like Redis) so the limit is
   enforced consistently across every replica
C. They're interchangeable terms for the same feature
D. Global rate limiting doesn't require any extra infrastructure

<details><summary>Show Answer</summary>

**Answer: B**

This repo's Phase 10 explicitly uses **local** rate limiting for
simplicity (see README section 14.1) — with a single-replica ingress
gateway it behaves identically to a global limit, but the moment you
scale to multiple replicas, each keeps its own separate bucket and the
effective total limit scales with replica count (demonstrated in
README section 14.4).
</details>

---

**Q50. [MCQ]** From a GitOps perspective, what's the recommended way to
manage Istio configuration (VirtualServices, DestinationRules,
AuthorizationPolicies, etc.) in a production environment?

A. Apply changes manually with `kubectl apply -f` directly against
   production whenever a change is needed
B. Store all Istio YAML in version control and let a GitOps controller
   (e.g. Argo CD, Flux) reconcile the cluster's actual state to match
   what's declared in Git, exactly like this repo's own `deploy/`
   folder structure is designed to be committed and reviewed
C. GitOps and Istio are incompatible, since Istio config changes too
   frequently
D. Only Helm charts can be used with GitOps, never plain YAML

<details><summary>Show Answer</summary>

**Answer: B**

This entire repo's `deploy/istio/` and `deploy/k8s/` folders are
already structured the GitOps way: declarative YAML, committed to
version control, meant to be the single source of truth that a
reconciliation engine (or, at minimum, disciplined manual
`kubectl apply`) keeps the cluster in sync with — never hand-edited
live against a running cluster as the primary workflow.
</details>

---

## Self-check: answer key summary

| Domain | Question numbers | Correct answers |
|---|---|---|
| Installation, Upgrade & Configuration | 1-4 | B, C, B, (lab) |
| Traffic Management | 5-24 | B, B, B, (lab), B, (lab), B, A, (lab), A, (lab), B, B, (lab), B, C, (lab), B, (lab), B, B, D |
| Resilience and Fault Injection | 25-34 | B, (lab), B, B, (lab), B, B, (lab), C, B |
| Securing Workloads | 35-44 | B, B, (lab), A, (lab), B, A, (lab), B, B |
| Advanced Scenarios | 45-50 | A, B, B, (lab), B, B |

**Scoring guide:** count only the MCQ items you got right (36 of the 50
are MCQ, 14 are hands-on labs graded by whether your cluster actually
behaved as described). Aim for 80%+ on MCQs before attempting the real
exam — and don't skip the labs, since the actual ICA is explicitly
performance-based, not purely multiple-choice.
