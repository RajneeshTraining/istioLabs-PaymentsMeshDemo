# Troubleshooting in Production: Five Real Problems, Five Real Fixes

Security, traffic management, and installation all eventually produce the same moment: something is broken, the dashboard shows red, and you have to find out why before customers notice. This post continues the ShopFast scenario and walks through five troubleshooting problems that show up constantly in real clusters, each with a way to **prove the problem exists**, the **fix**, and a way to **prove the fix worked**.

## The Scenario: ShopFast (Recap)

Same five services, same `shop` namespace:

| Service | Responsibility |
|---|---|
| `frontend` | Customer-facing web app |
| `cart` | Holds the customer's basket |
| `orders` | Creates and tracks orders |
| `payment` | Charges cards through an external provider |
| `inventory` | Tracks stock levels |

This time, ShopFast also has an `istio-ingressgateway` fronting `frontend`, and a rolling deployment of `inventory` is in progress. Both become sources of real incidents.

---

## Problem 1: A Sidecar Stops Receiving Configuration Updates

**The problem.** An engineer updates the `AuthorizationPolicy` on `payment`, applies it, and confirms it with `kubectl get`. But `cart` still gets `403`s hours later even after the policy is loosened — because `payment`'s sidecar has silently stopped syncing with `istiod` and is running on stale configuration.

### Validate Before: Prove the Proxy Is Out of Sync

```bash
istioctl proxy-status
```

```
NAME                             CDS        LDS        EDS        RDS        ISTIOD
payment-6d8f9c-x2k4p.shop        STALE      STALE      SYNCED     STALE      istiod-7f9b5-abc12
cart-5c7d8b-m3n5q.shop           SYNCED     SYNCED     SYNCED     SYNCED     istiod-7f9b5-abc12
```

`STALE` next to `payment` is the proof — its sidecar has an outdated snapshot of configuration and isn't receiving pushes. Confirm what it's actually running versus what's configured in the cluster:

```bash
istioctl proxy-config listener <payment-pod>.shop | head -5
kubectl get authorizationpolicy -n shop payment-allow-cart -o yaml
```

If the listener output doesn't reflect the policy you just applied, that mismatch is the second half of the proof. Check the sidecar's own connection state to `istiod`:

```bash
kubectl logs -n shop <payment-pod> -c istio-proxy --tail=50 | grep -i "xds\|connect"
```

Repeated connection errors or a lack of recent `ACK` log lines confirm the sync is broken, not just slow.

### The Fix

Most commonly this comes from resource pressure on the proxy, a network policy blocking the connection to `istiod`, or the proxy process being stuck. Restart the sidecar to force a fresh connection.

```bash
kubectl delete pod -n shop <payment-pod>
```

If pods across the mesh are frequently going `STALE`, check `istiod`'s own health and load rather than restarting proxies one at a time forever:

```bash
kubectl top pod -n istio-system -l app=istiod
kubectl logs -n istio-system -l app=istiod --tail=100 | grep -i "error\|timeout"
```

**Step by step:**

1. Identify every `STALE` or `NOT SENT` proxy with `istioctl proxy-status` — don't assume it's isolated to one pod.
2. Check `istiod`'s resource usage; a control plane under memory or CPU pressure will fall behind on pushes to many proxies at once.
3. Restart the affected sidecar(s). If the root cause is `istiod` capacity, scale `istiod` instead of restarting proxies repeatedly.

### Validate After: Prove the Proxy Is Synced and Reflects the Real Policy

```bash
istioctl proxy-status
```

Expect `payment` to show `SYNCED` across every column. Confirm the actual applied configuration matches the cluster object:

```bash
istioctl proxy-config listener <payment-pod>.shop -o json | grep -A 3 "payment-allow-cart"
```

Then re-run the original failing request:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# Expect: 200, matching the loosened policy
```

`SYNCED` status plus a request result that matches the current policy — not the old one — is the proof the fix took hold.

---

## Problem 2: A Rolling Deployment Causes a Burst of 503s

**The problem.** `inventory` is being rolled from v1 to v2. During the rollout, `orders` starts seeing intermittent `503 UC` (upstream connect error) responses, even though both old and new `inventory` pods report `Ready` in `kubectl get pods`.

### Validate Before: Prove the 503s Are Happening and Identify Their Type

```bash
for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080
done | sort | uniq -c
```

A nonzero count of `503` responses during the rollout is the first proof. Pin down the exact cause using the response flag in the access log, not just the status code:

```bash
kubectl logs -n shop <orders-pod> -c istio-proxy --since=5m | grep " 503 "
```

```
[2026-09-27T10:15:22.104Z] "GET / HTTP/1.1" 503 UC "-" "-" 0 95 1 - "-" ... upstream_cluster="outbound|8080||inventory.shop.svc.cluster.local" ...
```

The `UC` flag specifically means "upstream connection termination" — the sidecar tried to send the request to a pod that was in the process of shutting down or hadn't fully started, not a genuine application failure. That flag, not just the 503 count, is what tells you this is a rollout timing problem rather than a bug in `inventory` itself.

### The Fix

Give Envoy time to notice a pod is terminating before Kubernetes actually kills it, using a `preStop` hook, and make sure new pods don't receive traffic before their sidecar is actually ready.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory
  namespace: shop
spec:
  template:
    spec:
      containers:
      - name: app
        lifecycle:
          preStop:
            exec:
              command: ["sh", "-c", "sleep 5"]
```

And confirm the sidecar holds application traffic until the proxy is actually ready, which is the default in modern Istio but worth verifying explicitly:

```yaml
      annotations:
        proxy.istio.io/config: |
          holdApplicationUntilProxyStarts: true
```

**Step by step:**

1. Add a `preStop` hook on the application container so it keeps serving for a few seconds after Kubernetes marks it for termination, giving Envoy time to drain connections cleanly.
2. Confirm `holdApplicationUntilProxyStarts` is enabled so new pods don't accept traffic before their own sidecar is up.
3. Roll out the change and trigger a fresh deployment to test it.

```bash
kubectl apply -f inventory-deployment.yaml
kubectl rollout restart deployment inventory -n shop
```

### Validate After: Prove the Rollout No Longer Produces 503 UC Errors

While the new rollout is in progress, repeat the same batch of requests:

```bash
kubectl rollout restart deployment inventory -n shop

for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080
done | sort | uniq -c
```

Expect all `200`s this time, with zero `503`s during the rollout window. Confirm no fresh `UC` flags appear in the access log during the same window:

```bash
kubectl logs -n shop <orders-pod> -c istio-proxy --since=2m | grep " 503 "
# Expect: no output
```

A clean rollout with zero `503 UC` entries, compared against the burst you captured before, is the proof.

---

## Problem 3: A Pod Never Becomes Ready, Even Though the App Is Fine

**The problem.** A new `frontend` pod is stuck at `0/2` Ready for several minutes after every deploy. The application logs show it started successfully and is listening on its port, but Kubernetes won't route any traffic to it.

### Validate Before: Prove the App Is Healthy but the Pod Isn't Ready

```bash
kubectl get pods -n shop -l app=frontend
```

```
NAME                        READY   STATUS    RESTARTS
frontend-7d9f8c9b5f-x2k4p   1/2     Running   0
```

Check which container isn't ready:

```bash
kubectl describe pod -n shop <frontend-pod> | grep -A 10 "Conditions"
```

Check the app container's own logs to confirm it thinks it's fine:

```bash
kubectl logs -n shop <frontend-pod> -c app --tail=20
# Shows: "Server listening on :8080" with no errors
```

Now check the sidecar's own readiness:

```bash
kubectl logs -n shop <frontend-pod> -c istio-proxy --tail=30
```

If the sidecar's logs show it's still trying to establish its initial connection to `istiod`, or waiting on certificate provisioning, that's the proof — the *application* is healthy, but the pod's overall readiness is gated on the *sidecar's* own readiness probe, which hasn't passed yet.

```bash
kubectl exec -n shop <frontend-pod> -c istio-proxy -- curl -s localhost:15021/healthz/ready
```

A non-200 response here, while the app container is clearly healthy, is the direct proof of where the readiness gate is stuck.

### The Fix

This is usually a symptom of the sidecar failing to reach `istiod` for certificates, often due to a `NetworkPolicy` blocking the connection, or resource starvation delaying proxy startup. Check for a blocking `NetworkPolicy` first, since it's the most common cause:

```bash
kubectl get networkpolicy -n shop
```

If one exists and doesn't explicitly allow egress to `istiod` on port 15012, that's likely it:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-istiod
  namespace: shop
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: istio-system
    ports:
    - protocol: TCP
      port: 15012
```

**Step by step:**

1. Check for `NetworkPolicy` objects in the namespace that might block egress to `istio-system`.
2. If resource starvation is the cause instead, check sidecar CPU/memory requests and node pressure.
3. Apply the fix and redeploy to confirm.

```bash
kubectl apply -f allow-istiod-egress.yaml
kubectl rollout restart deployment frontend -n shop
```

### Validate After: Prove the Sidecar Becomes Ready Promptly

```bash
kubectl rollout restart deployment frontend -n shop

kubectl get pods -n shop -l app=frontend -w
```

Expect the pod to reach `2/2` within the normal startup window, not stuck at `1/2`. Confirm the sidecar readiness endpoint directly:

```bash
kubectl exec -n shop <new-frontend-pod> -c istio-proxy -- curl -s -o /dev/null -w "%{http_code}\n" localhost:15021/healthz/ready
# Expect: 200
```

A `200` here, combined with the pod reaching `2/2` in a normal amount of time, is the proof the sidecar can now reach `istiod` and complete its own startup.

---

## Problem 4: mTLS Handshakes Fail After a Certificate Rotation

**The problem.** ShopFast rotates its root certificate as part of a routine security process. Immediately after, `cart` can no longer call `payment` — not with a `403` this time, but with connection resets, because the two sidecars are presenting certificates signed by roots the other side no longer trusts.

### Validate Before: Prove the Failure Is a TLS Handshake Problem, Not an Authorization Problem

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -v http://payment:8080/api/v1/charge -X POST
```

```
* Connection reset by peer
```

A connection reset — not a `403` — is the first clue this isn't an `AuthorizationPolicy` problem. Confirm it's specifically a TLS trust issue by inspecting the certificates each sidecar is presenting:

```bash
istioctl proxy-config secret <payment-pod>.shop
```

```
RESOURCE NAME     TYPE           STATUS       VALID CERT     SERIAL NUMBER
default           Cert Chain     ACTIVE       true           2a1f...
ROOTCA             CA             ACTIVE       true           9c3e...
```

Compare the `ROOTCA` serial number on `payment` against the one on `cart`:

```bash
istioctl proxy-config secret <cart-pod>.shop
```

Different `ROOTCA` serial numbers on the two sides is the exact proof: the two proxies have not yet converged on the same trust root, so any handshake between them fails at the TLS layer before authorization is ever evaluated.

### The Fix

Root certificate rotation must be done with an overlap period — both the old and new root trusted simultaneously — never a hard cutover. Check whether the rotation was done properly:

```bash
kubectl get secret -n istio-system cacerts -o yaml
```

If only the new root is present with no overlap, restore a trust bundle that includes both roots during the transition:

```bash
istioctl x precheck
```

Use `istioctl` to push a combined trust bundle so every proxy trusts both the old and new root during the transition window, then roll out fresh certs to every workload:

```bash
kubectl rollout restart deployment -n shop --all
```

**Step by step:**

1. Never hard-cut a root certificate rotation — always maintain a trust bundle containing both old and new roots during the transition.
2. Restart every workload in the affected namespace so each sidecar picks up a fresh certificate signed correctly and rebuilds its trust bundle.
3. Only remove the old root from the trust bundle once every proxy has confirmed it's using the new one.

### Validate After: Prove Both Sides Trust the Same Root and the Handshake Succeeds

```bash
istioctl proxy-config secret <payment-pod>.shop
istioctl proxy-config secret <cart-pod>.shop
```

Expect matching `ROOTCA` serial numbers on both sides this time. Re-run the original failing request:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
# Expect: 200, no connection reset
```

Matching root serials plus a successful, non-reset response together prove the trust chain is consistent across the mesh again.

---

## Problem 5: The Ingress Gateway Returns 404 for a Route That Should Exist

**The problem.** Customers hit `shopfast.example.com/checkout` and get a `404` from the ingress gateway, even though `frontend`'s `VirtualService` clearly has a route for `/checkout` and the service itself is healthy internally.

### Validate Before: Prove the Gateway Itself Doesn't Have the Route

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://shopfast.example.com/checkout
# 404
```

Confirm `frontend` is healthy when called directly inside the mesh, to rule out an application problem:

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://frontend:8080/checkout
# 200 — the service itself is fine
```

That contrast — working internally, `404` externally — points at the gateway layer specifically. Confirm the route is actually missing from the gateway's own configuration, not just assumed to be there:

```bash
istioctl proxy-config routes <ingressgateway-pod>.istio-system --name http.80 -o json | grep -A 5 checkout
```

If nothing comes back, or the route table doesn't include `/checkout` at all, that's the proof: the `VirtualService` for `frontend` is either not bound to the gateway, or the `Gateway` resource itself doesn't have a matching host/port entry.

```bash
kubectl get gateway -n shop -o yaml
kubectl get virtualservice frontend -n shop -o yaml
```

Check specifically whether the `VirtualService`'s `gateways` field references the actual `Gateway` object by name, and whether the `Gateway`'s `hosts` field includes `shopfast.example.com`.

### The Fix

Bind the `VirtualService` to the correct `Gateway` explicitly, and make sure the `Gateway` itself is listening for the right host.

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: shopfast-gateway
  namespace: shop
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "shopfast.example.com"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend
  namespace: shop
spec:
  hosts:
  - "shopfast.example.com"
  gateways:
  - shopfast-gateway
  http:
  - match:
    - uri:
        prefix: /checkout
    route:
    - destination:
        host: frontend
        port:
          number: 8080
```

**Step by step:**

1. Confirm the `Gateway` resource's `hosts` field actually lists the domain customers are using.
2. Confirm the `VirtualService`'s `gateways` field names that exact `Gateway` — omitting it, or leaving the default `mesh` value, means the rule never applies to gateway traffic at all.
3. Apply both together, since a `Gateway` with no bound `VirtualService` (or vice versa) is equally useless.

### Validate After: Prove the Route Now Resolves Through the Gateway

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://shopfast.example.com/checkout
# Expect: 200
```

Confirm the route now appears explicitly in the gateway's live configuration, not just that the external call happened to succeed:

```bash
istioctl proxy-config routes <ingressgateway-pod>.istio-system --name http.80 -o json | grep -A 5 checkout
```

A visible `/checkout` route entry, plus a `200` from the external URL where you previously got a `404`, is the proof the binding between `Gateway` and `VirtualService` is now correct end to end.

---

## Troubleshooting Checklist

| Problem | Control | Resource | Validate Before | Validate After |
|---|---|---|---|---|
| Stale proxy config | Force resync / scale control plane | Pod restart, `istiod` capacity | `istioctl proxy-status` shows `STALE` | Status shows `SYNCED`; live request matches current policy |
| Rollout 503s | Graceful connection draining | `preStop` hook, `holdApplicationUntilProxyStarts` | Access logs show `503 UC` during rollout | Zero `UC` flags during a fresh rollout |
| Pod stuck not-ready | Unblock sidecar-to-istiod connectivity | `NetworkPolicy` egress rule | App healthy, `istio-proxy` readiness endpoint non-200 | Pod reaches `2/2` promptly; readiness endpoint returns 200 |
| mTLS handshake failures after rotation | Overlapping trust bundle during rotation | `cacerts` trust bundle | Mismatched `ROOTCA` serials between proxies; connection reset | Matching root serials; handshake succeeds |
| Gateway 404 on a working service | Correct Gateway/VirtualService binding | `Gateway` + `VirtualService` `gateways` field | Route missing from gateway's route table | Route appears in gateway config; external call returns 200 |

## Exam Angle

If you're preparing for the Istio Certified Associate (ICA) exam, focus on reading Envoy's response flags (`UC`, `NR`, `UF`, `URX`) rather than status codes alone, knowing that `istioctl proxy-status` and `istioctl proxy-config` are your primary diagnostic tools before you ever reach for raw Envoy admin endpoints, and understanding that a `VirtualService` with no `gateways` field silently applies to `mesh` traffic only — one of the most common causes of "my route works internally but not through the gateway."

## Try It Yourself

On the same ShopFast cluster, deliberately break each scenario — delete a `NetworkPolicy` rule, remove a `gateways` field, restart `istiod` under load — and practice diagnosing it blind before looking at the fix. The diagnostic commands above (`istioctl proxy-status`, `proxy-config secret`, `proxy-config routes`, and reading response flags in access logs) are the same handful of tools that solve nearly every Istio incident in production.
