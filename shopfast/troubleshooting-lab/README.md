# 🔧 ShopFast — Istio Troubleshooting Lab

A hands-on lab for diagnosing the five Istio failures you'll hit most often in
production. Every problem follows the same loop:

> **💥 Break → 🔍 Diagnose → 🛠️ Fix → ✅ Validate**

Every `kubectl` command is a **single command** — nothing chained — so you can
run each one, read its output, and know exactly what it proved before moving on.

---

## 📖 Table of Contents

- [Prerequisites](#-prerequisites)
- [Setup](#-setup)
- [🩺 Envoy Flags Cheat Sheet](#-envoy-flags-cheat-sheet)
- [Quest 1 — Zero Endpoints (503 / UH)](#quest-1--zero-endpoints-503--uh)
- [Quest 2 — Sidecar Skipped Under STRICT mTLS (UC)](#quest-2--sidecar-skipped-under-strict-mtls-uc)
- [Quest 3 — Broken Canary Routing (No Healthy Upstream for Subset)](#quest-3--broken-canary-routing-no-healthy-upstream-for-subset)
- [Quest 4 — Circuit Breaking / Outlier Detection (UO)](#quest-4--circuit-breaking--outlier-detection-uo)
- [Quest 5 — Gateway Misrouting (404 at the Edge)](#quest-5--gateway-misrouting-404-at-the-edge)
- [Cleanup](#-cleanup)
- [Quick Reference](#-quick-reference)

---

## ✅ Prerequisites

| Tool | Needed for |
|---|---|
| `kind` or `minikube` | The cluster |
| `kubectl` | Applying manifests, reading pods/logs |
| `istioctl` | Install, `proxy-config`, `analyze` |
| ~4 GB free RAM | The demo profile |

---

## 🚀 Setup

> **📁 Do this once, in order. Confirm the "Expected" output before moving to the next command.**

**1. Create the cluster**

```bash
kind create cluster --name shopfast-ts
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

> **✅ Expected:** every pod shows `2/2 READY`. If any shows `1/1`, check that
> `shop` has the `istio-injection=enabled` label:
> `kubectl get ns shop --show-labels`

**8. Create a reusable in-mesh client pod**

```bash
kubectl run client -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- sleep 3600
```

```bash
kubectl wait --for=condition=Ready pod/client -n shop --timeout=60s
```

You're ready to begin. 🎯

---

## 🩺 Envoy Flags Cheat Sheet

Keep this open while you work — these are the response flags you'll see in
sidecar logs (`kubectl logs <pod> -c istio-proxy`) throughout this lab.

| Flag | Meaning | Usually points to |
|---|---|---|
| **UH** | No healthy upstream | Zero endpoints — bad selector, pod not ready |
| **UC** | Upstream connection termination | mTLS mismatch, sidecar missing, network policy |
| **UO** | Upstream overflow (circuit breaker) | Outlier detection ejected the host |
| **NR** | No route configured | VirtualService host/gateway mismatch |
| **NC** | No cluster found | DestinationRule/subset misconfigured |

---

## Quest 1 — Zero Endpoints (503 / UH)

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

A deploy changed the `inventory` Service's selector without anyone noticing.
The Deployment is healthy, but the Service now points at nothing.
</details>

### 💥 Break it

```bash
kubectl apply -f 02-problem1-break.yaml
```

### 🔍 Diagnose

**Step 1 — Check the Service's endpoints:**

```bash
kubectl get endpoints inventory -n shop
```

> **🚨 Expected:** the `ENDPOINTS` column is empty. A Service with no
> endpoints can't route anywhere — this alone is your root cause.

**Step 2 — Confirm the pods are actually healthy (it's not the pods):**

```bash
kubectl get pods -n shop -l app=inventory
```

> **✅ Expected:** the pod is `2/2 Running`. This proves the problem is the
> Service's selector, not the workload.

**Step 3 — Reproduce the failure from a client:**

```bash
kubectl exec -n shop client -- curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/
```

> **🚨 Expected:** `503`.

**Step 4 — Confirm the flag in the sidecar log:**

```bash
kubectl logs -n shop client -c istio-proxy --tail=5
```

> Look for `UH` in the response flags column.

### 🛠️ Fix it

```bash
kubectl apply -f 02-problem1-fix.yaml
```

### ✅ Validate

```bash
kubectl get endpoints inventory -n shop
```

> **✅ Expected:** the `ENDPOINTS` column now lists a pod IP.

```bash
kubectl exec -n shop client -- curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/
```

> **✅ Expected:** `200`.

---

## Quest 2 — Sidecar Skipped Under STRICT mTLS (UC)

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

A "legacy worker" pod was deployed with `sidecar.istio.io/inject: "false"`
— maybe to save resources, maybe by accident. Once the namespace enforces
STRICT mTLS, that pod can no longer talk to anything in the mesh.
</details>

### Setup

```bash
kubectl apply -f 03-problem2-mtls-strict.yaml
```

### 💥 Break it

```bash
kubectl apply -f 03-problem2-break.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=legacy-worker -n shop --timeout=60s
```

### 🔍 Diagnose

**Step 1 — Confirm the pod has no sidecar:**

```bash
kubectl get pods -n shop -l app=legacy-worker
```

> **🚨 Expected:** `1/1 Running` — only the app container, no `istio-proxy`.

**Step 2 — Reproduce the failure:**

```bash
kubectl exec -n shop deploy/legacy-worker -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 5 http://cart.shop.svc.cluster.local:8080/
```

> **🚨 Expected:** `000` — the connection is reset before any HTTP response,
> because STRICT mTLS refuses a plaintext client.

**Step 3 — Confirm it from the server side:**

```bash
kubectl logs -n shop -l app=cart -c istio-proxy --tail=10
```

> Look for a `UC` flag or an mTLS handshake failure around the time of your request.

### 🛠️ Fix it

```bash
kubectl apply -f 03-problem2-fix.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=legacy-worker -n shop --timeout=60s
```

### ✅ Validate

```bash
kubectl get pods -n shop -l app=legacy-worker
```

> **✅ Expected:** `2/2 Running` — the sidecar is now present.

```bash
kubectl exec -n shop deploy/legacy-worker -c app -- curl -s -o /dev/null -w "%{http_code}\n" http://cart.shop.svc.cluster.local:8080/
```

> **✅ Expected:** `200`.

---

## Quest 3 — Broken Canary Routing (No Healthy Upstream for Subset)

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

`inventory-v2` is being rolled out as a 50/50 canary. The `DestinationRule`
subset for `v2` has a typo in its label selector, so it matches nothing —
half your traffic has nowhere to go.
</details>

### Setup

```bash
kubectl apply -f 04-problem3-inventory-v2.yaml
```

```bash
kubectl wait --for=condition=Ready pod -l app=inventory,version=v2 -n shop --timeout=60s
```

### 💥 Break it

```bash
kubectl apply -f 04-problem3-break.yaml
```

### 🔍 Diagnose

**Step 1 — Send several requests and look for failures:**

```bash
kubectl exec -n shop client -- sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/; done'
```

> **🚨 Expected:** a mix of `200` and `503` — roughly half the requests fail,
> matching the 50% weight sent to the broken subset.

**Step 2 — Inspect the subset configuration directly:**

```bash
kubectl get destinationrule inventory -n shop -o yaml
```

> Compare the `v2` subset's `labels` against the actual pod labels — you'll
> spot the mismatch (`version2` vs `v2`).

**Step 3 — Confirm the real pod label:**

```bash
kubectl get pods -n shop -l app=inventory --show-labels
```

> **🚨 Expected:** the v2 pod is labeled `version=v2`, not `version=version2`.

### 🛠️ Fix it

```bash
kubectl apply -f 04-problem3-fix.yaml
```

### ✅ Validate

```bash
kubectl exec -n shop client -- sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/; done'
```

> **✅ Expected:** all `200`s.

```bash
kubectl exec -n shop client -- sh -c 'for i in 1 2 3 4 5 6; do curl -s http://inventory:8080/; done'
```

> **✅ Expected:** a mix of `inventory v1 ok` and `inventory v2 ok` responses,
> confirming both subsets now receive traffic.

---

## Quest 4 — Circuit Breaking / Outlier Detection (UO)

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

One of the two `payment` pods starts failing intermittently (simulated here
with fault injection). Without outlier detection, Envoy keeps sending it
traffic at full rate, and every client eats the errors.
</details>

### 💥 Break it (simulate a flaky pod)

```bash
kubectl apply -f 05-problem4-fault-injection.yaml
```

### 🔍 Diagnose

**Step 1 — Confirm no DestinationRule exists yet:**

```bash
kubectl get destinationrule payment -n shop
```

> **🚨 Expected:** `Error from server (NotFound)` — no resilience policy is configured.

**Step 2 — Send repeated requests and watch the failure rate:**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/; done'
```

> **🚨 Expected:** roughly 6 out of 10 requests return `500`, matching the
> 60% fault-injection rate. Nothing is protecting clients from this.

### 🛠️ Fix it

```bash
kubectl apply -f 05-problem4-fix.yaml
```

### ✅ Validate

**Step 1 — Re-run the same burst of requests:**

```bash
kubectl exec -n shop client -- sh -c 'for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/; done'
```

> **✅ Expected:** after the first few `500`s, the flaky host gets ejected and
> your success rate improves — you should see mostly `200`s again as traffic
> shifts to the healthy endpoint.

**Step 2 — Confirm the ejection directly in the proxy stats:**

```bash
kubectl exec -n shop client -- curl -s http://localhost:15000/clusters 2>/dev/null | grep payment | grep outlier_detection
```

> **✅ Expected:** a nonzero `outlier_detection.ejections_active` or
> `ejections_total` counter, proving the circuit breaker fired.

> **💡 Note:** Leave the fault injection running — this Quest validates
> *resilience*, not the absence of failures. The goal is that clients stop
> seeing them, not that the flaky pod stops existing.

---

## Quest 5 — Gateway Misrouting (404 at the Edge)

<details>
<summary><strong>📋 The scenario</strong> (click to expand)</summary>

The `frontend` is being exposed externally through the Istio Ingress
Gateway. The `Gateway` resource's selector has a typo, so it never binds to
the real ingress pods — every external request gets a 404.
</details>

### 💥 Break it

```bash
kubectl apply -f 06-problem5-break.yaml
```

### 🔍 Diagnose

**Step 1 — Find the ingress gateway's external address:**

```bash
kubectl get svc istio-ingressgateway -n istio-system
```

> Note the `EXTERNAL-IP` (or use `kubectl port-forward` if it's `<pending>`,
> see below).

**Step 2 — Port-forward to the gateway for local testing:**

```bash
kubectl port-forward -n istio-system svc/istio-ingressgateway 8080:80
```

> Leave this running in its own terminal.

**Step 3 — In a second terminal, send a request:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/
```

> **🚨 Expected:** `404`.

**Step 4 — Check which pods the Gateway actually selects:**

```bash
kubectl get pods -n istio-system --show-labels
```

> **🚨 Expected:** the real ingress pod is labeled `istio=ingressgateway`,
> but the `Gateway` resource in `06-problem5-break.yaml` selects `istio: ingress`
> — no pod matches, so the Gateway has no listener to bind to.

### 🛠️ Fix it

```bash
kubectl apply -f 06-problem5-fix.yaml
```

### ✅ Validate

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/
```

> **✅ Expected:** `200`.

```bash
curl -s http://localhost:8080/
```

> **✅ Expected:** `frontend ok`.

When you're done, stop the port-forward with `Ctrl+C` in its terminal.

---

## 🧹 Cleanup

```bash
kind delete cluster --name shopfast-ts
```

---

## 📎 Quick Reference

| Quest | Symptom | Flag | Root Cause | Fix File |
|---|---|---|---|---|
| 1 | 503 on every request | `UH` | Service selector matches no pods | `02-problem1-fix.yaml` |
| 2 | `000` / connection reset | `UC` | Sidecar injection disabled under STRICT mTLS | `03-problem2-fix.yaml` |
| 3 | ~50% of requests 503 | `UH` (subset) | DestinationRule subset label typo | `04-problem3-fix.yaml` |
| 4 | Elevated 5xx rate | `UO` | No outlier detection configured | `05-problem4-fix.yaml` |
| 5 | 404 at the edge | `NR` | Gateway selector doesn't match ingress pods | `06-problem5-fix.yaml` |

**🎓 Exam tip:** For the Istio Certified Associate exam, memorize the Envoy
flags table above — questions frequently describe a symptom (a status code
and a flag) and ask you to name the misconfiguration.
