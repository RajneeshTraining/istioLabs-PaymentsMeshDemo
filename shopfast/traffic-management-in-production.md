# Traffic Management in Production: Five Real Problems, Five Real Fixes

Security stops the wrong requests from happening. Traffic management decides what happens to the *right* ones — how long to wait, what to do when something fails, and how to roll out change without breaking checkout for everyone. This post continues the ShopFast scenario and walks through five traffic problems that show up constantly in production, each with a way to **prove the problem exists**, the **fix**, and a way to **prove the fix worked**.

## The Scenario: ShopFast (Recap)

Same five services, same `shop` namespace:

| Service | Responsibility |
|---|---|
| `frontend` | Customer-facing web app |
| `cart` | Holds the customer's basket |
| `orders` | Creates and tracks orders |
| `payment` | Charges cards through an external provider |
| `inventory` | Tracks stock levels |

This time, `payment` gets a second version, `payment-v2`, rewritten to use a faster charge algorithm. That upgrade is what breaks things.

---

## Problem 1: A Slow Downstream Call Hangs the Whole Checkout

**The problem.** `payment` occasionally takes 30+ seconds to respond because of a flaky connection to the external card processor. `orders` has no timeout configured, so it waits indefinitely, threads pile up, and the entire checkout flow grinds to a halt.

### Validate Before: Prove There's No Timeout

Simulate a slow `payment` using a fault injection, then time how long `orders` waits.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-delay-test
  namespace: shop
spec:
  hosts:
  - payment
  http:
  - fault:
      delay:
        percentage:
          value: 100
        fixedDelay: 30s
    route:
    - destination:
        host: payment
```

```bash
kubectl apply -f payment-delay-test.yaml

time kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
```

If the command hangs for the full 30 seconds before returning, that's the proof — nothing is cutting the call short, and that same 30 seconds is being passed straight up to the customer.

### The Fix

Set an explicit timeout on the route so a slow `payment` fails fast instead of hanging the caller.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-timeout
  namespace: shop
spec:
  hosts:
  - payment
  http:
  - route:
    - destination:
        host: payment
    timeout: 3s
```

**Step by step:**

1. Decide a realistic timeout based on `payment`'s normal p99 latency, not a guess.
2. Apply the `VirtualService` with the `timeout` field.
3. Keep the fault-injection rule in place for now — it's your test harness for the next step.

### Validate After: Prove the Call Now Fails Fast

Re-run the exact same timed request, with the 30-second delay fault still active:

```bash
time kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge -X POST
```

Expect the command to return in roughly 3 seconds, not 30, with a `504` status code. That timing difference — 30s before, 3s after — is your proof.

Remove the fault-injection test rule once you're done:

```bash
kubectl delete virtualservice payment-delay-test -n shop
```

---

## Problem 2: A Single Transient Error Fails an Entire Order

**The problem.** `inventory` occasionally returns a `503` for a fraction of a second during pod restarts or brief network blips. `orders` treats every `503` as a hard failure and cancels the order, even though a retry a moment later would have succeeded.

### Validate Before: Prove a Transient Failure Isn't Retried

Force `inventory` to fail a percentage of requests, then send a batch of calls and count the failures.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: inventory-fail-test
  namespace: shop
spec:
  hosts:
  - inventory
  http:
  - fault:
      abort:
        percentage:
          value: 30
        httpStatus: 503
    route:
    - destination:
        host: inventory
```

```bash
kubectl apply -f inventory-fail-test.yaml

for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080
done
```

With no retry policy, roughly 30% of those calls return `503` and fail outright. That failure rate — visible directly in the output — is the proof.

### The Fix

Add a retry policy so transient errors are retried automatically before they're surfaced as failures.

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: inventory-retry
  namespace: shop
spec:
  hosts:
  - inventory
  http:
  - route:
    - destination:
        host: inventory
    retries:
      attempts: 3
      perTryTimeout: 1s
      retryOn: 5xx,reset,connect-failure
```

**Step by step:**

1. Choose `retryOn` conditions that match genuinely transient failures (`5xx`, `reset`, `connect-failure`) — don't blindly retry everything, since retrying a real application bug just multiplies load.
2. Set `perTryTimeout` shorter than the overall request timeout so retries don't stack up into a long wait.
3. Apply the policy alongside the existing fault-injection rule.

### Validate After: Prove Transient Failures Are Now Absorbed

Re-run the same batch of 20 requests with the 30% failure fault still active:

```bash
for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080
done
```

Expect the visible failure rate to drop close to zero — Envoy is retrying the 30% of failed calls behind the scenes before your `curl` ever sees a response. Confirm the retries are actually happening by checking the sidecar's stats:

```bash
kubectl exec -n shop <inventory-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep upstream_rq_retry
```

A non-zero `upstream_rq_retry` counter is the proof the retry policy is active, not just configured.

Clean up the test fault:

```bash
kubectl delete virtualservice inventory-fail-test -n shop
```

---

## Problem 3: A New Payment Version Gets Rolled Out to Everyone at Once

**The problem.** The team deploys `payment-v2` and points all traffic at it immediately. It turns out `v2` has a bug that silently double-charges 1 in 50 transactions. Because 100% of traffic hit it instantly, the blast radius is every customer checking out that hour.

### Validate Before: Prove All Traffic Goes to One Version

Deploy `payment-v2` alongside `payment-v1` with no routing rule in place, then send a batch of requests and see where they land.

```bash
kubectl label pod -n shop -l app=payment,version=v1 version=v1 --overwrite
kubectl label pod -n shop -l app=payment,version=v2 version=v2 --overwrite

for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s http://payment:8080/version
done | sort | uniq -c
```

With no `DestinationRule` subsets and no weighted `VirtualService`, Kubernetes' default service load-balancing sends traffic to whichever pods are backing the `payment` service — with no control over the v1/v2 split. If both versions are behind the same Service, you'll see an uncontrolled, roughly-even split; if only `v2` pods are up, you'll see 100% going to the buggy version. Either way, the proof is that there is no deliberate weighting — the split is whatever Kubernetes gives you by accident, not something the team chose.

### The Fix

Define subsets and route the majority of traffic to the proven version, sending only a small slice to the new one.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: payment-versions
  namespace: shop
spec:
  host: payment
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: payment-canary
  namespace: shop
spec:
  hosts:
  - payment
  http:
  - route:
    - destination:
        host: payment
        subset: v1
      weight: 95
    - destination:
        host: payment
        subset: v2
      weight: 5
```

**Step by step:**

1. Apply the `DestinationRule` so Istio knows how to distinguish `v1` from `v2` pods by label.
2. Apply the weighted `VirtualService`, starting conservative — 5% is enough to catch a bug like this without exposing most customers.
3. Watch `v2`'s error rate before increasing its weight.

### Validate After: Prove the Split Matches the Configured Weights

Send a larger batch and check the actual distribution:

```bash
for i in $(seq 1 100); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s http://payment:8080/version
done | sort | uniq -c
```

Expect roughly 95 responses from `v1` and roughly 5 from `v2` — close to the configured weights, not an even or uncontrolled split. That distribution, matching the numbers in the `VirtualService`, is your proof the canary rule is actually in effect and not just applied-but-ignored.

---

## Problem 4: One Unhealthy Pod Drags Down the Whole Service

**The problem.** One of the three `inventory` pods develops a memory leak and starts responding slowly and with errors, but it's still marked "Ready" by its readiness probe. Istio keeps sending it a third of all traffic, so roughly a third of every customer's requests are slow or broken.

### Validate Before: Prove the Bad Pod Keeps Getting Traffic

Identify the struggling pod and simulate its bad behavior with a delay fault targeted only at it (or, in a real cluster, observe its latency directly):

```bash
kubectl get pods -n shop -l app=inventory -o wide
```

Send a batch of requests and check per-pod response times using access logs:

```bash
for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{time_total}\n" http://inventory:8080
done
```

```bash
kubectl logs -n shop <bad-inventory-pod> -c istio-proxy --since=2m | grep inventory
```

You should see a mix of fast and slow response times in the batch, and the bad pod's own access log confirms it's still receiving roughly its fair share of requests — proof that nothing is routing around it.

### The Fix

Configure outlier detection so Istio automatically ejects a misbehaving pod from the load-balancing pool.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: inventory-outlier
  namespace: shop
spec:
  host: inventory
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 3
      interval: 10s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

**Step by step:**

1. Set `consecutive5xxErrors` low enough to react quickly, but not so low that a single blip ejects a healthy pod.
2. Cap `maxEjectionPercent` so a bad rollout can't eject the entire pool and take the service down completely.
3. Apply the `DestinationRule` and let it run against real or simulated failures.

### Validate After: Prove the Bad Pod Gets Ejected

Force the same pod to fail consistently (fault injection scoped to that pod's traffic, or wait for its real errors), then send another batch of requests:

```bash
for i in $(seq 1 30); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"orders"}}' -- \
    curl -s -o /dev/null -w "%{time_total}\n" http://inventory:8080
done
```

Check the sidecar stats on the healthy pods for ejection activity:

```bash
kubectl exec -n shop <inventory-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep outlier_detection
```

Look for `outlier_detection.ejections_active` at 1 or more, and confirm via the access logs on the bad pod that its request count drops off after the `baseEjectionTime` window starts. That drop — combined with the ejection counter incrementing — is the proof Istio pulled it out of rotation automatically.

---

## Problem 5: A New Checkout Version Can't Be Tested Without Risking Real Orders

**The problem.** The team wants to test `orders-v2` against real production traffic patterns before trusting it, but sending live customers to an unproven version risks creating duplicate or broken orders.

### Validate Before: Prove There's No Safe Way to Test Against Live Traffic Yet

With only a weighted split available, any traffic sent to `orders-v2` is traffic a real customer experiences — there's no way to observe `v2`'s behavior without exposing someone to it.

```bash
kubectl get virtualservice orders -n shop -o yaml
```

If the only routing options visible are weighted `route` rules, that's the proof: the current setup makes "test with production traffic" and "expose customers to an unproven version" the same action. There is no mechanism to send a *copy* of traffic to `v2` while `v1` still handles the real response.

### The Fix

Use traffic mirroring so `orders-v2` receives a copy of real traffic, but its responses are discarded — customers only ever see `v1`'s answer.

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: orders-versions
  namespace: shop
spec:
  host: orders
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: orders-mirror
  namespace: shop
spec:
  hosts:
  - orders
  http:
  - route:
    - destination:
        host: orders
        subset: v1
      weight: 100
    mirror:
      host: orders
      subset: v2
    mirrorPercentage:
      value: 100
```

**Step by step:**

1. Apply the `DestinationRule` defining both subsets.
2. Apply the `VirtualService` with `weight: 100` on `v1` so customers only ever get `v1`'s response, and `mirror` pointing at `v2`.
3. Watch `v2`'s logs and error rates as it silently processes copies of live traffic.

### Validate After: Prove Customers See Only v1, While v2 Receives Copies

Send a batch of real requests and confirm every response comes from `v1`:

```bash
for i in $(seq 1 20); do
  kubectl run client-$i -n shop --rm --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"serviceAccountName":"cart"}}' -- \
    curl -s http://orders:8080/version
done | sort | uniq -c
# Expect: all 20 responses from v1
```

Then confirm `v2` received copies of the same traffic, even though it answered none of the customer-facing calls:

```bash
kubectl logs -n shop <orders-v2-pod> -c orders --since=2m | grep -c "request received"
```

Expect that count to be close to 20 — proof that `v2` saw the same volume of traffic as `v1`, without a single customer response coming from it. Mirrored requests in Envoy are also tagged distinctly in access logs (typically with `-shadow` appended to the cluster name), which you can confirm with:

```bash
kubectl logs -n shop <orders-v1-pod> -c istio-proxy --since=2m | grep shadow
```

---

## Traffic Management Checklist

| Problem | Control | Resource | Validate Before | Validate After |
|---|---|---|---|---|
| Hanging calls | Fail fast on slow dependencies | `VirtualService` `timeout` | Request hangs for full delay (30s) | Request fails fast at configured timeout (3s) |
| Transient errors | Retry on genuinely transient failures | `VirtualService` `retries` | ~30% of calls fail outright | Failures absorbed; `upstream_rq_retry` counter increments |
| Risky rollouts | Weighted canary release | `DestinationRule` + weighted `VirtualService` | Uncontrolled/all-or-nothing split | Traffic split matches configured weights (e.g. 95/5) |
| Unhealthy instances | Automatic ejection | `DestinationRule` `outlierDetection` | Bad pod keeps receiving its full share | Bad pod ejected; `ejections_active` > 0 |
| Testing new versions safely | Traffic mirroring | `VirtualService` `mirror` | No way to test without exposing customers | Customers see only `v1`; `v2` receives copies, tagged `-shadow` |

## Exam Angle

If you're preparing for the Istio Certified Associate (ICA) exam, focus on the difference between `DestinationRule` (defines subsets and traffic policy like outlier detection and load balancing) and `VirtualService` (defines routing rules like weights, retries, timeouts, and mirroring) — a huge share of traffic management questions test whether you know which object owns which responsibility.

## Try It Yourself

Build on the same ShopFast cluster from the security post. For each problem: run the "before" validation using the fault-injection rule provided, apply the fix, then re-run the identical validation and compare the numbers. The fault-injection rules are disposable test harnesses — always remove them once you've confirmed the fix, so they don't linger and mask real production behavior later.
