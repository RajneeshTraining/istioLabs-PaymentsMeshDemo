# Payment Mesh Demo — Hands-On Lab Questions & Step-by-Step Solutions

The 14 hands-on `[LAB]` tasks pulled out of the 50-question ICA
practice bank, with each solution expanded into full step-by-step
walkthroughs — what to run, why, and what you should see at each step.

**Prerequisite for all labs below:** your `payment-mesh-demo` cluster is
up and running (Phases 1-10 applied), with images pulled from your
Docker Hub account. Confirm with:
```bash
kubectl get pods -n payment-mesh
```
You should see 6 pods, all `2/2 Running` (2 containers = your app +
the injected Envoy sidecar).

### A note on Istio API versions (updated for 1.28.x)

Istio's `networking.istio.io` and `security.istio.io` APIs (`Gateway`,
`VirtualService`, `DestinationRule`, `ServiceEntry`,
`PeerAuthentication`, `AuthorizationPolicy`, `RequestAuthentication`,
etc.) were promoted from `v1beta1` to GA **`v1`** back in Istio 1.22.
Every YAML snippet below now uses `apiVersion: .../v1` accordingly.

`EnvoyFilter` is the one exception you'll see kept at
`networking.istio.io/v1alpha3` in Lab 14 — that's not outdated, it's
correct: `EnvoyFilter` is deliberately an unstable "escape hatch" API
that reaches directly into Envoy's own config, and it has **not** been
promoted to `v1` even in current Istio releases, precisely because it's
expected to change alongside Envoy internals.

One thing worth knowing if you're applying these labs against your own
copy of the repo from earlier phases: those existing files
(`deploy/istio/*.yaml`) were originally written with `v1beta1`. That
still works today — Kubernetes keeps old API versions functioning as
aliases for a long deprecation window — but it's not the current
convention. If you'd like, ask for an update to bump those repo files
to `v1` too, for full consistency with what's shown here.

Of the 14 labs, 3 are marked **bonus/extension** — they ask you to
write a *new* resource this repo doesn't already ship, rather than
apply one that exists. Those are flagged clearly below.

| # | Lab | Domain |
|---|---|---|
| 1 | Verify the Istio installation profile | Installation, Upgrade & Configuration |
| 2 | Change the canary split to 70/30 | Traffic Management |
| 3 | Header-based (A/B) routing | Traffic Management |
| 4 | Traffic mirroring *(bonus/extension)* | Traffic Management |
| 5 | ServiceEntry for external egress *(bonus/extension)* | Traffic Management |
| 6 | TLS termination on the ingress gateway *(bonus/extension)* | Traffic Management |
| 7 | Inspect Envoy config with `istioctl proxy-config` | Traffic Management |
| 8 | Timeout demo | Resilience and Fault Injection |
| 9 | Circuit breaking / outlier detection demo | Resilience and Fault Injection |
| 10 | Fault injection demo | Resilience and Fault Injection |
| 11 | STRICT mTLS blocks a non-mesh caller | Securing Workloads |
| 12 | AuthorizationPolicy blocks a wrong-identity caller | Securing Workloads |
| 13 | JWT-based end-user auth *(design exercise)* | Securing Workloads |
| 14 | Rate limiting at the ingress gateway | Advanced Scenarios |

---

## Lab 1: Verify the Istio installation profile

**Domain:** Installation, Upgrade & Configuration

**Task:** Using the Istio release you downloaded for Phase 4, verify
which installation profile is currently active on your cluster, and
list the Istio components actually installed.

> **Version note:** `istioctl profile list` / `dump` / `diff` were
> **removed in Istio 1.24** (confirmed in the official 1.24.0 change
> notes: *"Removed `istioctl profile` command. The same information can
> be found in Istio documentation."*). The steps below use the current,
> supported approach instead.

### Step-by-step solution

**Step 1 — confirm `istioctl` is available and check its version
against the control plane:**
```bash
istioctl version
```
This prints both the **client** version (the `istioctl` binary on your
machine) and the **control plane** version (`istiod` running in the
cluster). If these don't match, you likely have a stale `istioctl` from
an earlier download — re-download it to match, since mismatched
versions can cause confusing errors on later labs.

**Step 2 — list the profiles actually available in your downloaded
release**, directly from the filesystem (this replaces the removed
`istioctl profile list`):
```bash
ls istio-*/manifests/profiles/
```
You'll see files like `default.yaml`, `demo.yaml`, `minimal.yaml`,
`empty.yaml`, `remote.yaml`, `preview.yaml` — `istioctl` reads
profiles straight from this directory, so this listing is the
authoritative, current source of truth.

**Step 3 — see what a given profile would actually install**, without
touching your cluster (this replaces the removed
`istioctl profile dump demo`):
```bash
istioctl manifest generate --set profile=demo > demo-manifest.yaml
less demo-manifest.yaml
```
This renders the complete set of Kubernetes manifests the `demo`
profile produces — the same information `istioctl profile dump` used
to show, just generated as real, inspectable YAML instead of an
internal config dump.

**Step 4 — check what's actually running in `istio-system`:**
```bash
kubectl get pods -n istio-system
```
For the `demo` profile (used in this repo's Phase 4), you should see:
- `istiod-xxxxx` — the control plane
- `istio-ingressgateway-xxxxx` — the ingress gateway (this is what
  Phase 4's `Gateway` resource attaches to)
- possibly `istio-egressgateway-xxxxx` — the `demo` profile installs
  this too, even though this repo never configures egress traffic
  through it

**Step 5 — cross-reference Step 3's generated manifest against what's
actually running in Step 4** to confirm your cluster genuinely matches
the `demo` profile and hasn't drifted from it (e.g. via manual `kubectl
edit`s made directly against the live cluster over time):
```bash
grep "kind: Deployment" demo-manifest.yaml
```
Compare that list of Deployments against `kubectl get deployments -n
istio-system`.

**What this demonstrates:** the ICA exam expects you to be comfortable
inspecting an *already-installed* mesh and reasoning about what profile
produced it — a common real-world task when you inherit a cluster you
didn't personally install. It's also a good example of why checking a
command against **current** release notes matters: `istioctl profile`
is exactly the kind of thing older tutorials (and, candidly, an earlier
draft of this very file) still show as if it works, when it no longer
does as of 1.24+.

---

## Lab 2: Change the canary split to 70/30

**Domain:** Traffic Management

**Task:** Starting from this repo's baseline
(`virtual-service-payment-service-v1.yaml` applied, 100% to v1), modify
the routing to send 70% of traffic to v1 and 30% to v2 — without
creating a new file.

### Step-by-step solution

**Step 1 — confirm the current baseline is active:**
```bash
kubectl get virtualservice payment-service -n payment-mesh -o yaml
```
You should see a single route with `subset: v1`, `weight: 100`.

**Step 2 — edit it directly** (either with `kubectl edit`, or by
editing a local copy of `deploy/istio/examples/virtual-service-canary-v1-v2.yaml`
and re-applying it, since that file already has the two-subset shape —
just change its numbers):
```bash
kubectl edit virtualservice payment-service -n payment-mesh
```
Change the `http[0].route` list to:
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
**The weights across every destination in one route must sum to
exactly 100** — this is one of the most common mistakes `istioctl
analyze` will catch for you if you get it wrong.

**Step 3 — save and confirm the change took effect:**
```bash
kubectl get virtualservice payment-service -n payment-mesh -o yaml
```

**Step 4 — verify with real traffic.** Since Istio's split is
probabilistic per-request (not a strict round-robin), you need enough
samples to see the ratio emerge:
```bash
for i in $(seq 1 30); do
  curl -s -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 100, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}' \
    | grep -o '"servedBy":"[^"]*"'
done | sort | uniq -c
```
Expect roughly 21 `payment-service-v1` and 9 `payment-service-v2` (70/30
of 30 requests) — exact counts will vary run to run since it's
probabilistic, not deterministic.

**Step 5 — revert to the safe baseline when done:**
```bash
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** direct, hands-on proof that traffic
percentages are a pure configuration decision, editable live with zero
code changes or restarts — the headline Traffic Management skill.

---

## Lab 3: Header-based (A/B) routing

**Domain:** Traffic Management

**Task:** Apply this repo's header-based routing example
(`examples/virtual-service-header-beta-v3.yaml`) and confirm that a
request with header `x-user-type: beta` is routed differently than one
without it.

### Step-by-step solution

**Step 1 — apply the rule:**
```bash
kubectl apply -f deploy/istio/examples/virtual-service-header-beta-v3.yaml
```

**Step 2 — inspect what you just applied** (worth reading before
testing, so you know what to expect):
```bash
kubectl get virtualservice payment-service -n payment-mesh -o yaml
```
Note the `http` list has **two** entries: a `match`-based rule (header
`x-user-type: beta` → subset `v3`) listed *first*, and a catch-all
fallback rule (→ subset `v1`) listed *second*. Istio evaluates `http[]`
entries **top-to-bottom, first match wins** — this ordering is not
optional, it's the entire mechanism.

**Step 3 — send a request WITH the header:**
```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -H "x-user-type: beta" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Expect `"servedBy": "payment-service-v3"`.

**Step 4 — send a request WITHOUT the header:**
```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Expect `"servedBy": "payment-service-v1"` — it falls through to the
second (fallback) rule since the first rule's `match` condition wasn't
met.

**Step 5 (why this actually works end-to-end) —** recall that
`gateway`'s `CheckoutController` explicitly forwards this one header
downstream (a Phase 5 code change). Confirm this is why it works by
checking the code:
```bash
grep -A3 "x-user-type" gateway/src/main/java/com/example/paymentmesh/gateway/CheckoutController.java
```
Header-based routing decisions are enforced by the **caller's**
sidecar — if `gateway` hadn't forwarded the header to its own outbound
call to `payment-service`, this VirtualService rule would have nothing
to match against, no matter how correctly it was configured.

**Step 6 — revert to baseline:**
```bash
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** deterministic, opt-in routing (vs. Lab 2's
probabilistic split) — the pattern behind beta programs and internal
testing rollouts.

---

## Lab 4 (bonus/extension): Traffic mirroring

**Domain:** Traffic Management

**Task:** Add traffic mirroring to this repo's `payment-service`
VirtualService: send 100% of live traffic to `v1`, and mirror a copy to
`v2`. *(This resource doesn't exist in the repo yet — you're writing it
from scratch.)*

### Step-by-step solution

**Step 1 — create the file** (e.g.
`deploy/istio/examples/virtual-service-mirror-v1-v2.yaml`):
```yaml
apiVersion: networking.istio.io/v1
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

**Step 2 — apply it:**
```bash
kubectl apply -f deploy/istio/examples/virtual-service-mirror-v1-v2.yaml
```

**Step 3 — start tailing v2's logs in one terminal, before sending any
traffic:**
```bash
kubectl logs -n payment-mesh deployment/payment-service-v2 -f
```

**Step 4 — in a second terminal, send normal checkout traffic:**
```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Look at the JSON response: `"servedBy"` will say `payment-service-v1`
— that's the only response you, the caller, ever see.

**Step 5 — go back to the first terminal.** You should see `v2` logged
an incoming request too, even though its response was never returned
to you. Mirrored requests are genuinely fire-and-forget — Envoy sends
the copy and discards whatever comes back.

**Step 6 — clean up:**
```bash
kubectl delete -f deploy/istio/examples/virtual-service-mirror-v1-v2.yaml
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** testing a new version against real
production traffic *shapes* with zero user-facing risk — the mirrored
service's mistakes never reach a real caller.

---

## Lab 5 (bonus/extension): ServiceEntry for external egress

**Domain:** Traffic Management

**Task:** Write a `ServiceEntry` allowing `payment-service` to call an
external exchange-rate API at `api.exchangerate.host` over HTTPS on
port 443. *(This resource doesn't exist in the repo — this is a
from-scratch exercise; the repo's original design intentionally
dropped an external "currency-service" call to stay simple.)*

### Step-by-step solution

**Step 1 — check your mesh's current egress policy** (this determines
whether a `ServiceEntry` is even required to reach external hosts at
all):
```bash
kubectl get configmap istio -n istio-system -o yaml | grep -A2 outboundTrafficPolicy
```
- `ALLOW_ANY` (the `demo` profile's default): external calls work even
  *without* a ServiceEntry, but you get none of Istio's routing/mTLS-
  origination/observability benefits for that traffic.
- `REGISTRY_ONLY`: external calls are **blocked** unless explicitly
  registered via a `ServiceEntry` — the stricter, more production-like
  setting.

**Step 2 — write the ServiceEntry:**
```yaml
apiVersion: networking.istio.io/v1
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
- `location: MESH_EXTERNAL` tells Istio this host lives outside the
  mesh (as opposed to `MESH_INTERNAL`, for registering workloads not
  otherwise auto-discovered).
- `resolution: DNS` tells Envoy to resolve the hostname itself via DNS,
  rather than expecting you to list static IPs.

**Step 3 — apply it:**
```bash
kubectl apply -f service-entry-exchangerate.yaml
```

**Step 4 — test from inside the mesh:**
```bash
kubectl run debug-curl -n payment-mesh --image=curlimages/curl --restart=Never -- sleep 3600
kubectl exec -n payment-mesh debug-curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://api.exchangerate.host/latest
```
Expect `200`. If your mesh's `outboundTrafficPolicy` is `REGISTRY_ONLY`
and you delete the ServiceEntry, re-run the same command — it should
now fail/hang, proving the ServiceEntry was the thing making it work.

**Step 5 — clean up:**
```bash
kubectl delete pod debug-curl -n payment-mesh --grace-period=0 --force
kubectl delete -f service-entry-exchangerate.yaml
```

**What this demonstrates:** how to deliberately, explicitly register
external dependencies instead of relying on an implicit "allow
everything" egress posture — a real production security consideration.

---

## Lab 6 (bonus/extension): TLS termination on the ingress gateway

**Domain:** Traffic Management

**Task:** Add HTTPS with `SIMPLE` TLS termination to this repo's
ingress gateway.

### Step-by-step solution

**Step 1 — generate a self-signed certificate for testing** (a real
deployment would use a CA-issued cert instead):
```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout tls.key -out tls.crt -subj "/CN=payment-mesh.local"
```

**Step 2 — create a Kubernetes TLS secret in `istio-system`** (this is
required — the ingress gateway pods run there, and Istio's ingress
gateway only reads TLS secrets from its own namespace by default):
```bash
kubectl create secret tls payment-mesh-tls \
  --cert=tls.crt --key=tls.key -n istio-system
```

**Step 3 — edit `deploy/istio/ingress-gateway.yaml`**, adding a second
`server` entry to the existing `Gateway` (keep the original port-80
entry too, or remove it if you want HTTPS-only):
```yaml
servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
      - "*"
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

**Step 4 — re-apply:**
```bash
kubectl apply -f deploy/istio/ingress-gateway.yaml
```

**Step 5 — test over HTTPS.** If you're port-forwarding for local
access, forward port 443 too:
```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8443:443 &

curl -k -X POST https://localhost:8443/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
(`-k` skips certificate validation, since this is a self-signed cert
for a fake hostname — never do this against a real production
endpoint.)

**What this demonstrates:** TLS termination happens at the mesh edge,
not in your application — `gateway`'s own Spring Boot code has zero
awareness that HTTPS was ever involved.

---

## Lab 7: Inspect Envoy config with `istioctl proxy-config`

**Domain:** Traffic Management

**Task:** Use `istioctl proxy-config` to inspect the actual routes the
`gateway` pod's Envoy sidecar has been programmed with for calls to
`payment-service`.

### Step-by-step solution

**Step 1 — find the gateway pod's exact name:**
```bash
kubectl get pods -n payment-mesh -l app=gateway
```

**Step 2 — inspect its clusters** (a "cluster" in Envoy terms is a
group of upstream endpoints — this is where you'll see
`payment-service`'s subsets):
```bash
istioctl proxy-config clusters <gateway-pod-name> -n payment-mesh | grep payment-service
```
You should see entries corresponding to the `v1`/`v2`/`v3` subsets
defined in `destination-rule-payment-service.yaml`.

**Step 3 — inspect its routes** (this is where VirtualService routing
rules actually land, as compiled Envoy config):
```bash
istioctl proxy-config routes <gateway-pod-name> -n payment-mesh -o json | less
```
Search the output for `payment-service` — you'll see the exact
weighted-cluster or header-match rules currently in effect, in raw
Envoy form, not the friendlier YAML you wrote.

**Step 4 — cross-check against what you expect.** Whatever
VirtualService is currently applied (baseline v1, canary, header-based
— whichever you left active from earlier labs), the specific
percentages or match conditions you see in this raw Envoy config
**must** match what's in the applied YAML. If they don't, that's a
strong signal the config hasn't propagated yet, or the resource wasn't
applied to the namespace/host you thought.

**Step 5 (bonus) — inspect listeners too**, to see the full picture of
what ports Envoy is actually listening on:
```bash
istioctl proxy-config listeners <gateway-pod-name> -n payment-mesh
```

**What this demonstrates:** the ability to verify Istio configuration
against **ground truth** (what Envoy actually received), rather than
just trusting that `kubectl apply` succeeded — an essential real-world
and exam troubleshooting skill.

---

## Lab 8: Timeout demo

**Domain:** Resilience and Fault Injection

**Task:** Apply this repo's `virtual-service-all-v3-resilient.yaml` and
this repo's v3 chaos toggle to demonstrate the timeout in action.

### Step-by-step solution

**Step 1 — route everything to v3, with the resilience rule attached:**
```bash
kubectl apply -f deploy/istio/examples/virtual-service-all-v3-resilient.yaml
```
Confirm what you just applied includes both a route AND a `timeout`/
`retries` block:
```bash
kubectl get virtualservice payment-service -n payment-mesh -o yaml
```

**Step 2 — turn on v3's chaos mode with a delay bigger than the
timeout you're about to test against:**
```bash
kubectl set env deployment/payment-service-v3 -n payment-mesh \
  CHAOS_ENABLED=true CHAOS_DELAY_MS=5000 CHAOS_FAILURE_RATE=0
```
`CHAOS_FAILURE_RATE=0` deliberately isolates pure delay — every
request sleeps 5 seconds, none throw their own exception, so any
failure you see is purely the *timeout* acting, not v3's own error
handling.

**Step 3 — wait for the rollout** (changing env vars restarts the
Deployment automatically):
```bash
kubectl rollout status deployment/payment-service-v3 -n payment-mesh
```

**Step 4 — time a request:**
```bash
time curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Look at the `real` time reported. Expect it to land around **2
seconds** — the `timeout: 2s` configured in the VirtualService — NOT
the full 5-second delay v3 is actually sleeping for.

**Step 5 — understand what actually happened:** Envoy gave up waiting
at 2s and returned an error to `gateway` (a `504`), rather than the
caller hanging until v3 eventually responded at the 5s mark. This is
the entire value proposition of a configured timeout: a fast, bounded
failure instead of an unbounded hang.

**Step 6 (optional) — observe that retries don't rescue this specific
case.** Even though `retries.attempts: 2` is configured, every retry
attempt hits the *same* single `payment-service-v3` replica, which is
still sleeping 5s on every call — so retries can't find a "different,
faster" instance to succeed against. The **timeout** is what actually
bounds the damage here, not the retries.

**Step 7 — clean up:**
```bash
kubectl set env deployment/payment-service-v3 -n payment-mesh CHAOS_ENABLED=false
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** the practical difference between an
unbounded hang and a fast, predictable failure — purely from Istio
configuration, no application code involved.

---

## Lab 9: Circuit breaking / outlier detection demo

**Domain:** Resilience and Fault Injection

**Task:** Using this repo's existing outlier detection config
(`consecutive5xxErrors: 3`, `baseEjectionTime: 30s`), force
`payment-service-v3` to fail consistently and observe the circuit open.

### Step-by-step solution

**Step 1 — route everything to v3** (reuse the same file from Lab 8,
or the plain `all-v3` one):
```bash
kubectl apply -f deploy/istio/examples/virtual-service-all-v3.yaml
```

**Step 2 — make v3 fail on every request, with zero delay** (isolating
pure failures from the timeout behavior you just tested in Lab 8):
```bash
kubectl set env deployment/payment-service-v3 -n payment-mesh \
  CHAOS_ENABLED=true CHAOS_DELAY_MS=0 CHAOS_FAILURE_RATE=1.0
kubectl rollout status deployment/payment-service-v3 -n payment-mesh
```

**Step 3 — confirm the outlier detection policy that's already
watching for this** (this was applied back in Phase 6 and doesn't
need re-applying, but worth re-reading before testing):
```bash
kubectl get destinationrule payment-service -n payment-mesh -o yaml
```
Note `consecutive5xxErrors: 3`, `interval: 10s`, `baseEjectionTime: 30s`,
`maxEjectionPercent: 100`, scoped to the `v3` subset only.

**Step 4 — send requests one at a time, with a short pause between
each, and watch the HTTP status codes:**
```bash
for i in $(seq 1 6); do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
  sleep 1
done
```

**Step 5 — interpret the pattern you should see:**
- **Requests 1-3:** fail with v3's own real error (whatever status
  code the app itself/Envoy returns for the thrown exception) — Envoy
  is still trying to reach v3 normally each time.
- **Request 4 onward:** after the 3rd consecutive 5xx, Envoy ejects the
  v3 endpoint from its load-balancing pool entirely. Further requests
  fail **immediately**, typically with a `503` and a "no healthy
  upstream" style message — Envoy isn't even attempting to reach the
  pod anymore.

**Step 6 — wait out the ejection window and try again:**
```bash
sleep 30
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
After `baseEjectionTime` (30s) passes, Envoy allows v3 back into
rotation for a "trial" request — since chaos is still set to fail
100%, it'll likely get re-ejected quickly again.

**Step 7 — understand the single-replica caveat.** With
`maxEjectionPercent: 100` and only 1 replica of v3, "ejecting the
unhealthy endpoint" means a **total, temporary outage** of that
version — there's no second, healthy v3 pod to fail over to. To see
real graceful failover instead of a full outage, scale up first:
```bash
kubectl scale deployment/payment-service-v3 -n payment-mesh --replicas=3
```
With 3 replicas and, say, `CHAOS_FAILURE_RATE=0.5` instead of `1.0`,
you'd see occasional ejections of individual unhealthy pods while
others keep serving traffic — a meaningfully different, more realistic
outcome.

**Step 8 — clean up:**
```bash
kubectl set env deployment/payment-service-v3 -n payment-mesh CHAOS_ENABLED=false
kubectl scale deployment/payment-service-v3 -n payment-mesh --replicas=1
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** the circuit breaker pattern in action, plus
an honest, hands-on understanding of its real limitation at low
replica counts — a nuance the exam expects you to reason about, not
just define.

---

## Lab 10: Fault injection demo

**Domain:** Resilience and Fault Injection

**Task:** Apply this repo's
`virtual-service-fraud-fault-injection.yaml` and describe the two
independent probabilities at play.

### Step-by-step solution

**Step 1 — route payment traffic to v2**, which always calls
`fraud-detection-service` (isolating this test from v3's own app-level
chaos toggle):
```bash
kubectl apply -f deploy/istio/examples/virtual-service-all-v2.yaml
```

**Step 2 — apply the fault injection rule to `fraud-detection-service`:**
```bash
kubectl apply -f deploy/istio/examples/virtual-service-fraud-fault-injection.yaml
```

**Step 3 — read the rule before testing, so you know what to expect:**
```bash
kubectl get virtualservice fraud-detection-service -n payment-mesh -o yaml
```
Note two independent fields under `fault`:
- `delay`: 50% chance, 5-second fixed delay
- `abort`: 20% chance, HTTP 500

**Step 4 — send a batch of requests and observe the spread of
outcomes:**
```bash
for i in $(seq 1 10); do
  echo "--- Request $i ---"
  time curl -s -o /dev/null -w "HTTP %{http_code}\n" -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
done
```

**Step 5 — categorize what you see across the 10 requests.** Because
`delay` and `abort` are evaluated **independently** per request (not
mutually exclusive), across enough samples you should observe roughly:
- Some requests: fast, normal `200` (neither delay nor abort triggered)
- Some requests: slow (~5s extra) but still `200` (delay only)
- Some requests: fast but failing (abort only)
- Some requests: slow AND failing (both triggered)

**Step 6 — understand why failures look "unhandled."** Since neither
`payment-service` nor `gateway` in this demo explicitly catches a
failed fraud-check call, an aborted request surfaces as a raw,
generic `500` all the way up to you — not a polished
`"status": "REJECTED"` JSON body. This is intentional: it's a clean
demonstration of an unhandled dependency failure propagating through
the mesh, exactly the kind of gap you'd want a circuit breaker,
fallback, or explicit error handling to cover in a real system.

**Step 7 — clean up:**
```bash
kubectl delete -f deploy/istio/examples/virtual-service-fraud-fault-injection.yaml
kubectl apply -f deploy/istio/virtual-service-payment-service-v1.yaml
```

**What this demonstrates:** the purest "Istio superpower" of the three
resilience labs — making a perfectly healthy service misbehave, with
zero code, environment variables, or rebuilds involved at all.

---

## Lab 11: STRICT mTLS blocks a non-mesh caller

**Domain:** Securing Workloads

**Task:** Apply this repo's `peer-authentication.yaml` (STRICT) and
prove it blocks a caller with no sidecar at all.

### Step-by-step solution

**Step 1 — apply STRICT mTLS namespace-wide:**
```bash
kubectl apply -f deploy/istio/peer-authentication.yaml
```

**Step 2 — confirm it's active:**
```bash
kubectl get peerauthentication -n payment-mesh
```

**Step 3 — first, confirm the LEGITIMATE flow still works** (mTLS
between mesh members should be completely transparent to them):
```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
This should succeed exactly as before — the ingress gateway and every
service already have sidecars issuing/validating certificates
automatically.

**Step 4 — now create a caller with NO Istio sidecar at all**, in a
namespace that was never labeled for sidecar injection:
```bash
kubectl run debug-curl-external -n default --image=curlimages/curl --restart=Never -- sleep 3600
```

**Step 5 — attempt a direct, plain HTTP call to a service inside the
STRICT-mTLS namespace:**
```bash
kubectl exec -n default debug-curl-external -- \
  curl -s -m 5 http://order-service.payment-mesh.svc.cluster.local:8081/orders/anything
```

**Step 6 — interpret the result.** Expect this to **hang and time out,
or have the connection reset** — not a clean HTTP error code. This is
an important distinction from Lab 12's `403`: this call fails at the
**transport layer**. `order-service`'s sidecar demands a valid mTLS
handshake before any HTTP request is even processed; a plain HTTP
client has no certificate to present at all, so it never gets far
enough to be evaluated by any `AuthorizationPolicy`.

**Step 7 — clean up:**
```bash
kubectl delete pod debug-curl-external -n default --grace-period=0 --force
```

**What this demonstrates:** mTLS is a transport-level trust
requirement, enforced before any application-level authorization logic
even runs — the foundational layer everything else in Lab 12 builds on
top of.

---

## Lab 12: AuthorizationPolicy blocks a wrong-identity caller

**Domain:** Securing Workloads

**Task:** Apply this repo's `authorization-policy-order-service.yaml`
and prove it blocks a caller with valid mTLS but the wrong identity.

### Step-by-step solution

**Step 1 — apply the policy:**
```bash
kubectl apply -f deploy/istio/authorization-policy-order-service.yaml
```

**Step 2 — read what it actually says:**
```bash
kubectl get authorizationpolicy order-service -n payment-mesh -o yaml
```
Note the single rule: only the principal
`cluster.local/ns/payment-mesh/sa/gateway` is allowed. Because this is
the only `ALLOW` rule and it selects `order-service`, everything else
is implicitly denied by default.

**Step 3 — confirm the LEGITIMATE flow (via `gateway`, which DOES run
as the `gateway` ServiceAccount) still works:**
```bash
curl -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Should succeed as always.

**Step 4 — create a pod INSIDE the mesh** (same namespace, so it gets a
sidecar and valid mTLS certificates automatically) but under the
default ServiceAccount, not `gateway`:
```bash
kubectl run debug-curl -n payment-mesh --image=curlimages/curl --restart=Never -- sleep 3600
```
Give it a few seconds to fully start with its sidecar:
```bash
kubectl wait --for=condition=Ready pod/debug-curl -n payment-mesh --timeout=30s
```

**Step 5 — confirm its actual identity, for clarity:**
```bash
kubectl get pod debug-curl -n payment-mesh -o jsonpath='{.spec.serviceAccountName}'
```
Should print `default` — NOT `gateway`.

**Step 6 — attempt to call `order-service` directly, completely
bypassing `gateway`:**
```bash
kubectl exec -n payment-mesh debug-curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://order-service:8081/orders/anything
```

**Step 7 — interpret the result.** Expect **`403`** — a clean,
immediate HTTP-level rejection, very different from Lab 11's
hang/reset. This pod has a perfectly valid mTLS certificate (it's
inside the mesh) — the connection itself is fully trusted. It's simply
not on `order-service`'s allow-list, so `AuthorizationPolicy` rejects
it at the application layer, one level above where mTLS operates.

**Step 8 — clean up:**
```bash
kubectl delete pod debug-curl -n payment-mesh --grace-period=0 --force
```

**What this demonstrates:** the two-layer security model in one
side-by-side comparison with Lab 11 — "are you a trusted mesh member at
all" (mTLS) vs. "are you specifically allowed to call this" (Authorization
Policy) are genuinely different questions, failing in genuinely
different ways.

---

## Lab 13 (design exercise): JWT-based end-user authentication

**Domain:** Securing Workloads

**Task:** Sketch the resources needed to require a valid JWT (issued by
`https://example-issuer.com`) on all calls to `gateway`'s `/checkout`
endpoint. *(Not implemented in this repo — a from-scratch design
exercise, since it requires an actual JWT issuer to fully execute
end-to-end.)*

### Step-by-step solution

**Step 1 — understand what you're adding on top of.** Everything this
repo already enforces (mTLS, AuthorizationPolicy-by-ServiceAccount) is
about **service identity** — which workload is calling. JWT-based auth
adds a separate, additional layer: **end-user identity** — which human
user, authenticated by an external identity provider, is behind this
request.

**Step 2 — define a `RequestAuthentication`** telling Istio how to
validate JWTs presented to `gateway`:
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
    - issuer: "https://example-issuer.com"
      jwksUri: "https://example-issuer.com/.well-known/jwks.json"
```
Apply it:
```bash
kubectl apply -f gateway-jwt-requestauth.yaml
```

**Step 3 — understand a critical, commonly-tested nuance:**
`RequestAuthentication` on its own only **validates** a JWT if one is
present — a request with **no** `Authorization` header at all is still
allowed through unchanged. It does not, by itself, make a JWT
mandatory.

**Step 4 — add an `AuthorizationPolicy` that actually requires a valid
token**, by checking for a `requestPrincipals` value (which only gets
populated when a JWT successfully validated against the rule in Step
2):
```yaml
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
            requestPrincipals: ["https://example-issuer.com/*"]
```
Apply it:
```bash
kubectl apply -f gateway-require-jwt-authz.yaml
```

**Step 5 — to actually test this end-to-end**, you'd need a real
signed JWT from a matching issuer. Two practical options:
- Stand up a lightweight test OIDC provider (many exist for local
  testing) and issue yourself a token.
- Use Istio's own bundled sample JWT and test key (found under
  `security/tools/jwt/samples/` in the Istio source/release you already
  downloaded for Phase 4) — designed specifically for exercises like
  this one.

**Step 6 — test both cases once you have a token:**
```bash
# Without a token - should now be rejected
curl -X POST http://localhost:8080/checkout -H "Content-Type: application/json" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'

# With a valid token - should succeed
curl -X POST http://localhost:8080/checkout -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-jwt-here>" \
  -d '{"amount": 250.00, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```

**What this demonstrates:** JWT/end-user authentication is a distinct,
additive security layer on top of (never a replacement for) the
service-to-service mTLS and AuthorizationPolicy this repo already
enforces — a concept the ICA exam tests independently of the
hands-on Phase 7 work.

---

## Lab 14: Rate limiting at the ingress gateway

**Domain:** Advanced Scenarios

**Task:** Apply this repo's rate-limiting `EnvoyFilter` and prove it
enforces a limit before any backend service is even reached.

### Step-by-step solution

**Step 1 — apply the filter:**
```bash
kubectl apply -f deploy/istio/envoy-filter-rate-limit-gateway.yaml
```

**Step 2 — confirm it's targeting the right workload:**
```bash
kubectl get envoyfilter ratelimit-gateway -n istio-system -o yaml
```
Note `workloadSelector.labels.istio: ingressgateway` — this applies
directly to the ingress gateway's own Envoy proxy, not to `gateway` or
any other service.

**Step 3 — read the token bucket configuration** embedded in the
filter: `max_tokens: 10`, `tokens_per_fill: 10`, `fill_interval: 60s` —
10 requests allowed, refilling to 10 again every 60 seconds.

**Step 4 — burst more than 10 requests and record every status code:**
```bash
for i in $(seq 1 15); do
  curl -s -o /dev/null -w "Request $i: %{http_code}\n" -X POST http://localhost:8080/checkout \
    -H "Content-Type: application/json" \
    -d '{"amount": 100, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
done
```
Expect requests 1-10 to return `200`, and 11-15 to return `429 Too Many
Requests`.

**Step 5 — confirm it's specifically the rate limiter causing the
`429`s** (not some unrelated error), by checking for the header the
filter adds only to blocked responses:
```bash
curl -i -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}' \
  | grep -i x-local-rate-limit
```
If you're still within the same 60s window from Step 4, you should see
this header on the response, confirming Envoy's local rate limit
filter specifically produced it.

**Step 6 — wait for the bucket to refill and confirm normal service
resumes:**
```bash
sleep 60
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/checkout \
  -H "Content-Type: application/json" \
  -d '{"amount": 100, "currency": "USD", "cardNumber": "4111-1111-1111-1111"}'
```
Expect `200` again.

**Step 7 (optional) — see the local-vs-global distinction for
yourself** by scaling the ingress gateway:
```bash
kubectl scale deployment/istio-ingressgateway -n istio-system --replicas=3
```
Since this is a **local** rate limit (each Envoy proxy keeps its own
independent token bucket), the effective total limit across the whole
gateway now becomes closer to 30 requests/minute — whichever of the 3
replicas a given request happens to land on. Scale back down when
done:
```bash
kubectl scale deployment/istio-ingressgateway -n istio-system --replicas=1
```

**Step 8 — clean up:**
```bash
kubectl delete -f deploy/istio/envoy-filter-rate-limit-gateway.yaml
```

**What this demonstrates:** protection enforced at the absolute edge of
the mesh — none of `gateway`, `order-service`, or `payment-service`
ever see the blocked requests at all, and no application code was
touched to achieve it.
