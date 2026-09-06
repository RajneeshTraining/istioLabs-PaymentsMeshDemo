# "Client Sent an HTTP Request to an HTTPS Server": A Real Istio Troubleshooting Walkthrough (ICA Exam Prep)

*A hands-on debugging story that touches four core Istio Certified Associate (ICA) exam topics in one go: `Gateway`, `VirtualService`, `DestinationRule`, and NodePort service routing — plus three valid ways to fix it, ranked by speed and blast radius.*

---

## Why this scenario matters for the ICA exam

The ICA exam loves testing the relationship between four resources:

- **`Gateway`** — what the mesh edge (ingress) accepts
- **`VirtualService`** — where accepted traffic is routed
- **`DestinationRule`** — how traffic is treated on the way to its destination (load balancing, mTLS, TLS origination)
- **`Service` / NodePort** — the Kubernetes plumbing that exposes the mesh externally

Most real (and exam) Istio bugs live in the **seams between these four objects**, not inside any single one. This walkthrough is a real debugging session that shows exactly that — and, once the root cause is found, three legitimate ways to fix it, so you can recognize all of them on the exam and pick the right one under time pressure.

---

## The setup

```bash
root@controlplane:~$ k get gw -o wide
NAME              AGE
booking-gateway   18m

root@controlplane:~$ k get svc -o wide
NAME              TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE   SELECTOR
booking-service   ClusterIP   10.106.80.235  <none>        443/TCP    23m   app=booking-service
kubernetes        ClusterIP   10.96.0.1      <none>        443/TCP    17d   <none>

root@controlplane:~$ k get svc -n istio-system -o wide
NAME                   TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)                                            AGE   SELECTOR
istio-ingressgateway   NodePort   10.98.230.208   <none>        15021:30870/TCP,80:30000/TCP,443:30443/TCP,...     24m   app=istio-ingressgateway,istio=ingressgateway
istiod                 ClusterIP  10.107.29.53    <none>        15010/TCP,15012/TCP,443/TCP,15014/TCP             24m   app=istiod,istio=pilot
```

Two facts worth memorizing the habit of checking:

- The ingress gateway Service maps **port 80 → nodePort 30000** and **port 443 → nodePort 30443**.
- `booking-service` only exposes **443/TCP** at the Kubernetes Service level.

### The symptom

```bash
root@controlplane:~$ curl http://booking.example.com:30000/bookings
Client sent an HTTP request to an HTTPS server.
```

A plaintext call to the "HTTP" NodePort fails with a TLS-mismatch error. Time to trace the request path.

---

## Root cause analysis

**Step 1 — Check the Gateway listener:**

```bash
k get gw booking-gateway -o yaml
```

```yaml
spec:
  servers:
  - hosts: [booking.example.com]
    port:
      name: http
      number: 80
      protocol: HTTP
```

Clean. `protocol: HTTP` matches the plaintext request on the `80 → 30000` mapping. **The Gateway is not the problem.**

**Step 2 — Check the VirtualService:**

```bash
k get vs -o yaml
```

```yaml
spec:
  gateways: [booking-gateway]
  hosts: [booking.example.com]
  http:
  - route:
    - destination:
        host: booking-service
        port:
          number: 443
```

Found it. The `VirtualService` forwards HTTP traffic to `booking-service` on **port 443 as plaintext** — `VirtualService.http` routes never encrypt traffic on their own. Since `booking-service` only exposes 443 and its pod is terminating TLS there, Envoy is handing it a raw HTTP request. The pod (correctly) rejects it with the exact error we saw.

![Traffic flow diagram showing where the request breaks](traffic-flow.svg)

```
curl (plain HTTP)
   -> istio-ingressgateway :30000   [Gateway: HTTP]        OK
   -> VirtualService "booking"      [routes to :443]
   -> booking-service :443          [pod expects TLS]      FAILS
```

Now that the root cause is confirmed, here are three ways to fix it. All three are technically correct — which one is "best" actually depends on whether you're patching a live production issue or answering an ICA exam question, so read both recommendation sections below before picking one.

---

## ✅ Recommended for the ICA exam: Gateway `TLS PASSTHROUGH`

Here's the detail that should jump out immediately in an exam scenario: **`booking-service` exposes only port 443, nothing on 80.** That's the standard signal Istio's own documentation uses to teach `PASSTHROUGH` — a backend that already owns and terminates its own TLS certificate, with no plaintext port available at all. Traffic Management — which covers `Gateway`, `VirtualService`, and `DestinationRule` — is the single largest ICA domain at 40% of the exam, and Gateway TLS modes (`SIMPLE`, `MUTUAL`, `PASSTHROUGH`, `AUTO_PASSTHROUGH`) are a named part of that domain. This is the pattern the exam is most likely testing you on.

**Gateway:**

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: booking-gateway
  namespace: default
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - booking.example.com
```

**VirtualService** — this becomes a `tls:` block matched by SNI, not an `http:` block, since Envoy never decrypts the traffic to read HTTP headers or paths:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: booking
  namespace: default
spec:
  hosts: [booking.example.com]
  gateways: [booking-gateway]
  tls:
  - match:
    - port: 443
      sniHosts: [booking.example.com]
    route:
    - destination:
        host: booking-service
        port:
          number: 443
```

Client now connects over HTTPS on the 443 NodePort:

```bash
curl https://booking.example.com:30443/bookings \
  --resolve booking.example.com:30443:<ingress-node-ip> -k
```

**Why this is the answer to reach for on the exam:**

- The backend having **only** a 443 port with no plaintext option is the classic tell for "this workload already does its own TLS — don't terminate it at the gateway, pass it through."
- It's directly testing named Gateway TLS-mode knowledge (`SIMPLE` vs `MUTUAL` vs `PASSTHROUGH` vs `AUTO_PASSTHROUGH`), which is explicitly called out in the highest-weighted domain.
- It requires no assumption about a `DestinationRule` existing or being the "missing piece" — it fixes the problem using the two resources the question already gave you (`Gateway` + `VirtualService`), which is how ICA scenario questions are typically scoped.
- It matches Istio's own documented reference pattern for exposing an HTTPS-terminating backend, so it's the answer least likely to be marked wrong for "missing the point" of the question.

**Trade-off to know for the exam too:** you lose HTTP-layer (L7) routing at the gateway — no path/header matching, no HTTP-aware retries — since Envoy is forwarding encrypted bytes it can't inspect. If a question adds "...and the gateway must also route by URL path," PASSTHROUGH stops being viable and you're back to TLS origination.

---

## Production-pragmatic alternative: `DestinationRule` with TLS origination

Since the `Gateway` and `VirtualService` are otherwise correctly configured, and the *only* missing piece is telling Envoy to encrypt traffic before it reaches a TLS-only backend, add a single new resource:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: booking-service
  namespace: default
spec:
  host: booking-service
  trafficPolicy:
    tls:
      mode: SIMPLE
```

`tls.mode: SIMPLE` tells the gateway's Envoy proxy to **originate TLS** to `booking-service:443` — wrapping the outbound request in TLS before it leaves the gateway, matching exactly what the pod expects.

![Production-pragmatic fix flow with DestinationRule added](recommended-fix-flow.svg)

**Why you'd reach for this in a real production incident:**

- **Zero changes** to the existing `Gateway` or `VirtualService` — both stay exactly as they are.
- **No application/container changes** — the backend keeps doing exactly what it was doing.
- **Keeps HTTP-layer (L7) routing** — path/header matching, retries, timeouts, etc. all keep working, since the gateway still parses the request as HTTP before originating TLS downstream.
- **Smallest blast radius** — one new object, easy to roll back, easy to test in isolation, no client-facing URL scheme change (still plain `http://` from the caller's perspective).

This is genuinely the better choice **operationally** — if you're on call and need the fastest, lowest-risk patch to a live system without touching client behavior or losing path-based routing, this is it. It's just less likely to be the *expected* answer on a scenario-based exam question that's clearly probing Gateway TLS-mode knowledge.

Verify:

```bash
curl http://booking.example.com:30000/bookings -v
```

You should now get a normal application response instead of the TLS mismatch error.

---

## Alternate approach 1: Re-architect the backend to speak plain HTTP + mesh mTLS

If you're not just patching the bug but **redesigning the service** to be properly mesh-native, the idiomatic long-term pattern is: let the **application speak plain HTTP**, and let **Istio's sidecar-to-sidecar mTLS** (`ISTIO_MUTUAL`) handle encryption on the wire instead of the app terminating its own TLS.

Changes required:

1. Container listens on a plain HTTP port (e.g., `8080`) instead of terminating TLS itself.
2. Kubernetes `Service` `port`/`targetPort` updated to match.
3. `VirtualService` destination port updated to the new plaintext port.

```yaml
spec:
  http:
  - route:
    - destination:
        host: booking-service
        port:
          number: 8080   # plaintext internally — Istio mTLS encrypts the wire
```

**Trade-off:** requires touching the application/container, not just Istio config. Best when you're already refactoring the service, not when you just need the outage fixed.

---

## Alternate approach 2: Convert the Gateway to TLS `PASSTHROUGH`

If the backend's own certificate must remain end-to-end (compliance, customer-managed certs, no decryption at the mesh edge allowed), configure the gateway to pass the encrypted connection straight through without terminating it.

**Gateway:**

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: booking-gateway
  namespace: default
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: tls
      protocol: TLS
    tls:
      mode: PASSTHROUGH
    hosts:
    - booking.example.com
```

**VirtualService** — note this becomes a `tls:` block matched by SNI, not an `http:` block, since Envoy never decrypts the traffic to read HTTP headers or paths:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: booking
  namespace: default
spec:
  hosts: [booking.example.com]
  gateways: [booking-gateway]
  tls:
  - match:
    - port: 443
      sniHosts: [booking.example.com]
    route:
    - destination:
        host: booking-service
        port:
          number: 443
```

Client now connects over HTTPS on the 443 NodePort:

```bash
curl https://booking.example.com:30443/bookings \
  --resolve booking.example.com:30443:<ingress-node-ip> -k
```

**Trade-off:** both `Gateway` and `VirtualService` change structure, the client must switch to `https://` with correct SNI, and — importantly — **you lose HTTP-layer routing at the gateway** (no path-based routing, header matching, or HTTP-aware retries), since Envoy is just forwarding encrypted bytes it can't inspect.

---

## Comparing all three

![Comparison of the three fix approaches](three-options-comparison.svg)

| | Gateway PASSTHROUGH | DestinationRule (SIMPLE) | Re-architect backend |
|---|---|---|---|
| Resources touched | Gateway + VS (rewritten) | +1 (`DestinationRule`) | App + Service + VS |
| App/container changes | None | None | Yes |
| Keeps L7 (path/header) routing | **No** | Yes | Yes |
| Client-facing change | Must use `https://` + SNI | None | None |
| Best fit | **Backend already fully owns its TLS cert, no plaintext port exists at all** | Fast, low-risk patch to a live system without touching Gateway/VS | Long-term mesh-native redesign |

---

## Which one should you reach for — exam vs. production

This is the one place where the "right" answer genuinely depends on context, so hold both of these in your head separately:

**On the ICA exam → `Gateway` `TLS PASSTHROUGH`.**
The tell is `booking-service` exposing **only** port 443 with no plaintext alternative — that's the standard signal for "this backend already terminates its own TLS, don't decrypt it at the edge." Traffic Management is 40% of the exam and explicitly covers Gateway TLS modes, and PASSTHROUGH is the documented, named pattern for exactly this backend shape. Scenario-based questions tend to reward recognizing the *documented* pattern for the situation described, not inventing an extra resource (`DestinationRule`) that the question didn't hint at needing.

**In a live production incident → `DestinationRule` with `tls.mode: SIMPLE`.**
If your actual goal is "stop the outage with the least risk right now," adding one `DestinationRule` and touching nothing else is safer: no client-facing URL/SNI change, no loss of path-based routing, and the smallest possible diff to review and roll back.

**Rule of thumb:**
- Question emphasizes *"the backend already has its own certificate / only exposes 443 / must not be decrypted at the gateway"* → **PASSTHROUGH**.
- Question emphasizes *"the Gateway and VirtualService are correct, something in the traffic policy is missing"* or you need to preserve HTTP-layer routing → **DestinationRule TLS origination**.
- Question emphasizes *"redesign for mesh-native mTLS"* or asks about sidecar-to-sidecar encryption → **plain HTTP backend + `ISTIO_MUTUAL`**.

Reading which constraint the question is actually testing is the real skill here — not memorizing one "always correct" answer.

---

## Key takeaways for ICA exam prep

| Concept | What to remember |
|---|---|
| `Gateway.spec.servers[].port.protocol` | Defines what the **edge listener** expects. Mismatch vs. client request → "Client sent an HTTP request to an HTTPS server." |
| `VirtualService.http[].route[].destination` | Only controls **routing**, never encryption. It will happily forward plaintext to a TLS-expecting port. |
| `DestinationRule.trafficPolicy.tls.mode` | Controls **TLS origination** to the destination: `DISABLE`, `SIMPLE`, `MUTUAL`, `ISTIO_MUTUAL`. `SIMPLE` is the fast fix for this exact symptom. |
| `Gateway` TLS `PASSTHROUGH` | Edge never decrypts; routing at the gateway becomes SNI-based only, losing L7 routing. |
| NodePort mapping (`80:30000/TCP`) | Just a Kubernetes port forward — tells you nothing about the protocol Envoy expects. Always check the `Gateway` CRD for that. |
| Debugging order | Client → `Gateway` → `VirtualService` → `DestinationRule` → `Service` → `Pod`. Walk the whole chain. |

---

## Closing thought

*"Client sent an HTTP request to an HTTPS server"* can come from either end of the request path — a misconfigured `Gateway` listener, or a `VirtualService` forwarding plaintext to a TLS-only backend with no TLS origination configured. All three fixes above are technically correct; what separates a good answer from a great one is reading the specific constraint the scenario hands you. A backend with **only** a 443 port and no plaintext alternative is Istio's textbook signal for `PASSTHROUGH` — know that pattern cold for the exam. Save the `DestinationRule` fix for when you need the smallest possible diff to a live system, and the full backend redesign for when you're actually rearchitecting the service to be mesh-native.
