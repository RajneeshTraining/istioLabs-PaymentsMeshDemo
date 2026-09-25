# 🚦 ShopFast — Traffic Management Lab

Five real release-management problems, and the Istio traffic-management
features that solve each one. Same loop as before:

> **💥 Set the scene → 🔍 Prove the problem → 🛠️ Apply the fix → ✅ Validate**

Every `kubectl` command is a **single command** — run each one, read its
output, and know exactly what it proved before moving on.

---

## 📖 Table of Contents

- [Prerequisites](#-prerequisites)
- [Setup](#-setup)
- [🗺️ Traffic Management Features at a Glance](#️-traffic-management-features-at-a-glance)
- [Quest 1 — Controlled Canary Rollout](#quest-1--controlled-canary-rollout)
- [Quest 2 — Path-Based Routing Sends Traffic to the Wrong Service](#quest-2--path-based-routing-sends-traffic-to-the-wrong-service)
- [Quest 3 — A Slow Dependency Hangs the Whole Request Chain](#quest-3--a-slow-dependency-hangs-the-whole-request-chain)
- [Quest 4 — Transient Errors Become User-Facing Failures](#quest-4--transient-errors-become-user-facing-failures)
- [Quest 5 — Testing a New Version Safely With Real Traffic](#quest-5--testing-a-new-version-safely-with-real-traffic)
- [Cleanup](#-cleanup)
- [Quick Reference](#-quick-reference)

---

## ✅ Prerequisites

| Tool | Needed for |
|---|---|
| `kind` or `minikube` | The cluster |
| `kubectl` | Applying manifests, reading pods/logs |
| `istioctl` | Install, `proxy-config` |
| ~4 GB free RAM | The demo profile |

---

## 🚀 Setup

> **📁 Do this once, in order. Confirm the "Expected" output before moving on.**

**1. Create the cluster**

```bash
kind create cluster --name shopfast-tm
```

**2. Install Istio with the demo profile**

```bash
istioctl install --set profile=demo -y
```

**3. Confirm the control plane is up**

```bash
kubectl get pods -n istio-system
```

> **✅ Expected:** `istiod` and `istio-ingressgateway` both show `Running`.

**4. Create the `shop` namespace**

```bash
kubectl apply -f 00-namespace.yaml
```

**5. Deploy the baseline services**

```bash
kubectl apply -f 01-services.yaml
```

**6. Wait for everything to be ready**

```bash
kubectl wait --for=condition=Ready pod --all -n shop --timeout=120s
```

**7. Confirm every pod is running with a sidecar**

```bash
kubectl get pods -n shop
```

> **✅ Expected:** every pod shows `2/2 READY`.

**8. Create a reusable in-mesh client pod**

```bash
kubectl run client -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- sleep 3600
```

```bash
kubectl wait --for=condition=Ready pod/client -n shop --timeout=60s
```

You're ready to begin. 🎯

---

## 🗺️ Traffic Management Features at a Glance

| Feature | Resource | Solves |
|---|---|---|
| **Weighted routing** | `VirtualService` + `DestinationRule` subsets | Gradual, controllable rollouts |
| **Path/host routing** | `VirtualService` match rules | Directing requests to the right backend |
| **Timeouts** | `VirtualService` `timeout` | Slow dependencies hanging callers |
| **Retries** | `VirtualService` `retries` | Transient failures becoming visible errors |
| **Traffic mirroring** | `VirtualService` `mirror` | Testing new versions with zero user risk |

---

## Quest 1 — Controlled Canary Rollout

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

`orders-v2` is ready to ship. Right now there's no Istio routing config at
all — the Kubernetes Service just load-balances across whatever pods match
its selector. That means the moment `orders-v2` exists, it starts getting a
share of production traffic with **no way to control or limit that share**.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 02-quest1-orders-v2.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=orders,version=v2 -n shop --timeout=60s
```

### 🔍 Prove the problem

**Send 20 requests and count how many hit each version:**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 20); do curl -s http://orders:8080/; done | sort | uniq -c'
```

> **🚨 Expected:** roughly a 50/50 split between `orders v1 ok` and
> `orders v2 ok`. The brand-new, unvalidated version is already handling
> half of production traffic — there is no dial to turn that down.

### 🛠️ Apply the fix

```bash
kubectl apply -f 02-quest1-fix.yaml
```

### ✅ Validate

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 20); do curl -s http://orders:8080/; done | sort | uniq -c'
```

> **✅ Expected:** roughly 18 responses from `orders v1 ok` and 2 from
> `orders v2 ok` — an ~90/10 split you can now dial up gradually
> (`weight: 90/10` → `70/30` → `50/50` → `0/100`) as confidence grows.

> **💡 Try it:** edit `02-quest1-fix.yaml`, change the weights to `50`/`50`,
> re-apply, and re-run the validation command to see the ratio shift.

---

## Quest 2 — Path-Based Routing Sends Traffic to the Wrong Service

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The ingress gateway routes `/cart` and `/orders` to their matching services.
A copy-paste mistake in the `/orders` rule means it still points at `cart`.
</details>

### 💥 Break it

```bash
kubectl apply -f 03-quest2-break.yaml
```

### 🔍 Diagnose

**Step 1 — Port-forward to the ingress gateway (run in its own terminal):**

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

**Step 2 — In a second terminal, hit `/orders`:**

```bash
curl -s http://localhost:8080/orders
```

> **🚨 Expected:** `cart ok` — wrong service entirely.

**Step 3 — Confirm `/cart` works correctly (it's not a total outage):**

```bash
curl -s http://localhost:8080/cart
```

> **✅ Expected:** `cart ok` — correct, which tells you the gateway itself is
> fine and the bug is specific to the `/orders` rule.

**Step 4 — Inspect the routing rule directly:**

```bash
kubectl get virtualservice shop-routes -n shop -o yaml
```

> Look at the `/orders` match block's `destination.host` — it says `cart`.

### 🛠️ Fix it

```bash
kubectl apply -f 03-quest2-fix.yaml
```

### ✅ Validate

```bash
curl -s http://localhost:8080/orders
```

> **✅ Expected:** `orders v1 ok`.

```bash
curl -s http://localhost:8080/cart
```

> **✅ Expected:** `cart ok` — still correct, confirming the fix didn't break the other route.

Stop the port-forward with `Ctrl+C` when done.

---

## Quest 3 — A Slow Dependency Hangs the Whole Request Chain

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The payment provider starts responding slowly (simulated here with a fixed
5-second delay). With no timeout configured, every caller waits the full 5
seconds — tying up client threads and making the slowness contagious.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 04-quest3-slow-payment.yaml
```

### 🔍 Prove the problem

**Time a request to payment:**

```bash
kubectl exec -n shop client -- sh -c 'time curl -s -o /dev/null http://payment:8080/'
```

> **🚨 Expected:** `real` time is about `5s`. The caller has no way to give
> up early — it's fully at the mercy of the slow dependency.

### 🛠️ Apply the fix

```bash
kubectl apply -f 04-quest3-fix.yaml
```

### ✅ Validate

```bash
kubectl exec -n shop client -- sh -c 'time curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/'
```

> **✅ Expected:** `real` time is about `2s`, and the status code is `504`
> (Gateway Timeout). The caller now fails fast instead of hanging for 5
> seconds — a `504` at 2s is far better for the rest of the system than a
> success at 5s.

---

## Quest 4 — Transient Errors Become User-Facing Failures

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The `cart` backend has become flaky (simulated with a 40% fault-injection
rate). Without retries, every one of those transient failures reaches the
end user as a visible error.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 05-quest4-flaky-cart.yaml
```

### 🔍 Prove the problem

**Send 20 requests and count failures:**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080/; done | sort | uniq -c'
```

> **🚨 Expected:** roughly 8 out of 20 requests (≈40%) return `503`. Every
> one of those is a transient blip becoming a real, user-visible failure.

### 🛠️ Apply the fix

```bash
kubectl apply -f 05-quest4-fix.yaml
```

### ✅ Validate

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080/; done | sort | uniq -c'
```

> **✅ Expected:** far fewer `503`s — roughly 1 or 2 out of 20 (≈6%), matching
> the math: with a 40% failure rate and 3 attempts, the odds of *all three*
> failing are `0.4³ ≈ 6%`. Retries don't eliminate the flakiness, they just
> stop most of it from reaching the user.

> **💡 Note:** Retries help with *transient* failures. They do not fix a
> genuinely broken backend — if every request fails, retrying 3 times just
> makes it fail 3 times slower.

---

## Quest 5 — Testing a New Version Safely With Real Traffic

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The team wants to see how `inventory-v2` behaves under real production
traffic patterns before trusting it with actual users — without risking a
single real response coming from the unvalidated version.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 06-quest5-inventory-v2.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=inventory,version=v2 -n shop --timeout=60s
```

### 🔍 Prove the problem

**Send a few requests and confirm only v1 ever answers:**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 5); do curl -s http://inventory:8080/; done'
```

> **✅ Expected (this part is fine):** all 5 responses are `inventory v1 ok`.
> The problem isn't a bad response — it's that **v2 has never seen a single
> real request**, so nobody knows how it behaves under real traffic until
> it's too late to matter.

**Confirm v2's logs are empty:**

```bash
kubectl logs -n shop -l app=inventory,version=v2 -c app --tail=20
```

> **🚨 Expected:** no log lines — v2 has handled zero requests.

### 🛠️ Apply the fix

```bash
kubectl apply -f 06-quest5-fix.yaml
```

### ✅ Validate

**Step 1 — Confirm users still only ever see v1 (mirroring is invisible to them):**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 5); do curl -s http://inventory:8080/; done'
```

> **✅ Expected:** all 5 responses are still `inventory v1 ok`. No user-facing
> change at all.

**Step 2 — Confirm v2 received a shadow copy of that same traffic:**

```bash
kubectl logs -n shop -l app=inventory,version=v2 -c app --tail=20
```

> **✅ Expected:** log lines now appear for `inventory-v2`, showing it
> received the mirrored requests — even though its responses were silently
> discarded and never reached the user.

---

## 🧹 Cleanup

```bash
kind delete cluster --name shopfast-tm
```

---

## 📎 Quick Reference

| Quest | Problem | Feature | Fix File |
|---|---|---|---|
| 1 | No control over rollout ratio | Weighted routing | `02-quest1-fix.yaml` |
| 2 | Path rule points at the wrong service | Path-based routing | `03-quest2-fix.yaml` |
| 3 | Slow dependency hangs every caller | Timeouts | `04-quest3-fix.yaml` |
| 4 | Transient errors reach the user | Retries | `05-quest4-fix.yaml` |
| 5 | No safe way to test a new version | Traffic mirroring | `06-quest5-fix.yaml` |

**🎓 Exam tip:** For the Istio Certified Associate exam, know the difference
between **retries** (same request, tried again, user still waits) and
**mirroring** (a copy of the request, user never waits on it) — they're
often confused but solve very different problems.
