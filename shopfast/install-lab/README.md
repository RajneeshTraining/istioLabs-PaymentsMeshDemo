# ⚙️ ShopFast — Installation, Upgrade & Configuration Lab

Five real operational mistakes teams make while installing, upgrading, and
configuring Istio — and the exact fix for each. Same loop as the other labs:

> **💥 Set the scene → 🔍 Prove the problem → 🛠️ Apply the fix → ✅ Validate**

Every `kubectl` and `istioctl` command is a **single command** — run each
one, read its output, and know exactly what it proved before moving on.

> **⚠️ Heads-up:** unlike the other ShopFast labs, this one reinstalls and
> reconfigures the Istio control plane itself in Quests 1 and 3. Use a
> throwaway cluster you don't mind tearing down at the end.

---

## 📖 Table of Contents

- [Prerequisites](#-prerequisites)
- [Setup](#-setup)
- [🗂️ Concepts at a Glance](#️-concepts-at-a-glance)
- [Quest 1 — Wrong Install Profile Leaves Out the Ingress Gateway](#quest-1--wrong-install-profile-leaves-out-the-ingress-gateway)
- [Quest 2 — Enabling Injection Doesn't Touch Already-Running Pods](#quest-2--enabling-injection-doesnt-touch-already-running-pods)
- [Quest 3 — Canary Control Plane Upgrade](#quest-3--canary-control-plane-upgrade)
- [Quest 4 — Broken Config That Kubernetes Happily Accepts](#quest-4--broken-config-that-kubernetes-happily-accepts)
- [Quest 5 — Oversized Sidecar Resource Requests Block Scheduling](#quest-5--oversized-sidecar-resource-requests-block-scheduling)
- [Cleanup](#-cleanup)
- [Quick Reference](#-quick-reference)

---

## ✅ Prerequisites

| Tool | Needed for |
|---|---|
| `kind` or `minikube` | The cluster |
| `kubectl` | Applying manifests, reading pods/events |
| `istioctl` | Install, upgrade, `analyze` |
| ~4 GB free RAM | The demo/minimal profiles |

---

## 🚀 Setup

> **📁 This lab installs Istio itself as part of Quest 1 — don't
> pre-install it. Just create the empty cluster.**

**1. Create the cluster**

```bash
kind create cluster --name shopfast-install
```

**2. Confirm it's up**

```bash
kubectl get nodes
```

> **✅ Expected:** one node, `Ready`.

Head straight to Quest 1 — it does the first Istio install for you. 🎯

---

## 🗂️ Concepts at a Glance

| Term | What it means |
|---|---|
| **Profile** | A named preset of components (`minimal`, `default`, `demo`, etc.) |
| **IstioOperator** | The CRD used to declare exactly what to install |
| **Revision** | A version tag (e.g. `stable`, `canary`) letting two control planes run side by side |
| **`istio-injection` label** | The old, single-revision way to opt a namespace into injection |
| **`istio.io/rev` label** | The revision-aware way — pins a namespace to a specific control plane |
| **`istioctl analyze`** | Static validation that catches config the Kubernetes API server won't |

---

## Quest 1 — Wrong Install Profile Leaves Out the Ingress Gateway

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

A new cluster gets Istio installed with the `minimal` profile — it sounds
like the safe, lightweight default. It is: it installs only `istiod`. No
ingress gateway comes with it, which means there is no supported way to get
external traffic into the mesh at all.
</details>

### 💥 Break it (install with the minimal profile)

```bash
istioctl install -f 01-quest1-iop-minimal.yaml -y
```

### 🔍 Diagnose

**Step 1 — See what actually got installed:**

```bash
kubectl get pods -n istio-system
```

> **🚨 Expected:** only `istiod-*` pods. No `istio-ingressgateway`.

**Step 2 — Confirm there's no ingress gateway Service to route through:**

```bash
kubectl get svc -n istio-system
```

> **🚨 Expected:** no `istio-ingressgateway` entry — there is nothing to
> `port-forward` to, and no `EXTERNAL-IP` to point DNS at.

### 🛠️ Fix it

```bash
istioctl install -f 01-quest1-iop-fix.yaml -y
```

### ✅ Validate

```bash
kubectl get pods -n istio-system
```

> **✅ Expected:** `istio-ingressgateway-*` now appears alongside `istiod-*`,
> both `Running`.

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

> **✅ Expected:** the Service now exists, with ports `80` and `443` exposed.

> **💡 Note:** this fix layered the ingress gateway *on top of* the minimal
> profile via `components.ingressGateways`, instead of jumping to a much
> heavier profile like `demo`. Enable exactly what you need.

---

## Quest 2 — Enabling Injection Doesn't Touch Already-Running Pods

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The `shop` namespace was created and `frontend` was deployed before anyone
remembered to enable sidecar injection. The team fixes the oversight by
labeling the namespace — and is then confused when the pod *still* has no
sidecar.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 02-quest2-namespace.yaml
```

```bash
kubectl apply -f 02-quest2-frontend.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=frontend -n shop --timeout=60s
```

### 🔍 Prove the problem

**Step 1 — Confirm the pod has no sidecar:**

```bash
kubectl get pods -n shop -l app=frontend
```

> **🚨 Expected:** `1/1 Running` — app container only.

**Step 2 — "Fix" it the way most people try first — just label the namespace:**

```bash
kubectl label namespace shop istio-injection=enabled
```

**Step 3 — Check the pod again:**

```bash
kubectl get pods -n shop -l app=frontend
```

> **🚨 Expected:** still `1/1 Running`. This is the trap: the injection
> webhook only runs when a pod is **created**. Labeling the namespace
> changes nothing for pods that already exist.

### 🛠️ Apply the actual fix

```bash
kubectl rollout restart deployment frontend -n shop
```

```bash
kubectl wait --for=condition=Ready pod -l app=frontend -n shop --timeout=60s
```

### ✅ Validate

```bash
kubectl get pods -n shop -l app=frontend
```

> **✅ Expected:** `2/2 Running` — the sidecar is now present, because the
> restart re-created the pod through the (now-active) injection webhook.

> **💡 Rule of thumb:** enabling injection is a two-step operation —
> **label the namespace, then restart every existing workload in it.**
> `kubectl rollout restart deployment -n <namespace> --all` does this for
> every Deployment at once.

---

## Quest 3 — Canary Control Plane Upgrade

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The team wants to upgrade Istio without a risky in-place, all-at-once
control-plane swap. Istio's revision mechanism lets two control planes run
side by side, so workloads can be migrated gradually — but only if you
understand that **installing a new revision moves nothing by itself**.
</details>

### 🎬 Set the scene (install a "stable" revision, move `shop` onto it)

```bash
istioctl install --set revision=stable -y
```

```bash
kubectl label namespace shop istio-injection- istio.io/rev=stable
```

```bash
kubectl rollout restart deployment frontend -n shop
```

```bash
kubectl wait --for=condition=Ready pod -l app=frontend -n shop --timeout=60s
```

**Confirm `frontend` is running under the `stable` revision:**

```bash
kubectl get pod -n shop -l app=frontend -o jsonpath='{.items[0].metadata.annotations.istio\.io/rev}{"\n"}'
```

> **✅ Expected:** `stable`.

### 🔍 Prove the problem (install "canary" — does it move anything?)

```bash
istioctl install --set revision=canary -y
```

```bash
kubectl get pods -n istio-system
```

> **🚨 Expected:** you now see both `istiod-stable-*` and `istiod-canary-*`
> running. Two control planes exist side by side.

**Check what revision `frontend` is *actually* using — has anything changed?**

```bash
kubectl get pod -n shop -l app=frontend -o jsonpath='{.items[0].metadata.annotations.istio\.io/rev}{"\n"}'
```

> **🚨 Expected:** still `stable`. Installing `canary` created a second
> control plane, but not a single workload moved to it — every namespace is
> still pinned to whatever revision its `istio.io/rev` label says.

### 🛠️ Apply the fix (migrate `shop` onto the canary revision)

```bash
kubectl label namespace shop istio.io/rev=canary --overwrite
```

```bash
kubectl rollout restart deployment frontend -n shop
```

```bash
kubectl wait --for=condition=Ready pod -l app=frontend -n shop --timeout=60s
```

### ✅ Validate

```bash
kubectl get pod -n shop -l app=frontend -o jsonpath='{.items[0].metadata.annotations.istio\.io/rev}{"\n"}'
```

> **✅ Expected:** `canary`. The pod's sidecar is now injected and managed
> by the canary control plane.

**Once you're confident, complete the cutover by removing the old revision:**

```bash
istioctl uninstall --revision stable -y
```

```bash
kubectl get pods -n istio-system
```

> **✅ Expected:** only `istiod-canary-*` remains.

---

## Quest 4 — Broken Config That Kubernetes Happily Accepts

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

A `VirtualService` for `orders` is written with a typo — it routes to a
host called `checkout`, which doesn't exist. The Kubernetes API server
validates the YAML's *shape*, not whether `checkout` is a real service, so
the apply succeeds without a single warning.
</details>

### 🎬 Set the scene

```bash
kubectl apply -f 04-quest4-services.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=orders -n shop --timeout=60s
```

### 💥 Break it

```bash
kubectl apply -f 04-quest4-break.yaml
```

### 🔍 Diagnose

**Step 1 — Notice that `kubectl apply` reported success:**

> **🚨 Expected:** `virtualservice.networking.istio.io/orders-route created`
> — no error, no warning. This is the trap: a clean `apply` does not mean
> the config is correct.

**Step 2 — Run Istio's own config validator:**

```bash
istioctl analyze -n shop
```

> **🚨 Expected:** a warning similar to
> `Referenced host not found: "checkout"` — this is the check that catches
> what `kubectl apply` cannot.

### 🛠️ Fix it

```bash
kubectl apply -f 04-quest4-fix.yaml
```

### ✅ Validate

```bash
istioctl analyze -n shop
```

> **✅ Expected:** `✔ No validation issues found when analyzing namespace: shop.`

> **💡 Best practice:** run `istioctl analyze` as a pre-merge CI check on
> every PR that touches Istio config — catching this before `apply` is much
> cheaper than catching it in production traffic.

---

## Quest 5 — Oversized Sidecar Resource Requests Block Scheduling

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

Someone tries to guarantee the `payment-v2` sidecar plenty of headroom by
setting its CPU request explicitly — but types `"32"` (32 whole CPU cores)
instead of `"32m"` (32 millicores). No node in the cluster has that much
spare CPU, so the pod can never be scheduled.
</details>

### 💥 Break it

```bash
kubectl apply -f 05-quest5-break.yaml
```

### 🔍 Diagnose

**Step 1 — Check the pod's status:**

```bash
kubectl get pods -n shop -l app=payment-v2
```

> **🚨 Expected:** `Pending` — it never even starts.

**Step 2 — Check why:**

```bash
kubectl describe pod -n shop -l app=payment-v2
```

> **🚨 Expected:** an event like
> `Warning FailedScheduling ... Insufficient cpu` near the bottom.

**Step 3 — Confirm the annotation is the cause:**

```bash
kubectl get deployment payment-v2 -n shop -o jsonpath='{.spec.template.metadata.annotations}{"\n"}'
```

> **🚨 Expected:** `sidecar.istio.io/proxyCPU: "32"` — 32 full cores
> requested for the sidecar alone.

### 🛠️ Fix it

```bash
kubectl apply -f 05-quest5-fix.yaml
```

### ✅ Validate

```bash
kubectl wait --for=condition=Ready pod -l app=payment-v2 -n shop --timeout=60s
```

```bash
kubectl get pods -n shop -l app=payment-v2
```

> **✅ Expected:** `2/2 Running`.

---

## 🧹 Cleanup

```bash
kind delete cluster --name shopfast-install
```

---

## 📎 Quick Reference

| Quest | Problem | Concept | Fix File / Command |
|---|---|---|---|
| 1 | No ingress gateway after install | Profile + component selection | `01-quest1-iop-fix.yaml` |
| 2 | Injection label doesn't affect running pods | Injection lifecycle | `kubectl rollout restart` |
| 3 | New revision doesn't move any workloads | Canary control-plane upgrade | `istio.io/rev` label |
| 4 | Kubernetes accepts config Istio can't route | Static validation | `istioctl analyze` |
| 5 | Sidecar resource typo blocks scheduling | Resource sizing | `05-quest5-fix.yaml` |

**🎓 Exam tip:** For the Istio Certified Associate exam, know the difference
between `istio-injection=enabled` (single-revision, legacy) and
`istio.io/rev=<name>` (revision-aware) namespace labels — and remember that
neither one retroactively injects an already-running pod.
