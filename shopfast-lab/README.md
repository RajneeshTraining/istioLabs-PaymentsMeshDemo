# ShopFast Istio Security Lab

A hands-on lab for the Istio security blog. Every kubectl command is a single command. Run them in order.

## Folder contents

| File | Purpose |
|---|---|
| `00-namespace.yaml` | Creates `shop` with sidecar injection enabled |
| `00b-plain-namespace.yaml` | Creates `plain` with NO injection (simulates a plaintext client) |
| `01-services.yaml` | Deploys frontend, cart, orders, payment, inventory |
| `02-quest1-mtls-permissive.yaml` | Quest 1 step 1: PERMISSIVE mTLS |
| `02b-quest1-mtls-strict.yaml` | Quest 1 step 2: STRICT mTLS |
| `03-quest2-authz.yaml` | Quest 2: deny-all + identity-based allows |
| `04-quest3-jwt.yaml` | Quest 3: JWT validation on orders |
| `05-quest4-egress.yaml` | Quest 4: ServiceEntry for Stripe |
| `06-quest5-debug.yaml` | Quest 5: deliberately broken DENY policy |

## Prerequisites

- A Kubernetes cluster (kind or minikube)
- `kubectl`
- `istioctl` (matching version)
- About 4 GB free memory

---

## Step 0: Create the cluster and install Istio

```bash
kind create cluster --name shopfast
```

```bash
istioctl install --set profile=demo -y
```

```bash
kubectl get pods -n istio-system
```

Wait until the `istiod` and `istio-ingressgateway` pods show `Running`.

## Step 1: Create the namespaces

```bash
kubectl apply -f 00-namespace.yaml
```

```bash
kubectl apply -f 00b-plain-namespace.yaml
```

## Step 2: Deploy the services

```bash
kubectl apply -f 01-services.yaml
```

```bash
kubectl wait --for=condition=Ready pod --all -n shop --timeout=120s
```

```bash
kubectl get pods -n shop
```

**Expected:** every pod shows `2/2 READY`. The `2` means the app container plus the Envoy sidecar. If you see `1/1`, injection is not working. Check the namespace label with `kubectl get ns shop --show-labels`.

## Step 3: Create client pods (one per identity)

Each client pod runs under a specific service account, so its requests carry that identity. Create them one at a time:

```bash
kubectl run client-frontend -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"frontend"}}' -- sleep 3600
```

```bash
kubectl run client-cart -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"cart"}}' -- sleep 3600
```

```bash
kubectl run client-orders -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"orders"}}' -- sleep 3600
```

```bash
kubectl run client-payment -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"payment"}}' -- sleep 3600
```

```bash
kubectl run client-inventory -n shop --image=curlimages/curl --restart=Never --overrides='{"spec":{"serviceAccountName":"inventory"}}' -- sleep 3600
```

```bash
kubectl run client-plain -n plain --image=curlimages/curl --restart=Never -- sleep 3600
```

```bash
kubectl wait --for=condition=Ready pod/client-frontend -n shop --timeout=120s
```

```bash
kubectl get pods -n shop
```

**Expected:** `client-frontend` etc. show `2/2`. Confirm `client-plain` in the `plain` namespace shows `1/1` (no sidecar):

```bash
kubectl get pods -n plain
```

---

## Quest 1: Encrypt service-to-service traffic (mTLS)

### Baseline (before fix)

Confirm no PeerAuthentication exists:

```bash
kubectl get peerauthentication -n shop
```

**Expected:** `No resources found`.

Send a plaintext request from the sidecar-less client to `payment`:

```bash
kubectl exec -n plain client-plain -- curl -s -o /dev/null -w "%{http_code}\n" http://payment.shop.svc.cluster.local:8080/
```

**Expected:** `200`. Plaintext is accepted, so the problem exists.

### Fix (step 1: permissive)

```bash
kubectl apply -f 02-quest1-mtls-permissive.yaml
```

Confirm the sidecar-to-sidecar path still works:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/
```

**Expected:** `200`.

### Fix (step 2: strict)

```bash
kubectl apply -f 02b-quest1-mtls-strict.yaml
```

### Validate the fix

Plaintext client from outside the mesh should now be rejected:

```bash
kubectl exec -n plain client-plain -- curl -s -o /dev/null -w "%{http_code}\n" http://payment.shop.svc.cluster.local:8080/
```

**Expected:** `000` (connection rejected).

Mesh client should still succeed:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/
```

**Expected:** `200`.

---

## Quest 2: Restrict which services can call which

### Reset before starting

Remove the Quest 1 STRICT policy so the baseline is a clean, open mesh. (STRICT can stay; it does not affect these tests. Skip this step if you prefer.)

### Baseline (before fix)

Confirm no authorization policy exists:

```bash
kubectl get authorizationpolicy -n shop
```

**Expected:** `No resources found`.

Frontend calls inventory directly:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/
```

**Expected:** `200`. The frontend should not be allowed, but it is.

### Fix

```bash
kubectl apply -f 03-quest2-authz.yaml
```

### Validate the fix

Frontend to inventory should now be denied:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/
```

**Expected:** `403`.

Orders to inventory should be allowed:

```bash
kubectl exec -n shop client-orders -- curl -s -o /dev/null -w "%{http_code}\n" http://inventory:8080/
```

**Expected:** `200`.

Cart to payment with POST should be allowed:

```bash
kubectl exec -n shop client-cart -- curl -s -o /dev/null -w "%{http_code}\n" -X POST http://payment:8080/api/v1/charge
```

**Expected:** `200`.

Cart to payment with GET should be denied:

```bash
kubectl exec -n shop client-cart -- curl -s -o /dev/null -w "%{http_code}\n" http://payment:8080/api/v1/charge
```

**Expected:** `403`.

---

## Quest 3: Require a valid end-user JWT

### Reset before starting

Remove the Quest 2 policies, because `deny-all` would block orders before JWT rules are tested:

```bash
kubectl delete -f 03-quest2-authz.yaml
```

### Baseline (before fix)

Confirm no RequestAuthentication exists:

```bash
kubectl get requestauthentication -n shop
```

**Expected:** `No resources found`.

Request with no token:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/
```

**Expected:** `200`. No identity is checked.

Request with a fake token:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer fake.token.value" http://orders:8080/
```

**Expected:** `200`. The fake token is ignored.

### Fix

```bash
kubectl apply -f 04-quest3-jwt.yaml
```

### Validate the fix

Request with no token should be denied:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://orders:8080/
```

**Expected:** `403`. The AuthorizationPolicy requires a request principal.

Request with a fake token should be rejected:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer fake.token.value" http://orders:8080/
```

**Expected:** `401`. RequestAuthentication cannot verify the token.

**Note:** A valid token test requires an issuer you control, because `auth.shopfast.example.com` is a placeholder. Without one, you can validate the first two checks only.

---

## Quest 4: Restrict outbound traffic

### Reset before starting

Remove the Quest 3 policies:

```bash
kubectl delete -f 04-quest3-jwt.yaml
```

### Baseline (before fix)

Check the outbound policy:

```bash
kubectl get configmap istio -n istio-system -o jsonpath='{.data.mesh}' | grep -i outboundTrafficPolicy -A2
```

**Expected:** no output, or `mode: ALLOW_ANY`. The default allows any destination.

Inventory calls an unregistered external host:

```bash
kubectl exec -n shop client-inventory -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
```

**Expected:** `200`. The pod reaches the internet.

### Fix (step 1: restrict the mesh)

```bash
istioctl install --set profile=demo --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY -y
```

### Fix (step 2: register the approved host)

```bash
kubectl apply -f 05-quest4-egress.yaml
```

### Validate the fix

Unregistered host should now be blocked:

```bash
kubectl exec -n shop client-inventory -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
```

**Expected:** `502` or `000`.

Registered host should still work from payment:

```bash
kubectl exec -n shop client-payment -- curl -s -o /dev/null -w "%{http_code}\n" https://api.stripe.com
```

**Expected:** a real HTTP status from Stripe (for example `200` or `401`). A `401` still proves the request reached Stripe.

---

## Quest 5: Diagnose a 403

### Reset before starting

Remove the Quest 4 ServiceEntry:

```bash
kubectl delete -f 05-quest4-egress.yaml
```

### Reproduce the failure

Apply the deliberately broken policy:

```bash
kubectl apply -f 06-quest5-debug.yaml
```

Send a request from frontend to cart:

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080/
```

**Expected:** `403`.

### Diagnose

Check the sidecar log for the RBAC denial:

```bash
kubectl logs -n shop -l app=cart -c istio-proxy --tail=50
```

Look for `RBAC: access denied`. That confirms an authorization policy caused the failure, not the application.

List the policies affecting cart:

```bash
istioctl x authz check $(kubectl get pod -n shop -l app=cart -o jsonpath='{.items[0].metadata.name}') -n shop
```

### Fix

Remove the broken policy:

```bash
kubectl delete -f 06-quest5-debug.yaml
```

### Validate the fix

```bash
kubectl exec -n shop client-frontend -- curl -s -o /dev/null -w "%{http_code}\n" http://cart:8080/
```

**Expected:** `200`.

---

## Cleanup

```bash
kubectl delete namespace plain
```

```bash
kind delete cluster --name shopfast
```

## Quick reference

| Quest | Problem | Fix file | Validation result |
|---|---|---|---|
| 1 | Plaintext traffic | `02b-quest1-mtls-strict.yaml` | Plaintext client gets `000` |
| 2 | Any service calls any service | `03-quest2-authz.yaml` | Frontend gets `403` on inventory |
| 3 | Unauthenticated user access | `04-quest3-jwt.yaml` | No token gets `403`, fake token gets `401` |
| 4 | Data exfiltration | `05-quest4-egress.yaml` | Unregistered host blocked |
| 5 | Unexplained 403 | Delete `06-quest5-debug.yaml` | Cart returns `200` |
