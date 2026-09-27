# Installation, Upgrade & Configuration in Production: Five Real Problems, Five Real Fixes

Security controls who can talk to whom. Traffic management controls how requests behave. Neither matters if the mesh itself is installed, upgraded, or configured carelessly — a bad upgrade or a silently invalid config can take down every service at once, security policies included. This post continues the ShopFast scenario and walks through five installation, upgrade, and configuration problems that show up constantly in real clusters, each with a way to **prove the problem exists**, the **fix**, and a way to **prove the fix worked**.

## The Scenario: ShopFast (Recap)

Same five services, same `shop` namespace:

| Service | Responsibility |
|---|---|
| `frontend` | Customer-facing web app |
| `cart` | Holds the customer's basket |
| `orders` | Creates and tracks orders |
| `payment` | Charges cards through an external provider |
| `inventory` | Tracks stock levels |

This time, ShopFast is adding a sixth service (`notifications`), and separately, the platform team needs to upgrade Istio itself. Both operations go wrong in ways that are common — and preventable.

---

## Problem 1: A New Service Goes Live With No Sidecar — and No One Notices

**The problem.** A developer creates a new `notifications` deployment. The namespace it lands in was created before the team standardized on auto-injection, so it was never labeled. The pod starts, looks healthy in `kubectl get pods`, and quietly runs with zero mTLS, zero authorization policy enforcement, and zero traffic management — completely outside the mesh.

### Validate Before: Prove the Pod Has No Sidecar

```bash
kubectl get pods -n shop -l app=notifications
```

```
NAME                             READY   STATUS
notifications-7d9f8c9b5f-x2k4p   1/1     Running
```

That `1/1` is the proof. Every meshed pod in ShopFast shows `2/2` — one container for the app, one for the `istio-proxy` sidecar. A lone `1/1` means this pod is invisible to every mTLS and authorization policy you configured earlier.

Confirm it directly:

```bash
kubectl get pod -n shop -l app=notifications -o jsonpath='{.items[0].spec.containers[*].name}'
# Expect: only "notifications", no "istio-proxy"

kubectl get namespace shop -o jsonpath='{.metadata.labels}'
# Check for istio-injection=enabled or istio.io/rev=<revision>
```

As a sharper test, call `notifications` from outside the mesh entirely — a plain pod with no sidecar. If a strict `PeerAuthentication` is in effect elsewhere in `shop`, a meshed service would reject this; an unmeshed one won't:

```bash
kubectl run plain-client -n default --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://notifications.shop.svc.cluster.local:8080
# A 200 here, despite STRICT mTLS elsewhere, proves this pod is outside mesh enforcement
```

### The Fix

Enable injection at the namespace level, then restart the workload so the webhook actually adds the sidecar.

```bash
kubectl label namespace shop istio-injection=enabled --overwrite
```

If your cluster uses revision-based injection instead of the default webhook:

```bash
kubectl label namespace shop istio-injection- --overwrite   # remove the old label if present
kubectl label namespace shop istio.io/rev=stable --overwrite
```

**Step by step:**

1. Confirm which injection mechanism your cluster uses — default (`istio-injection=enabled`) or revision-based (`istio.io/rev=<name>`). Mixing both on the same namespace is a common source of confusion.
2. Apply the correct label to the namespace.
3. Labeling the namespace does **not** retroactively inject already-running pods — you must restart them.

```bash
kubectl rollout restart deployment notifications -n shop
```

### Validate After: Prove the Sidecar Is Now Present and Enforced

```bash
kubectl get pods -n shop -l app=notifications
```

Expect `2/2` this time. Confirm the second container explicitly:

```bash
kubectl get pod -n shop -l app=notifications -o jsonpath='{.items[0].spec.containers[*].name}'
# Expect: "notifications istio-proxy"
```

Re-run the plain-client call from outside the mesh:

```bash
kubectl run plain-client -n default --rm -it --image=curlimages/curl -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://notifications.shop.svc.cluster.local:8080
```

If `shop` enforces `STRICT` mTLS, this should now fail or be rejected — proof the pod is finally inside the mesh's enforcement boundary, not just running a sidecar cosmetically.

---

## Problem 2: An In-Place Control Plane Upgrade Breaks Every Service at Once

**The problem.** The platform team runs `istioctl upgrade` directly against the live control plane. A subtle behavior change in the new version breaks `payment`'s outlier detection config, and because every workload's sidecar reconnects to the single upgraded control plane simultaneously, the impact hits all five services at the same moment, in production, with no way to roll back quickly.

### Validate Before: Prove There's Only One Control Plane to Break

```bash
istioctl version
```

```
control plane version: 1.22.0
data plane version: 1.22.0 (5 proxies)
```

A single control plane version serving every proxy is the proof — there is no isolation. If the upgrade misbehaves, all 5 proxies are affected simultaneously, and the only way back is a full reinstall of the old version.

```bash
kubectl get pods -n istio-system -l app=istiod
# Expect: a single istiod deployment, one revision
```

### The Fix

Use a canary control plane upgrade: install the new version alongside the old one under a different revision tag, move a small slice of workloads to it, and only cut over fully once it's proven stable.

```bash
# Install the new version as a separate, non-default revision
istioctl install --set revision=1-23-0 --set profile=demo -y
```

```bash
kubectl get pods -n istio-system
# Both istiod-1-22-0-xxxx and istiod-1-23-0-xxxx should be running
```

Move only `inventory` to the new revision as a test:

```bash
kubectl label namespace shop istio-injection- --overwrite
kubectl label namespace shop istio.io/rev=1-23-0 --overwrite

kubectl rollout restart deployment inventory -n shop
```

**Step by step:**

1. Install the new control plane version under its own `revision` — it runs side by side with the old one, not in place of it.
2. Re-label only a test workload's namespace (or use per-pod injection labels for finer granularity) to point at the new revision.
3. Restart just that workload and observe it before touching anything else.
4. Only after validation does the rest of the mesh move to the new revision, and only then is the old `istiod` uninstalled.

### Validate After: Prove the Blast Radius Is Contained

Confirm which revision each workload is actually using:

```bash
istioctl proxy-status
```

```
NAME                              CDS        LDS        EDS        ISTIOD
inventory-xxxx.shop               SYNCED     SYNCED     SYNCED     istiod-1-23-0-xxxx
cart-xxxx.shop                    SYNCED     SYNCED     SYNCED     istiod-1-22-0-xxxx
payment-xxxx.shop                 SYNCED     SYNCED     SYNCED     istiod-1-22-0-xxxx
orders-xxxx.shop                  SYNCED     SYNCED     SYNCED     istiod-1-22-0-xxxx
frontend-xxxx.shop                SYNCED     SYNCED     SYNCED     istiod-1-22-0-xxxx
```

That output is the proof: `inventory` is talking to the new control plane while everything else is untouched on the old one. If the new version misbehaves, only `inventory` is affected, and rolling it back is a single re-label and restart — not a mesh-wide incident.

```bash
kubectl label namespace shop istio.io/rev-   # rollback: remove the new-revision label
kubectl label namespace shop istio-injection=enabled --overwrite
kubectl rollout restart deployment inventory -n shop
```

Only once `inventory` has run cleanly on the new revision for a reasonable soak period should the rest of `shop` be migrated the same way, revision by revision.

---

## Problem 3: A Bad Configuration Change Is Applied and Nobody Catches It

**The problem.** An engineer pushes a `VirtualService` update for `orders` with a typo in the host field. `kubectl apply` succeeds — Kubernetes accepts any syntactically valid YAML — but the rule silently does nothing, and `orders` traffic quietly falls back to default routing, undoing an in-progress canary rollout without any error appearing anywhere.

### Validate Before: Prove Kubernetes Accepts Broken Istio Config Without Complaint

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: orders-broken
  namespace: shop
spec:
  hosts:
  - order        # typo: should be "orders"
  http:
  - route:
    - destination:
        host: orders
        subset: v2
      weight: 100
```

```bash
kubectl apply -f orders-broken.yaml
```

```
virtualservice.networking.istio.io/orders-broken created
```

That clean success message is the proof of the problem: Kubernetes validated the YAML *syntax*, not its semantic correctness against the mesh. The typo means this rule applies to a host that doesn't exist, so it silently has zero effect, and nothing in `kubectl`'s output tells you that.

### The Fix

Run Istio's own configuration analyzer, both as a manual gate before every apply and as a standing check against the live cluster.

```bash
istioctl analyze -n shop
```

```
Error [IST0101] (VirtualService orders-broken.shop) Referenced host+subset in destination not found: "orders+v2"
Warning [IST0132] (VirtualService orders-broken.shop) No destinations match rule's subsets, missing them and possible typos
```

**Step by step:**

1. Run `istioctl analyze` against any manifest before applying it, not just after:

   ```bash
   istioctl analyze orders-broken.yaml -n shop
   ```

2. Wire `istioctl analyze` into CI so a bad manifest never reaches `kubectl apply` in the first place.
3. Fix the typo and re-apply.

```bash
kubectl delete virtualservice orders-broken -n shop
```

Apply the corrected version with the right host.

### Validate After: Prove the Analyzer Catches the Class of Problem, Not Just This Instance

Re-run the analyzer against the corrected configuration:

```bash
istioctl analyze -n shop
```

```
✔ No validation issues found when analyzing namespace: shop.
```

That clean result on the corrected config, compared against the errors it caught on the broken one, is your proof the gate actually works. Confirm it also catches a fresh mistake — reintroduce a typo temporarily and watch it get flagged again before you make analyzing config a permanent habit rather than a one-off check.

---

## Problem 4: Every Sidecar Downloads Configuration for Every Service in the Mesh

**The problem.** As ShopFast adds more services, each sidecar proxy — including `frontend`'s, which only ever needs to reach `cart` — receives the full set of routing and cluster configuration for every service in the mesh. Startup gets slower, memory usage climbs, and `istiod` spends more CPU pushing configuration that most proxies will never use.

### Validate Before: Prove Every Proxy Holds the Full Mesh Configuration

Check how many clusters `frontend`'s sidecar actually knows about:

```bash
istioctl proxy-config cluster <frontend-pod>.shop | wc -l
```

If that number is close to or larger than the total service count across the whole mesh — not just the handful `frontend` actually calls — that's the proof. `frontend` only needs to know about `cart`, yet its sidecar is carrying routing information for every other service, including ones it will never call.

```bash
kubectl exec -n shop <frontend-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep server.memory_allocated
```

Note the memory figure — you'll compare it after the fix.

### The Fix

Scope each workload's visible configuration with a `Sidecar` resource, so proxies only receive configuration for the hosts they actually need.

```yaml
apiVersion: networking.istio.io/v1
kind: Sidecar
metadata:
  name: frontend
  namespace: shop
spec:
  workloadSelector:
    labels:
      app: frontend
  egress:
  - hosts:
    - "shop/cart.shop.svc.cluster.local"
    - "istio-system/*"
```

**Step by step:**

1. Identify each workload's actual dependencies — `frontend` only calls `cart`, `cart` only calls `payment`, `orders` calls `inventory`, and so on.
2. Write a `Sidecar` resource per workload restricting `egress` to just those hosts, plus `istio-system/*` for control-plane traffic.
3. Apply them one at a time, and validate each before moving to the next — an overly narrow `Sidecar` resource can break legitimate calls.

### Validate After: Prove the Proxy's Configuration Shrank

```bash
kubectl rollout restart deployment frontend -n shop

istioctl proxy-config cluster <frontend-pod>.shop | wc -l
```

Expect a significantly smaller number — close to the count of services `frontend` actually depends on, not the whole mesh.

```bash
kubectl exec -n shop <frontend-pod> -c istio-proxy -- \
  curl -s localhost:15000/stats | grep server.memory_allocated
```

Compare this figure against the one recorded before the fix — a lower number confirms the reduced configuration footprint. Finally, confirm `frontend` can still legitimately reach `cart` (the fix shouldn't have broken anything real):

```bash
kubectl run client -n shop --rm -it --image=curlimages/curl \
  --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- \
  curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080
# Expect: 200
```

---

## Problem 5: Sidecars Get OOMKilled Under Real Load

**The problem.** ShopFast's sidecars were installed with the default resource settings from years ago, sized for a much smaller mesh. Under Black Friday traffic, several `istio-proxy` containers hit their memory limit and get OOMKilled, taking their application containers down with them even though the app itself had plenty of headroom.

### Validate Before: Prove the Sidecars Are Under-Provisioned and Getting Killed

```bash
kubectl get pods -n shop -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[?(@.name=="istio-proxy")].restartCount}{"\n"}{end}'
```

A nonzero restart count on `istio-proxy` containers is a strong signal. Confirm the cause directly:

```bash
kubectl describe pod -n shop <payment-pod> | grep -A 5 "istio-proxy"
```

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

`OOMKilled` on the sidecar container is the proof. Check what it was actually allowed to use:

```bash
kubectl get pod -n shop <payment-pod> -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].resources}'
```

```
{"limits":{"memory":"128Mi"},"requests":{"memory":"64Mi"}}
```

Under real load, a sidecar handling `payment`'s traffic volume routinely needs more than 128Mi, and the container is being killed for exceeding a limit that was never revisited.

### The Fix

Raise the sidecar resource limits, either globally at install time or per-workload via annotations.

Globally, via the Istio installation config:

```yaml
# istio-operator.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      proxy:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
```

```bash
istioctl install -f istio-operator.yaml -y
```

Or scoped to just the high-traffic `payment` workload, via pod annotations:

```yaml
metadata:
  annotations:
    sidecar.istio.io/proxyCPU: "200m"
    sidecar.istio.io/proxyMemory: "128Mi"
    sidecar.istio.io/proxyCPULimit: "500m"
    sidecar.istio.io/proxyMemoryLimit: "256Mi"
```

**Step by step:**

1. Check real sidecar memory usage under load (via `kubectl top pod` or metrics during a load test) before picking new numbers — don't just double the old limit blindly.
2. Apply the new resource settings, globally or per-workload depending on how uniform the traffic pattern is across services.
3. Restart the affected workloads so the new limits take effect.

```bash
kubectl rollout restart deployment payment -n shop
```

### Validate After: Prove the Sidecar Survives Under the Same Load

Confirm the new limits are actually applied:

```bash
kubectl get pod -n shop <payment-pod> -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].resources}'
```

```
{"limits":{"memory":"256Mi"},"requests":{"memory":"128Mi"}}
```

Re-run the same load test that caused the original OOMKills, then check restart counts again:

```bash
kubectl get pods -n shop -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[?(@.name=="istio-proxy")].restartCount}{"\n"}{end}'
```

A restart count that stays flat during and after the same load pattern that previously caused kills is the proof — the same traffic, no more `OOMKilled` events. Monitor actual usage against the new limit to confirm there's now real headroom, not just a higher ceiling still being hit:

```bash
kubectl top pod -n shop <payment-pod> --containers
```

---

## Installation, Upgrade & Configuration Checklist

| Problem | Control | Resource | Validate Before | Validate After |
|---|---|---|---|---|
| Missing sidecar injection | Namespace/revision labeling | Namespace label + rollout restart | Pod shows `1/1`; unmeshed traffic bypasses mTLS | Pod shows `2/2`; unmeshed access now rejected |
| Risky in-place upgrades | Canary control plane upgrade | `istioctl install --set revision=` | Single control plane serves all proxies | `istioctl proxy-status` shows isolated revision per workload |
| Silently broken config | Config analysis gate | `istioctl analyze` | `kubectl apply` succeeds on broken config | Analyzer reports zero issues on corrected config |
| Config bloat per sidecar | Scoped visibility | `Sidecar` resource | Proxy holds config for the entire mesh | Proxy's cluster/memory footprint shrinks; real calls still work |
| Sidecars OOMKilled under load | Right-sized resources | `proxy.resources` / per-pod annotations | `OOMKilled`, nonzero restart count | Same load, flat restart count, headroom confirmed |

## Exam Angle

If you're preparing for the Istio Certified Associate (ICA) exam, focus on the distinction between the default injection webhook and revision-based injection (`istio.io/rev`), why `istioctl analyze` exists as a pre-apply gate rather than a runtime enforcement tool, and what a `Sidecar` resource's `egress.hosts` field actually restricts. These are frequently tested because they trip up people who've only ever used Istio's defaults.

## Try It Yourself

On the same ShopFast cluster, deliberately reproduce each problem before fixing it — remove a namespace label, apply a typo'd manifest, leave default resource limits in place under a load test. Seeing the failure first, with the exact commands above, is what makes the fix — and the reason it exists — actually stick.
