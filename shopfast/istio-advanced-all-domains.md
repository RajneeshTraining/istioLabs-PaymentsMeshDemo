# Istio Deep Dive: Advanced Real-World Problems Across All Four Domains

The first four posts covered the fundamentals of each domain, one at a time. This post goes further — twenty new, more complex problems, five per domain, closer to what you'll actually face in production incidents and in exam scenario questions that combine multiple concepts at once. Same format throughout: **Validate Before**, **Fix**, **Validate After**.

## The Scenario: ShopFast (Recap)

Same five core services in the `shop` namespace — `frontend`, `cart`, `orders`, `payment`, `inventory` — now running across two clusters (`shop-east`, `shop-west`) for the multi-cluster problems, with a `partners` namespace added for third-party integrations.

---

# Domain 1: Securing Workloads

## Problem 1: Namespace and Workload-Level mTLS Policies Contradict Each Other

**The problem.** The mesh-wide `PeerAuthentication` is `PERMISSIVE`. A namespace-level policy on `shop` sets `STRICT`. A well-meaning engineer, trying to debug a legacy client, adds a workload-level `PeerAuthentication` on `inventory` set to `DISABLE`. Nobody is sure which one actually wins, and `inventory` is now accepting plaintext traffic without anyone realizing it.

### Validate Before

```bash
kubectl get peerauthentication -A
```

```
NAMESPACE      NAME       MODE
istio-system   default    PERMISSIVE
shop           default    STRICT
shop           inventory  DISABLE
```

Three policies at three scopes. Confirm which one is actually in effect on `inventory` — don't assume:

```bash
istioctl x describe pod <inventory-pod> -n shop
```

```
PeerAuthentication for workload: DISABLE (found via workload-specific policy "inventory.shop")
```

That output is the proof: **workload-level always beats namespace-level, which always beats mesh-level**, regardless of which is "more secure." `inventory` is running with mTLS disabled despite the namespace intending `STRICT`.

Confirm the plaintext acceptance directly:

```bash
kubectl run plain-client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"curlimages/curl","command":["sleep","3600"]}]}}' -- sh
# inside: curl -v http://inventory:8080  → succeeds despite no sidecar/mTLS
```

### The Fix

Remove the workload-level override; if a specific port genuinely needs plaintext (e.g., a legacy health check), scope the exception to that port only instead of disabling mTLS for the whole workload.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: inventory
  namespace: shop
spec:
  selector:
    matchLabels:
      app: inventory
  mtls:
    mode: STRICT
  portLevelMtls:
    9090:
      mode: PERMISSIVE   # legacy health-check port only
```

**Step by step:**

1. Understand the precedence order before writing any policy: workload > namespace > mesh.
2. Never use a workload-level `DISABLE` as a debugging shortcut — it silently overrides everything above it and is easy to forget about.
3. If an exception is genuinely needed, scope it with `portLevelMtls` rather than disabling the whole workload.

### Validate After

```bash
istioctl x describe pod <inventory-pod> -n shop
```

```
PeerAuthentication for workload: STRICT (except port 9090: PERMISSIVE)
```

Re-run the plaintext test on the main port:

```bash
kubectl run plain-client -n shop --rm -it --image=curlimages/curl -- \
  curl -v http://inventory:8080
# Expect: connection rejected — STRICT is enforced on 8080
```

Confirm the legacy port still accepts what it needs to:

```bash
kubectl run plain-client -n shop --rm -it --image=curlimages/curl -- \
  curl -v http://inventory:9090/healthz
# Expect: succeeds — the scoped exception works as intended
```

---

## Problem 2: A DENY Policy From a Different Team Silently Blocks a New Feature

**The problem.** The security team applies a namespace-wide `AuthorizationPolicy` with `action: DENY` to block all traffic to `/admin/*` paths across `shop`. Weeks later, the `orders` team adds a legitimate new endpoint `/admin/reconcile` for internal batch jobs, and their own `ALLOW` policy for it never seems to take effect.

### Validate Before

```bash
kubectl get authorizationpolicy -n shop
```

```
NAME                    ACTION
block-admin-paths       DENY
orders-allow-reconcile  ALLOW
```

Test the endpoint from an authorized caller:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"orders-batch"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/admin/reconcile -X POST
# 403, even though orders-allow-reconcile explicitly permits this
```

Inspect both policies to find the actual conflict:

```bash
kubectl get authorizationpolicy block-admin-paths -n shop -o yaml
kubectl get authorizationpolicy orders-allow-reconcile -n shop -o yaml
```

```yaml
# block-admin-paths
spec:
  action: DENY
  rules:
  - to:
    - operation:
        paths: ["/admin/*"]
```

The proof is in Istio's fixed evaluation order: **CUSTOM, then DENY, then ALLOW** — always, regardless of which policy was created first or which is more specific. `block-admin-paths` matches `/admin/reconcile` under its wildcard and denies the request before `orders-allow-reconcile` is ever consulted.

### The Fix

A `DENY` rule always wins over any `ALLOW`, so the fix must happen inside the `DENY` policy itself — carve out the exception there, not in a separate `ALLOW` policy.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: block-admin-paths
  namespace: shop
spec:
  action: DENY
  rules:
  - to:
    - operation:
        paths: ["/admin/*"]
    when:
    - key: request.headers[x-admin-path]
      notValues: ["/admin/reconcile"]
```

A simpler and more maintainable version narrows the `DENY` path match itself:

```yaml
  rules:
  - to:
    - operation:
        paths: ["/admin/*"]
        notPaths: ["/admin/reconcile"]
```

**Step by step:**

1. Confirm the evaluation order first — CUSTOM, then DENY, then ALLOW — before assuming your `ALLOW` policy is broken.
2. Never try to "out-ALLOW" a `DENY`; edit the `DENY` rule to exclude the exception explicitly.
3. Keep `DENY` policies narrow and well-documented, since every future `ALLOW` policy in the namespace has to work around them.

### Validate After

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"orders-batch"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/admin/reconcile -X POST
# Expect: 200
```

Confirm the rest of `/admin/*` is still blocked, so the fix didn't overcorrect:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/admin/delete-all
# Expect: 403 — still denied
```

Two results side by side — the intended exception open, everything else still shut — is the proof the `DENY` carve-out is correctly scoped.

---

## Problem 3: Outbound Calls to a Partner API Are Sent in Plaintext Despite "Using HTTPS"

**The problem.** `payment` calls a partner's REST API at `https://partner-api.example.com`. The developer configured the URL with `https://`, so everyone assumes it's encrypted end-to-end. In fact, the application code was written to call it over plain HTTP internally, relying on Istio to originate TLS outbound — except no one configured that, so the "https" call is actually plaintext all the way to the egress point.

### Validate Before

```bash
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  timeout 10 tcpdump -i any -A -s 0 port 80
```

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"payment"}}' -- \
  curl -s http://partner-api.example.com/v1/settle
```

Readable HTTP headers and body in the `tcpdump` capture is the proof — despite the app "calling HTTPS" conceptually, the actual wire traffic from the app to its own sidecar, and from the sidecar outbound, is plaintext because nothing is originating TLS.

Confirm there's no `DestinationRule` doing TLS origination:

```bash
kubectl get destinationrule -n shop -l host=partner-api.example.com
# No resources found
```

### The Fix

Configure a `ServiceEntry` for the external host and a `DestinationRule` that explicitly originates TLS, so the application can keep making a simple plaintext call to its own sidecar while Istio handles the encryption outbound.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: partner-api
  namespace: shop
spec:
  hosts:
  - partner-api.example.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
    targetPort: 443
  - number: 443
    name: https-port
    protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: partner-api-tls
  namespace: shop
spec:
  host: partner-api.example.com
  trafficPolicy:
    tls:
      mode: SIMPLE
```

**Step by step:**

1. Never assume "the URL says https" means the wire traffic is encrypted — verify what the application code and mesh config are actually doing.
2. Define the external host as a `ServiceEntry` so Istio treats it as a known destination.
3. Add a `DestinationRule` with `tls.mode: SIMPLE` (or `MUTUAL` if the partner requires client certs) so Istio originates real TLS on egress.

### Validate After

Repeat the capture:

```bash
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  timeout 10 tcpdump -i any -A -s 0 port 443
```

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"payment"}}' -- \
  curl -s http://partner-api.example.com/v1/settle
```

This time the capture on port 443 should show TLS handshake bytes and encrypted application data, not readable HTTP. Confirm the origination explicitly:

```bash
istioctl proxy-config cluster <payment-pod>.shop --fqdn partner-api.example.com -o json | grep -i tls
```

Look for `"tlsContext"` present in the cluster config — its presence, combined with unreadable capture output, is the proof outbound TLS is now actually being originated.

---

## Problem 4: A Multi-Tenant Gateway Lets One Partner See Another Partner's Requests

**The problem.** ShopFast exposes a single ingress gateway to multiple partners, each authenticated via their own JWT issuer. The `AuthorizationPolicy` checks `requestPrincipals` but not the specific claims, so a valid token from Partner A can be replayed against endpoints meant only for Partner B, because both issuers are accepted mesh-wide without per-partner scoping.

### Validate Before

```bash
kubectl get requestauthentication -n partners -o yaml
```

```yaml
jwtRules:
- issuer: "https://partner-a.example.com"
  jwksUri: "https://partner-a.example.com/jwks.json"
- issuer: "https://partner-b.example.com"
  jwksUri: "https://partner-b.example.com/jwks.json"
```

```bash
kubectl get authorizationpolicy -n partners -o yaml
```

```yaml
rules:
- from:
  - source:
      requestPrincipals: ["*"]   # accepts any valid principal from either issuer
```

Get a valid token from Partner A and use it against a Partner-B-only endpoint:

```bash
kubectl run client -n partners --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $PARTNER_A_TOKEN" \
  http://partner-gateway:8080/partner-b/data
```

A `200` here is the proof — the policy checks that *a* valid token exists, from *any* trusted issuer, but never checks that the token's issuer matches the partner the endpoint belongs to.

### The Fix

Scope each `AuthorizationPolicy` rule to the specific issuer expected for that path, not a wildcard.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: partner-a-scope
  namespace: partners
spec:
  selector:
    matchLabels:
      app: partner-gateway
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://partner-a.example.com/*"]
    to:
    - operation:
        paths: ["/partner-a/*"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: partner-b-scope
  namespace: partners
spec:
  selector:
    matchLabels:
      app: partner-gateway
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://partner-b.example.com/*"]
    to:
    - operation:
        paths: ["/partner-b/*"]
```

**Step by step:**

1. Treat `requestPrincipals: ["*"]` as a red flag in any multi-tenant setup — it authenticates but doesn't authorize per-tenant.
2. Write one scoped policy per tenant, pairing their issuer with only their own paths.
3. Remove the old wildcard policy entirely so there's no fallback path left open.

### Validate After

```bash
kubectl run client -n partners --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $PARTNER_A_TOKEN" \
  http://partner-gateway:8080/partner-b/data
# Expect: 403
```

Confirm Partner A can still reach their own endpoint:

```bash
kubectl run client -n partners --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $PARTNER_A_TOKEN" \
  http://partner-gateway:8080/partner-a/data
# Expect: 200
```

Cross-tenant access blocked, same-tenant access intact — that pairing is the proof the scoping actually isolates the two partners.

---

## Problem 5: Two Clusters Can't Establish mTLS After a Mesh Merge

**The problem.** ShopFast acquires a second team's cluster and wants their `partners` workloads to call `shop-west` services directly over mTLS. Both clusters were installed independently, each with `trustDomain: cluster.local`, but with different root CAs. Calls between them fail even though both sides are individually healthy.

### Validate Before

```bash
istioctl proxy-config secret <shop-west-pod>.shop -n shop --context shop-west
istioctl proxy-config secret <partners-pod>.partners -n partners --context partners-cluster
```

Different `ROOTCA` serials on each side, exactly as in a same-cluster cert mismatch — except here the underlying cause is structural: two independently-issued root CAs were never designed to trust each other.

```bash
kubectl run client -n partners --context partners-cluster --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"partner-client"}}' -- \
  curl -v https://payment.shop.svc.cluster.local:8080
# Connection reset — TLS trust failure
```

Check the trust domains configured on each mesh:

```bash
kubectl get configmap istio -n istio-system --context shop-west -o yaml | grep trustDomain
kubectl get configmap istio -n istio-system --context partners-cluster -o yaml | grep trustDomain
```

Both report `trustDomain: cluster.local` — identical names, but backed by different, non-federated CAs. That combination is the proof: identical trust domain strings gave a false sense of compatibility, while the actual root certificates were never shared.

### The Fix

Either issue both meshes' intermediate CAs from a shared root (the correct long-term fix), or, for scoped cross-mesh calls, configure explicit trust domain aliasing so each mesh explicitly trusts identities issued under the other's domain.

```yaml
# istio-operator.yaml on shop-west
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    trustDomain: cluster.local
    trustDomainAliases:
    - partners-cluster.local
```

**Step by step:**

1. Never assume matching `trustDomain` strings mean matching trust — check the actual CA serials.
2. For a real merge, plan on a shared root CA (via `cacerts` distributed to both clusters) rather than aliasing as a permanent solution.
3. Use `trustDomainAliases` as an interim bridge, explicitly declaring which external trust domains are accepted, and apply it to both sides.

### Validate After

```bash
istioctl proxy-config secret <shop-west-pod>.shop -n shop --context shop-west
```

Confirm the trust bundle now includes the partner cluster's root as a trusted signer, not just its own.

```bash
kubectl run client -n partners --context partners-cluster --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"partner-client"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://payment.shop.svc.cluster.local:8080
# Expect: a real HTTP response, not a connection reset
```

A successful cross-cluster handshake, plus visible aliasing in the mesh config on both sides, is the proof the federation is actually working — not just configured.

---

# Domain 2: Traffic Management

## Problem 1: A/B Testing With Sticky Sessions Keeps Routing Users to the Wrong Variant

**The problem.** ShopFast runs an A/B test on `frontend`'s checkout flow using header-based routing (`x-experiment: v2`), but wants each user consistently routed to the same variant across their whole session, not re-randomized per request. Right now, users bounce between `v1` and `v2` mid-session because there's no session affinity.

### Validate Before

```yaml
# Current config — header match only, no affinity
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend-experiment
  namespace: shop
spec:
  hosts: [frontend]
  http:
  - match:
    - headers:
        x-experiment:
          exact: v2
    route:
    - destination: {host: frontend, subset: v2}
  - route:
    - destination: {host: frontend, subset: v1}
```

Simulate the same session ID hitting the endpoint repeatedly:

```bash
for i in $(seq 1 10); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never -- \
    curl -s -H "Cookie: session=abc123" http://frontend:8080/version
done | sort | uniq -c
```

If both `v1` and `v2` responses appear for the *same* session cookie across repeated calls, that's the proof — routing is fully stateless per request, with nothing pinning a given user to one variant.

### The Fix

Use consistent-hash load balancing on the `DestinationRule`, keyed on a session identifier, so requests carrying the same key always land on the same subset.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: frontend-affinity
  namespace: shop
spec:
  host: frontend
  trafficPolicy:
    loadBalancer:
      consistentHash:
        httpCookie:
          name: session
          ttl: 3600s
```

**Step by step:**

1. Decide the affinity key — a cookie, a header, or source IP — based on what's reliably present on every request in the session.
2. Configure `consistentHash` on the `DestinationRule` for the overall service, which applies after the `VirtualService` has already picked a subset.
3. Note this doesn't replace the header-based experiment routing — it adds stickiness *within* whichever subset a user was first routed to.

### Validate After

```bash
for i in $(seq 1 10); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never -- \
    curl -s -H "Cookie: session=abc123" http://frontend:8080/version
done | sort | uniq -c
```

Expect all 10 responses to report the same variant this time. Repeat with a different session cookie and confirm it's consistently pinned to its own variant, which may differ from the first:

```bash
for i in $(seq 1 10); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never -- \
    curl -s -H "Cookie: session=xyz789" http://frontend:8080/version
done | sort | uniq -c
```

Two different sessions, each internally consistent but independent of each other, is the proof the affinity is keyed correctly rather than accidentally pinning everyone to one variant.

---

## Problem 2: Circuit Breaking Configuration Makes Things Worse Under Load

**The problem.** After Problem 4 in the earlier traffic management post (outlier detection), the team also added connection pool limits to `payment` to prevent overload. But the limits were copied from a low-traffic staging environment, and now legitimate Black Friday traffic gets circuit-broken constantly, rejecting healthy requests as if `payment` were failing.

### Validate Before

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-pool
  namespace: shop
spec:
  host: payment
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 10
      http:
        http1MaxPendingRequests: 5
        maxRequestsPerConnection: 2
```

```bash
for i in $(seq 1 50); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST &
done; wait | sort | uniq -c
```

A large share of `503`s under only 50 concurrent requests — traffic `payment` should handle easily — is the proof. Confirm it's the connection pool causing it, not the application:

```bash
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_cx_overflow|upstream_rq_pending_overflow"
```

Nonzero `overflow` counters confirm Envoy itself is rejecting requests at the connection pool layer, before they ever reach the application — the app never even sees the traffic being called "too much."

### The Fix

Right-size the pool based on real production concurrency, not a value copied from staging, and validate with an actual load test rather than a guess.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-pool
  namespace: shop
spec:
  host: payment
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 200
      http:
        http1MaxPendingRequests: 100
        maxRequestsPerConnection: 0   # unlimited reuse per connection
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s
```

**Step by step:**

1. Never copy connection pool settings across environments with different traffic volumes — size them from real metrics.
2. Pair connection pool limits with outlier detection deliberately: the pool protects against overload, outlier detection protects against a genuinely unhealthy backend — conflating the two causes exactly this kind of false-positive circuit breaking.
3. Load test the new values before trusting them in production.

### Validate After

```bash
for i in $(seq 1 50); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST &
done; wait | sort | uniq -c
```

Expect close to all `200`s at the same concurrency. Confirm the overflow counters stay flat:

```bash
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_cx_overflow|upstream_rq_pending_overflow"
```

Same load, no overflow counters climbing, near-zero `503`s — that combination is the proof the pool is now sized for reality rather than staging.

---

## Problem 3: Traffic Doesn't Prefer the Nearest Zone, Increasing Latency and Cost

**The problem.** ShopFast's `inventory` service runs pods in two availability zones. Requests from `orders` pods in zone A are frequently routed to `inventory` pods in zone B, adding cross-zone latency and unnecessary data transfer cost, even though healthy zone-A `inventory` pods exist.

### Validate Before

```bash
kubectl get pods -n shop -l app=inventory -o wide --show-labels | grep zone
```

```bash
for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders","nodeSelector":{"topology.kubernetes.io/zone":"zone-a"}}}' -- \
    curl -s http://inventory:8080/zone
done | sort | uniq -c
```

An even or unpredictable split across both zones — rather than a strong preference for zone A — is the proof there's no locality awareness configured. Confirm no locality load balancing settings exist:

```bash
kubectl get destinationrule inventory -n shop -o yaml | grep -A 10 localityLbSetting
# No output — nothing configured
```

### The Fix

Enable locality-weighted load balancing so Envoy prefers same-zone endpoints and only spills over to other zones when necessary.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: inventory-locality
  namespace: shop
spec:
  host: inventory
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        failover:
        - from: zone-a
          to: zone-b
    outlierDetection:
      consecutive5xxErrors: 5
      interval: 10s
      baseEjectionTime: 30s   # outlier detection is required for automatic failover to trigger
```

**Step by step:**

1. Confirm pods and nodes actually carry the standard `topology.kubernetes.io/zone` label — locality routing depends on it.
2. Enable `localityLbSetting` on the `DestinationRule`.
3. Configure `outlierDetection` alongside it — locality failover only activates when Istio has a way to detect that same-zone endpoints are unhealthy or unavailable.

### Validate After

```bash
for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders","nodeSelector":{"topology.kubernetes.io/zone":"zone-a"}}}' -- \
    curl -s http://inventory:8080/zone
done | sort | uniq -c
```

Expect the large majority of responses to now come from zone-A `inventory` pods. Confirm failover still works by scaling zone-A `inventory` to zero and re-running the same test — traffic should now correctly spill to zone B rather than failing outright:

```bash
kubectl scale deployment inventory-zone-a -n shop --replicas=0
# re-run the same batch — expect responses from zone-b this time, not errors
```

Strong zone-A preference under normal conditions, and clean failover when zone A is unavailable, together prove the locality configuration is working as intended.

---

## Problem 4: A Downstream Outage Triggers a Retry Storm That Makes Things Worse

**The problem.** `inventory` goes fully down during a bad deploy. `orders` has `retries.attempts: 3` configured from earlier. With every one of `orders`' many concurrent requests now retrying three times each, the retry traffic itself multiplies the load on an already-struggling `inventory`, and also floods the network layer, extending the outage well past when `inventory` actually recovers.

### Validate Before

Simulate the outage and watch what happens to actual request volume hitting `inventory`:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: inventory-outage-test
  namespace: shop
spec:
  hosts: [inventory]
  http:
  - fault:
      abort:
        percentage: {value: 100}
        httpStatus: 503
    route:
    - destination: {host: inventory}
```

```bash
kubectl apply -f inventory-outage-test.yaml

# generate concurrent load from orders
kubectl exec -n shop <orders-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep upstream_rq_total > before.txt

# ... run a burst of concurrent requests through orders ...

kubectl exec -n shop <orders-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_rq_total|upstream_rq_retry"
```

If `upstream_rq_retry` is running at roughly 3x `upstream_rq_total` for the outage window, that's the proof: every single failed call is unconditionally retried 3 times with no dampening, so a 100-request burst becomes roughly 400 requests hitting (or trying to hit) the already-down service.

### The Fix

Add a retry budget so the proportion of retries is capped relative to total traffic, preventing retries from amplifying load during a genuine widespread outage.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: inventory-retry-budget
  namespace: shop
spec:
  hosts: [inventory]
  http:
  - route:
    - destination: {host: inventory}
    retries:
      attempts: 3
      perTryTimeout: 1s
      retryOn: 5xx,reset,connect-failure
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: inventory-circuit-breaker
  namespace: shop
spec:
  host: inventory
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

**Step by step:**

1. Retries and circuit breaking must be configured together — retries alone, without a circuit breaker to eventually stop sending traffic to a fully-down backend, will amplify an outage rather than absorb transient blips.
2. Set `maxEjectionPercent: 100` for cases where the *entire* backend can legitimately go down — a lower cap would leave some traffic being sent (and retried) against a backend that's completely unavailable.
3. Remove the fault-injection test rule once validated.

### Validate After

Re-apply the same outage simulation and re-run the same burst:

```bash
kubectl apply -f inventory-outage-test.yaml
# ... run the same burst of concurrent requests ...

kubectl exec -n shop <orders-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_rq_total|upstream_rq_retry|outlier_detection.ejections_active"
```

Expect `upstream_rq_retry` to taper off once outlier detection ejects `inventory`'s endpoints (`ejections_active` > 0), rather than continuing to multiply indefinitely for the whole outage window. Fewer total requests attempted against a confirmed-down backend, with the ejection counter active, is the proof retries are now bounded rather than compounding the failure.

```bash
kubectl delete virtualservice inventory-outage-test -n shop
```

---

## Problem 5: A Cross-Cluster Failover Doesn't Actually Fail Over

**The problem.** `shop-east` is meant to fail over to `shop-west` if local `payment` pods become unavailable, using a multi-cluster setup with a shared `payment` service exposed via each cluster's east-west gateway. When `shop-east`'s `payment` pods all crash, `orders` in `shop-east` just returns errors instead of transparently using `shop-west`'s `payment` pods.

### Validate Before

```bash
kubectl get pods -n shop -l app=payment --context shop-east
# 0/3 — all payment pods down in shop-east

kubectl run client -n shop --context shop-east --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# 503 — no failover happening
```

Check whether `shop-east`'s proxies even know `shop-west`'s `payment` endpoints exist:

```bash
istioctl proxy-config endpoint <cart-pod>.shop --context shop-east | grep payment
```

If only `shop-east` IPs (all currently down) are listed, with nothing from `shop-west`, that's the proof — the two clusters were never actually joined into a single mesh view for this service; `shop-east` has no visibility into `shop-west`'s endpoints to fail over to.

### The Fix

Confirm cross-cluster service discovery is actually wired up (a shared root CA, an east-west gateway per cluster, and each cluster registered as a remote in the other's mesh config), and configure locality failover explicitly across clusters.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-cross-cluster-failover
  namespace: shop
spec:
  host: payment
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
    loadBalancer:
      localityLbSetting:
        enabled: true
        failover:
        - from: region-east
          to: region-west
```

**Step by step:**

1. Verify multi-cluster mesh setup first — `istioctl remote-clusters` should list both clusters as `Synced`, not just installed independently.
2. Confirm the east-west gateway in each cluster is actually exposing `payment` for cross-cluster access.
3. Apply the locality failover `DestinationRule`, identically, to both clusters.

### Validate After

```bash
istioctl proxy-config endpoint <cart-pod>.shop --context shop-east | grep payment
```

Expect `shop-west` endpoints to now appear in `shop-east`'s proxy configuration for `payment`, not just its own (currently down) local ones.

```bash
kubectl run client -n shop --context shop-east --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# Expect: 200, transparently served by shop-west
```

A successful response despite every local `payment` pod being down, combined with `shop-west` endpoints now visible in the proxy config, is the proof cross-cluster failover is genuinely wired up end-to-end.

---

# Domain 3: Installation, Upgrade & Configuration

## Problem 1: Two Teams' IstioOperator Overlays Silently Cancel Each Other Out

**The problem.** The platform team maintains a base `IstioOperator` manifest. The security team applies a second overlay to tighten `global.proxy` settings. Both are applied via `istioctl install -f`, one after the other, and the final live configuration doesn't match either file — because the second install fully replaced fields the first one set, rather than merging them as everyone assumed.

### Validate Before

```bash
istioctl install -f base-operator.yaml -y
istioctl install -f security-overlay.yaml -y
```

```bash
kubectl get istiooperator -n istio-system -o yaml | grep -A 20 "proxy:"
```

Compare that live output against both source files. If a setting from `base-operator.yaml` (say, `resources.requests.cpu`) is simply gone, replaced by whatever `security-overlay.yaml` did or didn't specify for that same field, that's the proof — `istioctl install -f` applies the given file as the new desired state; it does not deep-merge against whatever was applied before.

### The Fix

Use `istioctl manifest generate` with explicit multiple `-f` flags together (which *does* deep-merge), or maintain a single canonical `IstioOperator` file combining both teams' requirements, applied in one command.

```bash
istioctl install -f base-operator.yaml -f security-overlay.yaml -y
```

Or, to inspect exactly what the merged result will be before applying anything:

```bash
istioctl manifest generate -f base-operator.yaml -f security-overlay.yaml > merged-manifest.yaml
# review merged-manifest.yaml before applying
kubectl apply -f merged-manifest.yaml
```

**Step by step:**

1. Never apply multiple `IstioOperator` files as sequential, separate `istioctl install` calls expecting them to merge — each call sets the desired state fresh.
2. Pass every overlay file together in a single `-f -f` invocation, which merges them in order, later files overriding earlier ones field-by-field.
3. Always run `manifest generate` first to review the actual merged output before applying it to a live cluster.

### Validate After

```bash
istioctl install -f base-operator.yaml -f security-overlay.yaml -y

kubectl get istiooperator -n istio-system -o yaml | grep -A 20 "proxy:"
```

Confirm the live config now contains the combination of both files' settings — the base team's resource values *and* the security team's tightened settings, not one replacing the other.

```bash
diff <(istioctl manifest generate -f base-operator.yaml -f security-overlay.yaml) \
     <(kubectl get istiooperator -n istio-system -o yaml)
```

A merged result that includes fields from both source files, confirmed against the live cluster state, is the proof the overlays are now properly combined rather than overwriting each other.

---

## Problem 2: A Canary Revision Tag Points at the Wrong Control Plane After a Cleanup

**The problem.** ShopFast uses a revision tag `prod` that workloads reference via `istio.io/rev: prod`, so revision names can change underneath without relabeling every namespace. During a routine cleanup, an engineer deletes what looks like an old, unused `istiod` revision — but it was actually the one the `prod` tag pointed to. Every workload using the `prod` tag is now orphaned.

### Validate Before

```bash
istioctl tag list
```

```
TAG     REVISION      NAMESPACES
prod    1-22-3        shop, partners
```

```bash
kubectl get pods -n istio-system
```

```
istiod-1-22-3-xxxx    (about to be deleted — looks "old")
istiod-1-23-0-xxxx
```

Check proxy sync status before deleting anything:

```bash
istioctl proxy-status
```

```
NAME                    ISTIOD
cart-xxxx.shop          istiod-1-22-3-xxxx
payment-xxxx.shop       istiod-1-22-3-xxxx
```

Every production workload still points at `1-22-3` — the revision the `prod` tag resolves to — despite `1-23-0` existing alongside it. That's the proof: revision *number* looking old is not the same as revision *tag* being unused; the tag is what workloads actually reference.

### The Fix

Before deleting any `istiod` revision, always check `istioctl tag list` for what points at it, and re-point the tag to the new revision first if a migration is intended.

```bash
istioctl tag set prod --revision 1-23-0
```

Only then, once workloads have picked up the retagged control plane:

```bash
istioctl proxy-status   # confirm all workloads now show istiod-1-23-0-xxxx
istioctl x uninstall --revision 1-22-3
```

**Step by step:**

1. Never delete a revision without first checking `istioctl tag list` for tags pointing to it.
2. Move the tag to the new revision explicitly with `istioctl tag set`, and confirm via `proxy-status` that workloads have actually shifted before removing the old revision.
3. Treat "looks old" and "safe to delete" as two separate questions — only proxy-status output answers the second one.

### Validate After

```bash
istioctl tag list
```

```
TAG     REVISION      NAMESPACES
prod    1-23-0        shop, partners
```

```bash
istioctl proxy-status
```

Confirm every workload now shows the new `istiod-1-23-0-xxxx` as its control plane, before the old revision is removed. Only after that confirmation:

```bash
kubectl get pods -n istio-system
# Expect: istiod-1-22-3-xxxx safely gone, no workloads orphaned
```

Tag pointing at the new revision, every proxy synced to it, and the old revision removed only afterward — that sequence, confirmed at each step, is the proof nothing was orphaned.

---

## Problem 3: Pods Stay Stuck in `Init` Because of a CNI Mismatch

**The problem.** ShopFast switches from the sidecar injector's `istio-init` container approach to the Istio CNI plugin, to avoid needing `NET_ADMIN` capability on application pods. After the switch, new pods in `shop` get stuck in `Init:0/1` indefinitely.

### Validate Before

```bash
kubectl get pods -n shop
```

```
NAME                       READY   STATUS     RESTARTS
frontend-7d9f8c-x2k4p      0/2     Init:0/1   0
```

```bash
kubectl describe pod -n shop <frontend-pod> | grep -A 10 "Init Containers"
```

```
Init Containers:
  istio-validation:
    State:   Waiting
    Reason:  PodInitializing
```

Check whether the CNI plugin's own pods are actually healthy on the node scheduling this pod:

```bash
kubectl get pods -n kube-system -l k8s-app=istio-cni-node -o wide
```

```
istio-cni-node-abc12   0/1   CrashLoopBackOff   node-3
```

That's the proof — the application pod is stuck waiting on network setup that depends on the CNI daemonset, and the CNI pod on this specific node is crash-looping, so nothing is actually configuring the pod's traffic redirection.

```bash
kubectl logs -n kube-system istio-cni-node-abc12 --previous
```

### The Fix

Diagnose and fix the CNI daemonset issue directly — commonly a missing hostPath permission, an incompatible CNI binary version for the node's OS, or a conflicting CNI plugin already installed.

```bash
kubectl logs -n kube-system istio-cni-node-abc12 --previous | tail -30
```

```
error: failed to write CNI config: permission denied /etc/cni/net.d/
```

```yaml
# Fix: ensure the CNI daemonset has the correct hostPath volume and securityContext
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: istio-cni-node
  namespace: kube-system
spec:
  template:
    spec:
      containers:
      - name: install-cni
        securityContext:
          privileged: true
        volumeMounts:
        - name: cni-net-dir
          mountPath: /host/etc/cni/net.d
```

**Step by step:**

1. When pods are stuck in `Init`, check the CNI daemonset's own pod health on the same node before assuming it's an application-level problem.
2. Read the CNI pod's logs specifically — the failure is almost always there, not in the application pod's own events.
3. Fix the underlying permission or version issue, then delete the stuck application pods so they're rescheduled cleanly.

### Validate After

```bash
kubectl get pods -n kube-system -l k8s-app=istio-cni-node
# Expect: all Running, 1/1
```

```bash
kubectl delete pod -n shop <stuck-frontend-pod>
kubectl get pods -n shop -w
```

Expect the new pod to move through `Init` quickly and reach `2/2 Running`, rather than hanging. Confirm traffic redirection is actually in place:

```bash
kubectl exec -n shop <new-frontend-pod> -c istio-proxy -- iptables-save | grep ISTIO
```

Healthy CNI daemonset pods plus a new application pod reaching `2/2` with visible iptables redirection rules — that combination is the proof the CNI plugin is now functioning correctly.

---

## Problem 4: Overlapping Telemetry Resources Silently Turn Off Access Logs Mesh-Wide

**The problem.** The observability team adds a namespace-scoped `Telemetry` resource in `shop` to customize `payment`'s access log format. Months later, someone notices `cart` and `orders` have had no access logs at all since that change — even though nobody intentionally disabled logging for them.

### Validate Before

```bash
kubectl get telemetry -A
```

```
NAMESPACE   NAME              
istio-system default          
shop        payment-logging   
```

```bash
kubectl get telemetry payment-logging -n shop -o yaml
```

```yaml
spec:
  selector:
    matchLabels:
      app: payment
  accessLogging:
  - providers:
    - name: envoy
```

That looks scoped to `payment` only via the selector — but check the mesh-wide default it's layered on top of:

```bash
kubectl get telemetry default -n istio-system -o yaml
```

```yaml
spec:
  accessLogging:
  - disabled: true
```

The proof is the interaction: the mesh-wide `default` `Telemetry` disables access logging for everyone, and `payment-logging` only re-enables it for `payment` specifically via its selector. `cart` and `orders` were never individually re-enabled, so they've been silently logging nothing since the mesh-wide default was set — a change likely made for an unrelated reason and never fully understood.

### The Fix

Decide the intended default deliberately, then apply workload-level overrides explicitly for every workload that needs to differ from it — don't leave any workload relying on an assumption about what the mesh-wide default does.

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: default
  namespace: istio-system
spec:
  accessLogging:
  - providers:
    - name: envoy   # re-enable mesh-wide by default
```

Keep `payment`'s override only if it genuinely needs a different format from everyone else:

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: payment-logging
  namespace: shop
spec:
  selector:
    matchLabels:
      app: payment
  accessLogging:
  - providers:
    - name: envoy
    filter:
      expression: "response.code >= 400"   # payment only logs errors, by design
```

**Step by step:**

1. Always check the mesh-wide `Telemetry` resource in `istio-system` before assuming a namespace or workload-level one is self-contained — they compose, they don't replace.
2. Restore the intended mesh-wide default deliberately.
3. Re-verify every workload's actual logging behavior individually rather than assuming a fix at one scope fixed everything.

### Validate After

```bash
kubectl logs -n shop <cart-pod> -c istio-proxy --tail=5
```

Expect fresh access log lines to appear again for `cart`, where before there were none.

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s http://orders:8080 > /dev/null

kubectl logs -n shop <orders-pod> -c istio-proxy --tail=5
```

A new log line corresponding to that exact request is the proof `orders` logging is restored. Confirm `payment` still uses its intended error-only filter and hasn't been accidentally reverted:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s http://payment:8080/healthz > /dev/null   # a 200, not an error

kubectl logs -n shop <payment-pod> -c istio-proxy --tail=5
```

No new line for that successful health check, while `cart` and `orders` log everything, confirms each scope is now behaving exactly as intended rather than by accident.

---

## Problem 5: A Sidecar-to-Ambient Migration Leaves Some Pods Double-Enrolled

**The problem.** ShopFast starts migrating from sidecar mode to ambient mode (ztunnel) for lower resource overhead. During the transition, the `shop` namespace is labeled for ambient (`istio.io/dataplane-mode: ambient`), but some pods still carry sidecar injection labels from before, leaving them enrolled in both — with both a sidecar and ztunnel trying to manage the same pod's traffic.

### Validate Before

```bash
kubectl get namespace shop --show-labels
```

```
istio.io/dataplane-mode=ambient,istio-injection=enabled
```

Both labels present is the first red flag. Confirm the actual effect on a pod:

```bash
kubectl get pod -n shop <cart-pod> -o jsonpath='{.spec.containers[*].name}'
```

```
cart istio-proxy
```

A sidecar container is present despite the namespace being labeled for ambient — the proof that this pod's traffic handling is ambiguous, potentially double-processed by both the sidecar and ztunnel depending on how the two modes negotiate on this node.

```bash
kubectl exec -n shop <cart-pod> -c istio-proxy -- curl -s localhost:15000/stats | grep -i ztunnel
```

Any ztunnel-related stats appearing inside a pod that also has a full sidecar is confirmation of the double-enrollment.

### The Fix

Remove the conflicting sidecar-injection label so the namespace unambiguously uses ambient mode, then restart affected pods so they're re-created without a sidecar and picked up cleanly by ztunnel instead.

```bash
kubectl label namespace shop istio-injection- --overwrite
kubectl label namespace shop istio.io/dataplane-mode=ambient --overwrite
```

**Step by step:**

1. Never label a namespace for both sidecar injection and ambient mode simultaneously — pick one per namespace as the migration boundary.
2. Remove the old label explicitly; simply adding the new one doesn't clear the old one.
3. Restart every pod in the namespace so none of them carry a stale sidecar from before the label change.

```bash
kubectl rollout restart deployment -n shop --all
```

### Validate After

```bash
kubectl get pod -n shop <new-cart-pod> -o jsonpath='{.spec.containers[*].name}'
```

Expect just `cart` — no `istio-proxy` container at all, confirming the pod is now purely ambient-managed.

```bash
kubectl get namespace shop --show-labels
```

```
istio.io/dataplane-mode=ambient
```

Only the ambient label remains. Confirm traffic still flows correctly under ztunnel:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080
# Expect: 200
```

A pod with no sidecar container, a namespace with only one dataplane-mode label, and working traffic — together, the proof the migration is clean rather than double-enrolled.

---

# Domain 4: Troubleshooting

## Problem 1: Two Teams' VirtualServices on the Same Host Produce Nondeterministic Routing

**The problem.** The `orders` team and the `platform` team both independently create a `VirtualService` for the `orders` host — one for canary routing, one for a maintenance-mode redirect — in different Kubernetes namespaces. Requests to `orders` behave inconsistently, sometimes following one team's rules, sometimes the other's, with no clear pattern.

### Validate Before

```bash
kubectl get virtualservice -A -o json | jq -r '.items[] | select(.spec.hosts[]? == "orders.shop.svc.cluster.local") | "\(.metadata.namespace)/\(.metadata.name)"'
```

```
shop/orders-canary
platform/orders-maintenance
```

Two `VirtualService` objects claiming the same host from different namespaces is the proof of the conflict itself. Confirm Istio's own analyzer flags it:

```bash
istioctl analyze -A
```

```
Warning [IST0132] Conflict detected: multiple VirtualServices target host "orders" with overlapping match conditions
```

Check which one is actually winning at any given moment — this is where it gets nondeterministic:

```bash
istioctl proxy-config routes <frontend-pod>.shop --name http.8080 -o json | grep -A 5 orders
```

Repeating this command over time, or after any unrelated config push, can show a different one of the two `VirtualService` objects in effect — because when multiple `VirtualService` resources target the same host, Istio's behavior for reconciling them is not a reliable, documented precedence order; it depends on internal config processing that can change between pushes.

### The Fix

Consolidate ownership: only one `VirtualService` per host should exist across the entire mesh, typically owned by the team responsible for that service.

```yaml
# Single VirtualService, owned by the orders team, incorporating both needs
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: orders
  namespace: shop
spec:
  hosts: [orders]
  http:
  - match:
    - headers:
        x-maintenance-mode:
          exact: "true"
    route:
    - destination: {host: orders, subset: maintenance}
  - route:
    - destination: {host: orders, subset: v1}
      weight: 90
    - destination: {host: orders, subset: v2}
      weight: 10
```

```bash
kubectl delete virtualservice orders-maintenance -n platform
```

**Step by step:**

1. Run `istioctl analyze -A` mesh-wide periodically, not just per-namespace — cross-namespace host conflicts are easy to miss otherwise.
2. Establish a clear ownership convention: one `VirtualService` per host, and route all routing requirements for that host through its owning team.
3. Merge competing requirements into the single, owned resource rather than letting multiple teams each maintain their own.

### Validate After

```bash
kubectl get virtualservice -A -o json | jq -r '.items[] | select(.spec.hosts[]? == "orders.shop.svc.cluster.local") | "\(.metadata.namespace)/\(.metadata.name)"'
```

```
shop/orders
```

Exactly one result. Confirm the analyzer is clean:

```bash
istioctl analyze -A
# ✔ No validation issues found
```

Repeat the route inspection several times, including after an unrelated config change elsewhere in the mesh, to confirm the routing decision no longer shifts:

```bash
istioctl proxy-config routes <frontend-pod>.shop --name http.8080 -o json | grep -A 5 orders
```

Consistent output across repeated checks, with a clean analyzer result and a single owning resource, is the proof the nondeterminism is gone.

---

## Problem 2: A ServiceEntry Keeps Routing to an IP the Partner Retired Weeks Ago

**The problem.** ShopFast calls a partner's API through a `ServiceEntry` with `resolution: DNS`. The partner rotates their infrastructure and updates DNS, but ShopFast's calls keep intermittently hitting the old, now-dead IP for days afterward, causing sporadic timeouts that don't correlate with any change ShopFast made.

### Validate Before

```bash
dig +short partner-api.example.com
```

```
203.0.113.50
```

Check what Envoy actually has cached for that host:

```bash
istioctl proxy-config endpoint <payment-pod>.shop --cluster "outbound|443||partner-api.example.com"
```

```
203.0.113.10:443   HEALTHY   (the old, retired IP)
```

A mismatch between what `dig` resolves right now and what Envoy's endpoint table actually holds is the proof — Envoy cached the DNS resolution and isn't re-resolving it on the schedule ShopFast assumed.

```bash
kubectl get serviceentry partner-api -n shop -o yaml | grep -A 5 resolution
```

```yaml
resolution: DNS
# no explicit refresh interval — relying on the default
```

### The Fix

Set an explicit, shorter DNS refresh interval appropriate for a partner known to rotate infrastructure, rather than relying on the default refresh cadence.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: partner-api
  namespace: shop
spec:
  hosts:
  - partner-api.example.com
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
---
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: partner-api-dns-refresh
  namespace: shop
spec:
  host: partner-api.example.com
  trafficPolicy:
    connectionPool:
      tcp:
        connectTimeout: 5s
```

The refresh interval itself is a mesh-wide setting; apply it via `IstioOperator` if the default is too slow for volatile hosts across the mesh:

```yaml
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata:
        DNS_AUTO_ALLOCATE: "false"
```

More directly, confirm the sidecar's DNS proxying (`istio-agent` DNS capture) has an appropriate TTL awareness, and as a more immediate remedy, force a resync:

```bash
kubectl rollout restart deployment payment -n shop
```

**Step by step:**

1. Confirm Envoy's actual cached endpoint against a fresh `dig` lookup whenever intermittent failures correlate with a known external change.
2. Restart affected pods to force an immediate re-resolution as a short-term fix.
3. For any partner or external host known to rotate IPs, plan for a deliberately short DNS TTL and refresh cadence rather than accepting the default.

### Validate After

```bash
kubectl rollout restart deployment payment -n shop

istioctl proxy-config endpoint <new-payment-pod>.shop --cluster "outbound|443||partner-api.example.com"
```

```
203.0.113.50:443   HEALTHY
```

Envoy's endpoint table now matches the current `dig` result. Confirm calls succeed consistently, not intermittently:

```bash
for i in $(seq 1 10); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"payment"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" https://partner-api.example.com
done | sort | uniq -c
```

All ten succeeding, matched against Envoy's endpoint list agreeing with live DNS, is the proof the stale-cache issue is resolved.

---

## Problem 3: p99 Latency Is High but Every Individual Service Reports Fast Response Times

**The problem.** Customers report slow checkouts. Every service's own dashboards show healthy, fast response times individually — `orders`, `inventory`, and `payment` all report sub-100ms p99 on their own metrics — yet the end-to-end checkout latency customers experience is frequently over 2 seconds.

### Validate Before

Since individual service metrics look fine, check where time is actually being spent at the connection layer rather than the application layer:

```bash
kubectl exec -n shop <orders-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep -E "upstream_cx_overflow|upstream_rq_pending_overflow|upstream_cx_connect_timeout"
```

```
cluster.outbound|8080||inventory.shop.svc.cluster.local.upstream_rq_pending_overflow: 1204
```

A large, climbing `upstream_rq_pending_overflow` counter is the proof: requests from `orders` to `inventory` are queueing up waiting for an available connection in the pool, and that queueing time never shows up in `inventory`'s own server-side latency metrics — `inventory` only starts its clock once it actually receives the request, not while it's queued upstream.

Confirm with the access log timing breakdown, not just the status code:

```bash
kubectl logs -n shop <orders-pod> -c istio-proxy --since=5m | grep inventory | tail -5
```

Look at the duration field in the log line — a multi-second total duration despite `inventory` itself responding quickly once it receives the request confirms the delay is in the queue, not the service.

### The Fix

Increase the connection pool size on the `DestinationRule` for `inventory`, sized to actual concurrent demand from `orders`, rather than leaving it at a restrictive default.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: inventory-pool-sizing
  namespace: shop
spec:
  host: inventory
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 100
        http2MaxRequests: 1000
```

**Step by step:**

1. When end-to-end latency is high but every individual service reports fast responses, suspect queueing time between services — it's invisible to server-side metrics by definition.
2. Check `upstream_rq_pending_overflow` and similar Envoy stats on the calling service's sidecar, not the receiving service's.
3. Size the connection pool to real concurrent traffic, then confirm with a load test rather than a single request.

### Validate After

```bash
kubectl exec -n shop <orders-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep upstream_rq_pending_overflow
```

Expect the counter to stop climbing under the same load pattern that previously triggered it. Measure actual end-to-end latency under load:

```bash
for i in $(seq 1 50); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
    curl -s -o /dev/null -w "%{time_total}\n" http://orders:8080/checkout &
done; wait
```

A tight, low distribution of total times across the batch — instead of the earlier multi-second outliers — combined with a flat overflow counter, is the proof the pool sizing fixed the actual bottleneck.

---

## Problem 4: Certificate Handshakes Fail Intermittently, Only on One Node

**The problem.** mTLS handshakes between `cart` and `payment` fail intermittently — not consistently like a trust domain mismatch, and not for every pod, only for pods that happen to be scheduled on one specific node. The same certificates work fine everywhere else.

### Validate Before

```bash
kubectl get pods -n shop -o wide | grep payment
```

Identify which node the failing pod is on, then check that node's clock:

```bash
kubectl debug node/<suspect-node> -it --image=busybox -- date
```

```
Thu Sep 25 14:02:07 UTC 2026
```

Compare against the actual current time and against another node:

```bash
kubectl debug node/<healthy-node> -it --image=busybox -- date
```

If the suspect node's clock is meaningfully behind or ahead (even by a minute or two), that's the proof: TLS certificate validation checks `notBefore`/`notAfter` against the local system clock, and short-lived Istio workload certificates (often valid for as little as 24 hours, rotated frequently) leave very little tolerance for clock skew before validation starts failing intermittently, right at the edges of the cert's validity window.

Confirm the specific handshake error:

```bash
kubectl logs -n shop <payment-pod-on-suspect-node> -c istio-proxy --since=10m | grep -i "certificate\|expired\|not yet valid"
```

### The Fix

Fix the node's NTP synchronization — this is an infrastructure issue, not an Istio configuration issue, though its symptoms show up entirely inside Istio's mTLS layer.

```bash
kubectl debug node/<suspect-node> -it --image=busybox --profile=sysadmin -- \
  chroot /host systemctl status systemd-timesyncd
```

```
inactive (dead)
```

```bash
kubectl debug node/<suspect-node> -it --image=busybox --profile=sysadmin -- \
  chroot /host systemctl restart systemd-timesyncd
```

**Step by step:**

1. When mTLS failures correlate with node scheduling rather than any Istio configuration, suspect infrastructure — specifically clock sync — before touching any Istio resource.
2. Confirm the node's actual clock against a reliable reference, not just against another node that could itself be wrong.
3. Fix NTP at the node level, and consider adding node-level monitoring for clock drift going forward so this doesn't require app-layer symptoms to surface it again.

### Validate After

```bash
kubectl debug node/<suspect-node> -it --image=busybox -- date
```

Confirm the node's clock now matches accurate time. Re-run repeated handshake tests specifically against pods on that node:

```bash
for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart","nodeSelector":{"kubernetes.io/hostname":"<suspect-node>"}}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
done | sort | uniq -c
```

Expect all `200`s this time, with zero intermittent handshake failures. Confirm no fresh certificate errors appear in the sidecar logs on that node:

```bash
kubectl logs -n shop <payment-pod-on-suspect-node> -c istio-proxy --since=5m | grep -i "certificate\|expired"
# Expect: no output
```

A synced clock plus a clean run of repeated requests specifically targeted at the previously-affected node is the proof the intermittent failures are gone.

---

## Problem 5: Two Replicas of the Same Service Enforce Different Authorization Rules Under Load

**The problem.** `payment` runs 3 replicas. Under heavy load during a flash sale, some requests from `cart` succeed and some get `403`s — for the exact same request pattern, same caller, same policy. The inconsistency correlates with which specific `payment` pod handles the request.

### Validate Before

```bash
for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
done | sort | uniq -c
```

```
     22 200
      8 403
```

A mix of results for what should be a uniformly-allowed request is the proof of inconsistent enforcement. Check whether all three `payment` replicas actually agree on the current policy:

```bash
for pod in $(kubectl get pods -n shop -l app=payment -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $pod ==="
  istioctl proxy-status | grep $pod
done
```

```
=== payment-abc12 ===
payment-abc12.shop   SYNCED   istiod-xxxx
=== payment-def34 ===
payment-def34.shop   STALE    istiod-xxxx
=== payment-ghi56 ===
payment-ghi56.shop   SYNCED   istiod-xxxx
```

One replica reporting `STALE` while its siblings are `SYNCED` is the proof — that single pod is still enforcing an older version of the `AuthorizationPolicy` (perhaps one that was recently loosened), while its siblings correctly enforce the current rule, producing exactly the kind of pod-dependent inconsistency being observed.

### The Fix

Restart the stale replica specifically to force a fresh sync, and if this recurs across the fleet under load, investigate whether `istiod` itself is under-provisioned for the config push volume during traffic spikes.

```bash
kubectl delete pod -n shop payment-def34
```

For the underlying capacity issue, if this pattern repeats during every high-traffic event:

```bash
kubectl get hpa -n istio-system istiod
kubectl top pod -n istio-system -l app=istiod
```

Scale `istiod` proactively ahead of known high-traffic windows if it's consistently under-resourced during config-push-heavy periods:

```bash
kubectl scale deployment istiod -n istio-system --replicas=3
```

**Step by step:**

1. When identical requests get inconsistent results across replicas of the same service, check `istioctl proxy-status` per-pod before suspecting the policy itself is wrong.
2. Restart any replica reporting `STALE` to force resync immediately.
3. If staleness correlates with traffic spikes, treat it as an `istiod` capacity problem and scale the control plane ahead of known peak events, not just react after each incident.

### Validate After

```bash
kubectl delete pod -n shop payment-def34
# wait for the new pod to come up

istioctl proxy-status | grep payment
```

```
payment-abc12.shop   SYNCED   istiod-xxxx
payment-jkl78.shop   SYNCED   istiod-xxxx   (replacement pod)
payment-ghi56.shop   SYNCED   istiod-xxxx
```

All three replicas now `SYNCED`. Re-run the same batch of 30 identical requests:

```bash
for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
done | sort | uniq -c
```

```
     30 200
```

Uniform results across every replica this time, matched against uniform `SYNCED` status, is the proof the inconsistency was purely a config-sync gap and is now resolved.

---

# Combined Checklist

| Domain | Problem | Core Diagnostic Tool | Key Proof of Fix |
|---|---|---|---|
| Security | mTLS policy precedence conflict | `istioctl x describe pod` | Effective mode matches intended scope, exception limited to `portLevelMtls` |
| Security | DENY/ALLOW evaluation order | `istioctl analyze` reasoning | Exception carved into DENY rule, not a separate ALLOW |
| Security | Missing outbound TLS origination | `tcpdump` on sidecar | Encrypted bytes on wire; `tlsContext` present in cluster config |
| Security | Multi-tenant JWT scoping | Cross-tenant token replay test | Cross-tenant blocked, same-tenant allowed |
| Security | Cross-cluster trust domain mismatch | `proxy-config secret` on both clusters | Matching root trust; successful cross-cluster handshake |
| Traffic Mgmt | Session affinity for A/B testing | Repeated requests with same cookie | Consistent variant per session |
| Traffic Mgmt | Oversized circuit breaking | `upstream_cx_overflow` stat | Flat overflow counters under real load |
| Traffic Mgmt | Missing locality awareness | Zone-tagged request distribution | Strong same-zone preference, clean failover |
| Traffic Mgmt | Retry storm amplification | `upstream_rq_retry` vs `upstream_rq_total` | Retries bounded, ejection active during outage |
| Traffic Mgmt | Broken cross-cluster failover | `proxy-config endpoint` cross-cluster | Remote endpoints visible; failover succeeds |
| Install/Config | Non-merging IstioOperator overlays | `manifest generate` diff | Merged config contains both files' settings |
| Install/Config | Revision tag pointing at deleted revision | `istioctl tag list` + `proxy-status` | Tag repointed, all proxies synced before old revision removed |
| Install/Config | CNI daemonset failure | CNI pod logs on the node | CNI pods healthy; new pods reach `2/2` |
| Install/Config | Overlapping Telemetry scopes | Compare mesh-wide vs. namespace `Telemetry` | Each scope logs exactly as intended |
| Install/Config | Sidecar/ambient double-enrollment | Container list on pod | No sidecar container; single dataplane-mode label |
| Troubleshooting | Conflicting VirtualServices on one host | `istioctl analyze -A` | Single owning resource; consistent route output |
| Troubleshooting | Stale ServiceEntry DNS cache | `proxy-config endpoint` vs `dig` | Envoy endpoint matches live DNS |
| Troubleshooting | Hidden queueing latency | `upstream_rq_pending_overflow` | Flat overflow counter; tight latency distribution |
| Troubleshooting | Node clock skew breaking mTLS | Node `date` vs cert validity | Synced clock; clean handshakes on that node |
| Troubleshooting | Per-replica config drift under load | `proxy-status` per pod | All replicas `SYNCED`; uniform request results |

## Exam Angle

These twenty scenarios lean into what actually trips people up on the ICA exam and in real incidents: **precedence and evaluation order** (mTLS scope levels, DENY-before-ALLOW), **composition rather than replacement** (Telemetry layering, IstioOperator merging, retries plus circuit breaking), and **the gap between what a dashboard shows and what's actually happening on the wire** (queueing latency invisible to server-side metrics, stale DNS caches, per-replica config drift). When a question describes something that "should obviously work" but doesn't, look for one of these three patterns first.

## Try It Yourself

Pick one problem from each domain and reproduce it on the ShopFast cluster before reading its fix. The diagnostic habit — check `istioctl proxy-status`, `proxy-config`, and Envoy's own stats before touching any YAML — is what separates guessing from actually finding root cause, on the exam and in a real incident alike.
