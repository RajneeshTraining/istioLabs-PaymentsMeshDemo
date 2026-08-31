# Istio 1.26 ICA Remedial Labs
### Targeting: Troubleshooting · Securing Workloads · Installation, Upgrades & Configuration

**Important version note before you start**

Istio 1.26 no longer has an *in-cluster Operator controller*. The `IstioOperator` CRD reconciled by a running `istio-operator` Deployment was deprecated in 1.23 and removed in 1.24 — it cannot be used to install or upgrade 1.26 at all. Real 1.26 exam questions will **not** ask you to `kubectl apply` an `IstioOperator` resource and wait for an operator to reconcile it.

What **is** still valid in 1.26, and what these labs use exclusively:
- `istioctl install --set profile=<name>` — the `profile=` **flag** is alive and well; it's only the CRD-based Operator *controller* that's gone. `istioctl` renders the manifest client-side and applies it directly, no in-cluster watcher involved.
- Helm installation (`istio-base`, `istiod`, gateway charts) with a `profile:` value — the production-recommended path.
- Revision-based canary upgrades (`istioctl install --set revision=...`), which are unaffected by the operator deprecation and are the expected upgrade mechanism.

Every lab below is written and solved against `istioctl`/Helm only.

---

## Domain 1 — Installation, Upgrades, and Configuration

### Lab 1.1 — Customized install + validating the render before it touches the cluster

**Scenario**
You're handed a fresh 3-node cluster (Kubernetes 1.30) and told to install Istio 1.26 with the following requirements:
- Start from the `demo` profile.
- Access logging must be enabled to stdout.
- Pilot (istiod) must run 2 replicas minimum, with CPU request raised to `500m`.
- The change must be reviewable (diffed) *before* anything is applied to the cluster.
- After install, prove no in-cluster Operator component exists (since it's deprecated/removed).

**Tasks**
1. Produce a manifest diff/preview of a customized install based on `demo`, without touching the cluster.
2. Apply the customized install.
3. Verify control plane health and versions.
4. Verify no `IstioOperator` CRD or `istio-operator` Deployment exists.

**Solution**

Step 1 — build an IstioOperator-style overlay file (this is just a YAML input to `istioctl`, not a CRD you apply to the cluster):

```yaml
# overlay.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: demo
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    pilot:
      k8s:
        replicaCount: 2
        resources:
          requests:
            cpu: 500m
```

Step 2 — dry-run / diff it before applying anything:

```bash
istioctl manifest generate -f overlay.yaml > generated-manifest.yaml
istioctl manifest diff generated-manifest.yaml <(istioctl manifest generate --set profile=demo)
```

Step 3 — install for real (client-side render + apply, no in-cluster operator involved):

```bash
istioctl install -f overlay.yaml -y
```

Step 4 — verify:

```bash
kubectl get pods -n istio-system
istioctl version
kubectl get deploy -n istio-system istiod -o jsonpath='{.spec.replicas}'   # expect 2
```

Step 5 — prove no Operator remnants:

```bash
kubectl get deployment -n istio-system istio-operator          # expect: NotFound
kubectl get crd istiooperators.install.istio.io                # expect: NotFound (unless you never had one)
```

If either exists from a pre-1.24 cluster, the cluster is **not upgrade-safe to 1.26** until you migrate: `istioctl operator remove`, delete the CRD, then re-install via `istioctl`/Helm.

---

### Lab 1.2 — Zero-downtime canary (revision-based) upgrade from 1.25 to 1.26

**Scenario**
Production is running Istio 1.25 with the `default` profile. You must upgrade to 1.26 with **zero traffic disruption**, verify new-vs-old proxy versions coexist safely, migrate one namespace's workloads onto the new control plane, then finish the upgrade and clean up the old revision.

**Tasks**
1. Install 1.26 control plane as a *named revision*, side-by-side with the existing 1.25 default install.
2. Move a specific namespace's workloads to the new revision without editing every Deployment by hand.
3. Restart workloads so sidecars actually pick up the new proxy version.
4. Confirm both data-plane versions are compatible during the transition.
5. Once validated, make 1.26 the default and remove the old revision.

**Solution**

Step 1 — install the new revision (this does **not** touch the existing `istiod` that's serving `istio-injection=enabled` namespaces):

```bash
istioctl install --set revision=1-26-0 --set profile=default -y
kubectl get pods -n istio-system -l app=istiod
# you should see both istiod (old, default) and istiod-1-26-0 running
```

Step 2 — check version skew is within the supported N-1 range before routing any workload to it:

```bash
istioctl x precheck
istioctl proxy-status
```

Step 3 — retag (or label) the target namespace to use the new revision instead of the default injector:

```bash
kubectl label namespace payments istio-injection- --overwrite
kubectl label namespace payments istio.io/rev=1-26-0 --overwrite
```

Step 4 — roll the workloads so they pick up the new sidecar (label alone does not restart running pods):

```bash
kubectl rollout restart deployment -n payments
kubectl get pods -n payments -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | grep proxyv2
```

Step 5 — confirm the mesh is healthy with mixed control planes (old namespaces still on 1.25, `payments` on 1.26):

```bash
istioctl proxy-status
istioctl analyze -A
```

Step 6 — once every namespace has been migrated, promote 1.26 to be the default revision and delete the old one:

```bash
istioctl install --set revision=1-26-0 --set revisionTags[0]=default -y
istioctl x uninstall --revision <old-1.25-revision> -y
```

**Common exam trap:** using `kubectl label` on the *namespace* alone is not enough — pods already running keep their existing sidecar until you `rollout restart`. Also, skipping `istioctl x precheck`/`proxy-status` before cutting traffic is a frequently-tested mistake.

---

## Domain 2 — Securing Workloads

### Lab 2.1 — Enforcing mesh-wide STRICT mTLS with one namespace exception, plus deny-by-default authorization

**Scenario**
Namespace `prod` runs `frontend`, `backend`, and `reviews` services (all sidecar-injected). Security wants:
- Mesh-wide mTLS to be STRICT by default.
- One legacy service, `legacy-ingester` in namespace `legacy` (no sidecar yet), must still be able to talk to `backend` in plaintext.
- `backend` should only be reachable by `frontend`'s service account, and only on port 8080 with GET.
- Everything else must be denied by default.

**Tasks**
1. Set mesh-wide STRICT mTLS.
2. Carve out a workload-level PERMISSIVE exception for `backend` so `legacy-ingester` can still call it in plaintext (until it gets a sidecar).
3. Write an AuthorizationPolicy that implements default-deny plus the one explicit allow rule described.
4. Verify with `istioctl x authz check` / `openssl s_client`.

**Solution**

Step 1 — mesh-wide STRICT PeerAuthentication (goes in the root/`istio-system` namespace, applies to everything without a more specific override):

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

Step 2 — workload-level override so `backend` alone accepts both plaintext and mTLS while `legacy-ingester` gets a sidecar:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: backend-permissive
  namespace: prod
spec:
  selector:
    matchLabels:
      app: backend
  mtls:
    mode: PERMISSIVE
```
More specific (workload-selector) PeerAuthentication always wins over namespace or mesh-wide policy — this is the key rule the exam is testing.

Step 3 — default-deny + one explicit allow, scoped to the `backend` workload:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: prod
spec: {}          # empty spec + no selector = deny all in this namespace
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backend-allow-frontend
  namespace: prod
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/prod/sa/frontend"]
    to:
    - operation:
        methods: ["GET"]
        ports: ["8080"]
```

Note: an empty-spec `AuthorizationPolicy` with no selector switches the **entire namespace** to deny-by-default for every workload in it (not just `backend`) — that satisfies "everything else denied," including calls to `frontend` and `reviews` from anywhere not explicitly allowed. If `frontend`/`reviews` need their own traffic, add matching ALLOW policies for them too.

Step 4 — verify:

```bash
# Confirm mTLS mode observed by the sidecar
istioctl x describe pod backend-xxxx -n prod

# Confirm the policy chain applying to backend
istioctl x authz check backend-xxxx.prod

# From legacy-ingester (no sidecar) - should succeed in plaintext only if it also
# satisfies the AuthorizationPolicy identity check, which it *cannot* since it has
# no verifiable principal. This is the trap: PERMISSIVE mTLS alone does not bypass
# AuthorizationPolicy identity requirements.
```

**Exam trap:** PERMISSIVE mTLS only relaxes the *transport* requirement (plaintext is accepted). It does **not** grant `legacy-ingester` a verifiable principal, so an AuthorizationPolicy that matches on `source.principals` will still reject it. For a genuinely plaintext, unauthenticated caller you must add it via `notPrincipals`/`ipBlocks`/`namespaces` rather than `principals`, e.g. `source: { ipBlocks: ["10.20.0.0/16"] }`, or exempt the path from AuthorizationPolicy scope while accepting the reduced identity guarantee.

---

### Lab 2.2 — End-user JWT authentication plus claim-based authorization at the ingress and a downstream service

**Scenario**
External users hit `api-gateway` (via the ingress Gateway) with a JWT issued by `https://auth.example.com`. Requirements:
- Requests to `/orders` must present a valid JWT from that issuer; requests without one are rejected at the gateway, not passed through.
- Only tokens containing `"role": "admin"` in a custom claim may call `DELETE /orders/{id}`.
- `orders-service` (internal, mTLS-only) must still independently enforce that only `api-gateway`'s service account can reach it — defense in depth, not just gateway-level trust.

**Tasks**
1. Configure `RequestAuthentication` for JWT validation at the ingress workload.
2. Force JWT to be **required** (Istio's default `RequestAuthentication` behavior is opportunistic, not enforcing).
3. Add claim-based `AuthorizationPolicy` restricting `DELETE` to admins.
4. Add a workload-identity `AuthorizationPolicy` on `orders-service` restricting callers to `api-gateway`'s SA only.

**Solution**

Step 1 — validate JWTs at the gateway workload:

```yaml
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-auth
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  jwtRules:
  - issuer: "https://auth.example.com"
    jwksUri: "https://auth.example.com/.well-known/jwks.json"
```

Step 2 — this alone only *validates* JWTs presented; requests with **no** token still pass RequestAuthentication (they're just "unauthenticated," not rejected). You must explicitly require an authenticated principal with an AuthorizationPolicy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: DENY
  rules:
  - from:
    - source:
        notRequestPrincipals: ["*"]
    to:
    - operation:
        paths: ["/orders*"]
```
`notRequestPrincipals: ["*"]` matches "no verified JWT principal at all," so this DENY rule blocks any unauthenticated call to `/orders*` while leaving other paths untouched.

Step 3 — claim-based restriction for the destructive method:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: orders-delete-admin-only
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  action: ALLOW
  rules:
  - from:
    - source:
        requestPrincipals: ["https://auth.example.com/*"]
    to:
    - operation:
        methods: ["DELETE"]
        paths: ["/orders/*"]
    when:
    - key: request.auth.claims[role]
      values: ["admin"]
```
Remember this is an ALLOW rule — if any other ALLOW policy on this workload also matches DELETE without the claim check, it will override the restriction (Istio ORs multiple ALLOW policies together). Keep the DELETE path scoped to a single, narrow ALLOW policy, or use `action: DENY` with a `when.notValues` claim check instead if other broader ALLOW rules exist.

Step 4 — defense-in-depth at the internal service, independent of gateway JWT trust:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: orders-service-allow-gateway
  namespace: prod
spec:
  selector:
    matchLabels:
      app: orders-service
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account"]
```

Step 5 — verify:

```bash
curl -i https://api.example.com/orders            # expect 403 (no token)
curl -i -H "Authorization: Bearer <valid-non-admin-jwt>" https://api.example.com/orders -X DELETE  # expect 403
curl -i -H "Authorization: Bearer <valid-admin-jwt>" https://api.example.com/orders/123 -X DELETE  # expect 200/204
istioctl x authz check ingressgateway-xxxx.istio-system
```

**Exam trap:** candidates frequently forget that `RequestAuthentication` alone never rejects unauthenticated traffic — that's always an `AuthorizationPolicy` job (`notRequestPrincipals: ["*"]`). This exact gap is one of the most common ICA failure points.

---

## Domain 3 — Troubleshooting

### Lab 3.1 — Diagnosing intermittent 503s (`UC` / upstream connect failures) after a DestinationRule change

**Scenario**
`reviews` service has 3 subsets (`v1`, `v2`, `v3`) defined via `DestinationRule`, routed 90/10 canary via `VirtualService` from `v1` to `v2`. After someone edits the `DestinationRule`, clients start seeing intermittent `503` with response flag `UC` in the access logs, only for the `v2` subset.

**Tasks**
1. Confirm the failure is happening at the client-side (Envoy) layer, not the app.
2. Identify which config generation is broken using `istioctl analyze` and `proxy-config`.
3. Find the actual mismatch causing Envoy to have no healthy endpoints for the `v2` cluster.
4. Fix it and confirm resolution.

**Solution**

Step 1 — `UC` in Envoy access logs = "upstream connection termination" (i.e., Envoy tried to open a connection to the upstream cluster and failed before getting a response) — this points to a routing/cluster/endpoint problem, not application logic. Confirm:

```bash
kubectl logs -n prod deploy/reviews-v1 -c istio-proxy | grep 'UC' | tail -20
```

Step 2 — run the static analyzer first, it catches most config-drift issues instantly:

```bash
istioctl analyze -n prod
```
(If it flags nothing, the break may be a label mismatch that the analyzer doesn't fully catch — proceed manually.)

Step 3 — check whether Envoy actually has a cluster and healthy endpoints for the `v2` subset:

```bash
POD=$(kubectl get pod -n prod -l app=reviews,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config cluster $POD.prod --fqdn reviews.prod.svc.cluster.local -o json
istioctl proxy-config endpoint $POD.prod --cluster "outbound|9080|v2|reviews.prod.svc.cluster.local"
```
If the endpoint list is **empty**, Envoy has a cluster defined but no member pods matched — that's a label selector mismatch, most commonly caused by editing the `DestinationRule` subset labels to something that no longer matches the actual pod labels on the `reviews-v2` Deployment.

Step 4 — compare the DestinationRule subset selector against real pod labels:

```bash
kubectl get pods -n prod -l app=reviews --show-labels
kubectl get destinationrule reviews -n prod -o yaml
```
Typical bug found: the subset was edited to `version: v2-canary` but the Deployment's pods are still labeled `version: v2`.

Step 5 — fix (align the subset label to the real pod label) and confirm:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews
  namespace: prod
spec:
  host: reviews.prod.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2      # corrected from v2-canary
  - name: v3
    labels:
      version: v3
```

```bash
kubectl apply -f destinationrule-reviews.yaml
istioctl proxy-config endpoint $POD.prod --cluster "outbound|9080|v2|reviews.prod.svc.cluster.local"
# expect: non-empty endpoint list now
istioctl analyze -n prod
```

**Exam trap:** candidates often chase mTLS or network-policy causes for `UC` errors. Always check the endpoint list (`istioctl proxy-config endpoint`) before assuming it's a security issue — an empty endpoint list is a routing/selector bug, not TLS. If mTLS *were* the cause you'd instead see the cluster with endpoints present but connections failing at the TLS handshake, which shows up differently (`UF` or `UAEX` flags, or `503` with reason "TLS error" in verbose Envoy logs).

---

### Lab 3.2 — VirtualService/Gateway host mismatch causing "no healthy upstream" at the ingress

**Scenario**
A new `VirtualService` for `api.example.com` was deployed. `curl` from outside the cluster to `https://api.example.com/v1/status` returns `404` from the Istio ingress gateway itself (Envoy's own 404, not the app's). Other hosts on the same shared ingress Gateway continue to work fine.

**Tasks**
1. Confirm whether the ingress gateway even has a route for this host, versus a downstream endpoint problem.
2. Find the exact mismatch between `Gateway` and `VirtualService`.
3. Fix and re-verify at the Envoy config level, not just via `curl`.

**Solution**

Step 1 — an Envoy-generated 404 (as opposed to a 503) at the ingress almost always means "no route matched this `Host` header at all" — i.e., a `Gateway`/`VirtualService` binding problem, not a backend/endpoint problem. Confirm by checking the gateway's known routes:

```bash
ISTIO_INGRESS=$(kubectl get pod -n istio-system -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config routes $ISTIO_INGRESS.istio-system --name http.8080 -o json
# or for HTTPS listeners:
istioctl proxy-config listeners $ISTIO_INGRESS.istio-system --port 443 -o json
```

Step 2 — look for whether `api.example.com` appears in the listener's routable domains at all:

```bash
istioctl proxy-config routes $ISTIO_INGRESS.istio-system -o json | grep -A5 'api.example.com'
```
If nothing comes back, the `VirtualService` is not actually attached to this `Gateway`. Check both objects:

```bash
kubectl get gateway -n istio-system main-gateway -o yaml
kubectl get virtualservice -n prod api-vs -o yaml
```
Typical bug found: the `Gateway` exposes `hosts: ["*.example.com"]` under a server named `https-main`, but the `VirtualService`'s `gateways:` field references `main-gateway` using the wrong namespace-qualified name (Gateways referenced cross-namespace must be `<namespace>/<gateway-name>`), so Istio silently drops the binding — no error is thrown, the route is just never attached.

Step 3 — fix the reference:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: api-vs
  namespace: prod
spec:
  hosts:
  - "api.example.com"
  gateways:
  - "istio-system/main-gateway"     # corrected: namespace/name form
  http:
  - match:
    - uri:
        prefix: /v1
    route:
    - destination:
        host: api-backend.prod.svc.cluster.local
        port:
          number: 8080
```

Step 4 — re-verify at both the config and traffic level:

```bash
kubectl apply -f api-vs.yaml
istioctl proxy-config routes $ISTIO_INGRESS.istio-system -o json | grep -A5 'api.example.com'
istioctl analyze -A
curl -i https://api.example.com/v1/status     # expect real app response, not Envoy 404
```

**Exam trap:** a `VirtualService` referencing a `Gateway` in another namespace without the `namespace/name` prefix produces **no validation error** and no obvious log line — Istio just never binds the route. This is one of the highest-yield "silent failure" scenarios on the troubleshooting section, and `istioctl analyze` catches it (`SchemaWarning`/`referenced gateway not found`) far more reliably than reading logs, so always run it early in any routing-failure investigation.

---

## Quick command reference used across these labs

| Purpose | Command |
|---|---|
| Static config validation | `istioctl analyze -A` |
| Pre-upgrade compatibility check | `istioctl x precheck` |
| Proxy sync status | `istioctl proxy-status` |
| Effective Envoy cluster | `istioctl proxy-config cluster <pod>.<ns> --fqdn <svc>` |
| Effective Envoy endpoints | `istioctl proxy-config endpoint <pod>.<ns> --cluster <cluster-name>` |
| Effective Envoy routes | `istioctl proxy-config routes <pod>.<ns>` |
| Effective Envoy listeners | `istioctl proxy-config listeners <pod>.<ns>` |
| Authz policy applying to a workload | `istioctl x authz check <pod>.<ns>` |
| Human-readable workload summary (mTLS, policies, routes) | `istioctl x describe pod <pod> -n <ns>` |
| Manifest preview (no cluster changes) | `istioctl manifest generate -f overlay.yaml` |
| Diff two manifests | `istioctl manifest diff <a>.yaml <b>.yaml` |
