# Securing Istio in Production: Five Real Problems, Five Real Fixes

Security in a service mesh is easy to talk about and easy to get wrong. Most teams install Istio, enable the sidecars, and assume they're protected. This post walks through a realistic scenario and five security problems that show up in almost every production cluster — with a way to **prove the problem exists**, the **fix**, and a way to **prove the fix worked**.

## The Scenario: ShopFast

ShopFast is an e-commerce company running on Kubernetes. Its checkout flow spans five services in a `shop` namespace:

| Service | Responsibility |
|---|---|
| `frontend` | Customer-facing web app |
| `cart` | Holds the customer's basket |
| `orders` | Creates and tracks orders |
| `payment` | Charges cards through an external provider |
| `inventory` | Tracks stock levels |

Istio is installed, and every pod has a sidecar. Let's find out what's actually secure.

---

## Problem 1: Traffic Between Services Is Unencrypted

**The problem.** A security audit claims that service-to-service traffic inside the cluster is plaintext. Anyone who compromises a node, or a pod with packet-capture capability, can read card-related requests going to `payment`.

### Validate Before: Prove the Traffic Is Plaintext

Don't take the audit's word for it — capture the traffic yourself.

```bash
# Find the payment pod
kubectl get pod -n shop -l app=payment

# Capture traffic on the sidecar's inbound port (15006) while a request is in flight
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  timeout 10 tcpdump -i any -A -s 0 port 8080
```

In another terminal, send a request:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s http://payment:8080/api/v1/charge -X POST -d '{"card":"4111111111111111"}'
```

If mTLS is off, the `tcpdump` output shows the raw HTTP body — including the card number — in plain text. That's your proof.

You can also check the mTLS status mesh-wide with `istioctl`:

```bash
istioctl x describe pod <payment-pod> -n shop
```

Look for the line reporting the traffic policy — `PERMISSIVE` or absent means the audit is right.

### The Fix

Enable mutual TLS. Istio issues each workload a certificate and encrypts traffic in both directions. Start with a permissive mode so nothing breaks during rollout, then enforce strict mode.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: shop
spec:
  mtls:
    mode: STRICT
```

**Step by step:**

1. Set `mode: PERMISSIVE` first, which accepts both plaintext and mTLS.
2. Check which workloads still send plaintext. Kiali shows lock icons, and `istioctl analyze` catches configuration problems.
3. Fix any legacy clients or health-check probes that aren't yet in the mesh.
4. Switch to `STRICT` and confirm that traffic still flows.

### Validate After: Prove the Traffic Is Now Encrypted

Repeat the exact same `tcpdump` capture:

```bash
kubectl exec -n shop <payment-pod> -c istio-proxy -- \
  timeout 10 tcpdump -i any -A -s 0 port 8080
```

Send the same request again. This time the payload should appear as encrypted bytes, not readable text — no `4111111111111111`, no JSON structure visible.

Confirm the policy is active and enforced:

```bash
istioctl x describe pod <payment-pod> -n shop
# Expect: "STRICT" mTLS mode reported for the workload

kubectl get peerauthentication -n shop
```

As a negative test, try connecting without mTLS from a pod outside the mesh (no sidecar):

```bash
kubectl run plain-client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"containers":[{"name":"curl","image":"curlimages/curl","command":["sleep","3600"]}]}}' -- sh
# then inside: curl -v http://payment:8080
```

This should fail or be rejected — proof that STRICT mode is actually being enforced, not just configured.

---

## Problem 2: Any Service Can Call Any Other Service

**The problem.** The `inventory` service should only be called by `orders`, but right now the `frontend` can call it directly. A compromised frontend could change stock levels or reach the payment API.

### Validate Before: Prove the Over-Permissive Access

From the `frontend` service account, call `inventory` and `payment` directly — services it has no business talking to:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080

kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
```

A `200` on either call is the proof: nothing is stopping `frontend` from reaching services it shouldn't.

### The Fix

Istio's authorization model is deny-by-default once you apply an `AuthorizationPolicy` that has no rules. Start by denying everything in the namespace, then allow only the specific callers you want.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: shop
spec: {}
```

Then grant explicit permissions. Here, only the `cart` service identity may call `payment`, and only for charge requests:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: payment-allow-cart
  namespace: shop
spec:
  selector:
    matchLabels:
      app: payment
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shop/sa/cart"]
    to:
    - operation:
        methods: ["POST"]
        paths: ["/api/v1/charge"]
```

**Key point:** Identity here comes from the workload's service account, carried in the mTLS certificate. That's why Problem 1 must be solved first. Without mTLS, principals can't be trusted.

### Validate After: Prove Access Is Now Restricted

Re-run the exact same calls from `frontend`:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080
# Expect: 403

kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# Expect: 403
```

Now prove the legitimate path still works — `cart` calling `payment`:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# Expect: 200
```

You want to see three things: the wrong caller blocked, the right caller allowed, and the block visible in logs:

```bash
kubectl logs -n shop <payment-pod> -c istio-proxy | grep RBAC
```

---

## Problem 3: Customers Can Access Other Customers' Orders

**The problem.** The `orders` API trusts whatever user ID appears in the request. A customer changes the ID in the URL and reads someone else's order history.

### Validate Before: Prove Requests Work Without Any Token

Call `orders` with no `Authorization` header at all:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/api/v1/orders/12345
```

A `200` here is the proof — the mesh isn't checking who's asking, so anyone can request any order ID.

### The Fix

Validate the user's identity at the mesh layer using JWTs. Note that `RequestAuthentication` only validates tokens when they're present. It does not reject requests without one, so you need an `AuthorizationPolicy` to enforce that.

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: orders-jwt
  namespace: shop
spec:
  selector:
    matchLabels:
      app: orders
  jwtRules:
  - issuer: "https://auth.shopfast.example.com"
    jwksUri: "https://auth.shopfast.example.com/.well-known/jwks.json"
    forwardOriginalToken: true
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: orders-require-jwt
  namespace: shop
spec:
  selector:
    matchLabels:
      app: orders
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://auth.shopfast.example.com/*"]
```

**Step by step:**

1. Apply `RequestAuthentication` so invalid tokens are rejected.
2. Apply the `AuthorizationPolicy` so requests without a valid token are denied.
3. Note that the mesh verifies who the caller is, but the application must still verify that the user owns the order. Mesh-level checks are a strong first layer, not a replacement for authorization logic in code.

### Validate After: Prove Tokens Are Now Required

Repeat the no-token call:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/api/v1/orders/12345
# Expect: 403
```

Try a request with a garbage token, to prove validation — not just presence-checking — is happening:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer not-a-real-token" \
  http://orders:8080/api/v1/orders/12345
# Expect: 401
```

Finally, use a valid token issued by your test issuer:

```bash
TOKEN=$(<generate or fetch a valid JWT from your test issuer>)

kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  http://orders:8080/api/v1/orders/12345
# Expect: 200
```

Three outcomes prove the fix: no token → 403, bad token → 401, good token → 200.

---

## Problem 4: A Compromised Service Exfiltrates Data to the Internet

**The problem.** An attacker who gets into the `inventory` pod can send data to any external host. By default, Istio lets sidecars reach any destination.

### Validate Before: Prove Unrestricted Egress

From inside the mesh, try reaching an arbitrary external host that has nothing to do with ShopFast:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://example.com
```

A `200` proves the sidecar will happily forward traffic to any destination on the internet — exactly what a data-exfiltration attempt would use.

### The Fix

Restrict outbound traffic to a registry of approved destinations. Set the mesh's outbound policy to `REGISTRY_ONLY`, then explicitly declare the external hosts that services legitimately need with a `ServiceEntry`.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: stripe-api
  namespace: shop
spec:
  hosts:
  - api.stripe.com
  ports:
  - number: 443
    name: https
    protocol: TLS
  resolution: DNS
  location: MESH_EXTERNAL
```

Set `outboundTrafficPolicy.mode: REGISTRY_ONLY` in the mesh config:

```bash
istioctl install --set profile=demo \
  --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
```

### Validate After: Prove Egress Is Now Restricted

Repeat the call to the unrelated external host:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://example.com
# Expect: connection blocked / 502 from the sidecar
```

Then prove the *approved* destination still works:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" https://api.stripe.com
# Expect: a response (not blocked), since it's in the ServiceEntry registry
```

Check the sidecar logs to see the block recorded explicitly:

```bash
kubectl logs -n shop <inventory-pod> -c istio-proxy | grep -i "blackhole\|BlockAll"
```

Two outcomes prove the fix: the registered host reachable, everything else blocked.

---

## Problem 5: Requests Are Failing and Nobody Knows Why

**The problem.** After tightening policies, a checkout request returns `403`, and the team cannot tell whether it's a policy, a certificate, or an application bug.

### Validate Before: Reproduce the Failure on Demand

Before debugging anything, make the failure reproducible. Apply a deliberately broken policy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: broken-cart-policy
  namespace: shop
spec:
  selector:
    matchLabels: {app: cart}
  action: DENY
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shop/sa/frontend"]
```

Confirm the failure:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080
# Expect: 403
```

### The Fix (a Debugging Process, Not a Manifest)

1. **Read the Envoy logs.** Denied requests show `RBAC: access denied` with the response flag `-`, which points to an authorization policy rather than an application error.

   ```bash
   kubectl logs -n shop <cart-pod> -c istio-proxy | grep RBAC
   ```

2. **Check which policies apply.**

   ```bash
   istioctl x authz check <cart-pod>.shop
   ```

3. **Remember the evaluation order.** Istio evaluates `CUSTOM` first, then `DENY`, then `ALLOW`. A single matching `DENY` overrides any `ALLOW`, which is a common source of confusion.

4. **Test one change at a time.** Roll out policy fixes incrementally, and keep a rollback manifest ready.

Once you identify `broken-cart-policy` as the culprit, remove or correct it:

```bash
kubectl delete authorizationpolicy broken-cart-policy -n shop
```

### Validate After: Prove the Diagnosis Was Correct

Re-run the same request:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080
# Expect: 200 (or whatever access level is intended for frontend -> cart)
```

Confirm the RBAC denial no longer appears in fresh logs:

```bash
kubectl logs -n shop <cart-pod> -c istio-proxy --since=1m | grep RBAC
# Expect: no output
```

Re-run `istioctl x authz check` and confirm the broken policy is gone from the list of applied policies:

```bash
istioctl x authz check <cart-pod>.shop
```

The debugging loop is only complete when you can show the exact failing request, the exact policy that caused it, and the exact request succeeding after the fix.

---

## Security Checklist

| Layer | Control | Resource | Validate Before | Validate After |
|---|---|---|---|---|
| Transport | Encrypt all service traffic | `PeerAuthentication` (STRICT) | `tcpdump` shows plaintext | `tcpdump` shows encrypted bytes; plaintext client rejected |
| Service access | Deny by default, allow by identity | `AuthorizationPolicy` | Unrelated service calls succeed | Unrelated calls → 403; legitimate calls → 200 |
| End-user identity | Validate JWTs at the mesh | `RequestAuthentication` + `AuthorizationPolicy` | No-token request succeeds | No token → 403; bad token → 401; valid token → 200 |
| Egress | Allow only known external hosts | `ServiceEntry` + `REGISTRY_ONLY` | Arbitrary external host reachable | Unregistered host blocked; registered host reachable |
| Operations | Diagnose denials quickly | Envoy logs, `istioctl` | Reproduce the 403 on demand | RBAC denial gone from logs; request succeeds |

## Exam Angle

If you're preparing for the Istio Certified Associate (ICA) exam, focus on three things: how `PeerAuthentication` modes interact, why `RequestAuthentication` alone doesn't enforce authentication, and how the CUSTOM → DENY → ALLOW evaluation order works. Those three concepts show up repeatedly in security questions — and the validate-before / validate-after habit above is exactly the kind of hands-on evidence that makes those concepts stick.

## Try It Yourself

Build this scenario in a kind or minikube cluster with the Istio demo profile. Deploy the five services, and for each quest: run the "before" validation, apply the fix, then run the "after" validation. Don't skip the before step — seeing the actual proof of a vulnerability is what makes the fix meaningful.
