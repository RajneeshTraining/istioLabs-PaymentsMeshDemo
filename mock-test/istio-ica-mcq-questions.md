# Istio Certified Associate (ICA) — Practice MCQs
## Scenario: Payment Mesh Demo

These multiple-choice questions reuse the same `payment-mesh` scenario (gateway, order-service, payment-service v1/v2/v3, fraud-detection-service, testing-pod) so you can practice reasoning about a system you've already built manifests for. Each question has exactly one correct answer unless stated otherwise. Answer key is at the end — try answering before looking.

---

**Q1.** In the baseline `payment-mesh-all-in-one.yaml`, `payment-service` v1, v2, and v3 all share a single ServiceAccount. What is the direct consequence of this for Istio `AuthorizationPolicy` design?

A. Traffic splitting between versions will not work correctly
B. mTLS cannot be enabled for `payment-service`
C. A policy cannot distinguish "allow only v2/v3" from "allow all payment-service versions" based on identity alone
D. `DestinationRule` subsets cannot be created for this service

---

**Q2.** After labeling the `payment-mesh` namespace with `istio-injection: enabled`, existing pods still show `1/1 Ready` instead of `2/2`. What is the correct explanation?

A. The label was applied to the wrong namespace
B. Istio's sidecar injector webhook only mutates pod specs at pod **creation** time; existing pods must be recreated
C. `istio-injection: enabled` only works with automatic sidecar injection disabled
D. The Deployments need `imagePullPolicy: Always` for injection to take effect

---

**Q3.** You define a `VirtualService` with a header-match route for `x-canary: v3` listed **after** a weighted default route (v1/v2 70/30) in the `http:` array. What happens?

A. Istio merges both rules and applies the header match with higher precedence automatically
B. The weighted route always wins because Istio evaluates rules top-to-bottom and stops at the first match
C. This produces an invalid VirtualService rejected by `istioctl analyze`
D. Traffic is split three ways evenly among v1, v2, and v3

---

**Q4.** Which resource in Istio is responsible for defining named subsets of a Service based on pod labels, so a `VirtualService` can route to them individually?

A. `Gateway`
B. `ServiceEntry`
C. `DestinationRule`
D. `Sidecar`

---

**Q5.** You enable `outlierDetection` on the `payment-service` `DestinationRule` with `consecutive5xxErrors: 3`. A specific pod (payment-service v3) starts returning 5xx due to a chaos flag. What is the immediate effect once the threshold is hit?

A. The pod is deleted by Istio
B. The specific endpoint is temporarily ejected from the load-balancing pool for `baseEjectionTime`
C. All requests to `payment-service` are rejected with 503 until the Deployment is restarted
D. Istio automatically scales up a replacement pod

---

**Q6.** What is the primary difference between a retry policy's `perTryTimeout` and a route's overall `timeout`?

A. They are the same setting expressed in two APIs
B. `perTryTimeout` bounds each individual attempt; `timeout` bounds the total time across all attempts combined
C. `timeout` only applies to the first attempt; `perTryTimeout` applies to retries only
D. `perTryTimeout` is deprecated in favor of `timeout`

---

**Q7.** A `PeerAuthentication` resource named `default` with no `selector`, created in the `payment-mesh` namespace, sets `mtls.mode: STRICT`. What is its scope?

A. It applies only to a workload literally named "default"
B. It has no effect until a selector is added
C. It applies mesh-wide, cluster-wide, regardless of namespace
D. It applies as the namespace-wide default policy for every workload in `payment-mesh` that has no more specific PeerAuthentication

---

**Q8.** After applying an `AuthorizationPolicy` with `action: ALLOW` selecting `order-service`, listing only the `gateway` ServiceAccount as an authorized source, what happens to a request from `testing-pod` (ServiceAccount `default`)?

A. It is allowed, because ALLOW policies are additive and don't restrict other traffic
B. It is denied — once any ALLOW policy selects a workload, all non-matching traffic to that workload is implicitly denied
C. It is allowed only if mTLS is disabled
D. `AuthorizationPolicy` cannot use `principals`; it only supports IP-based rules

---

**Q9.** Which command would you run first to identify configuration issues in a `VirtualService` that references a misspelled destination host, before checking runtime behavior?

A. `kubectl logs`
B. `istioctl proxy-status`
C. `istioctl analyze`
D. `kubectl describe service`

---

**Q10.** In the baseline manifest, `testing-pod` deliberately runs under the `default` ServiceAccount rather than a dedicated one. Why is this useful for a certification lab?

A. It is required for `kubectl exec` to function
B. It provides a caller with no explicit identity/authorization grant, letting you demonstrate default-deny behavior under `AuthorizationPolicy`
C. It disables mTLS for that specific pod
D. It allows the pod to bypass all Istio Gateway routing rules

---

**Q11.** A `Gateway` resource defines `hosts: ["payment.mesh.local"]` on port 80. A client sends a request to the ingress IP with no `Host` header matching that value. What is the expected result, assuming no wildcard host is configured?

A. The request is routed to the first VirtualService found in the namespace
B. The request receives `404 Not Found` from the ingress gateway, since no matching virtual host exists
C. The request is automatically routed based on source IP
D. The Gateway resource itself becomes invalid

---

**Q12. (Multiple correct answers — select all that apply)** Which of the following are valid fields inside a `VirtualService` `http[].retries` block?

A. `attempts`
B. `perTryTimeout`
C. `retryOn`
D. `consecutive5xxErrors`

---

**Q13.** Which statement correctly distinguishes `DestinationRule` outlier detection from `VirtualService` retries as resiliency mechanisms?

A. They solve the same problem and using both together is redundant and unsupported
B. Retries mask individual failed requests by re-attempting them; outlier detection stops routing to a consistently unhealthy endpoint over time — they are complementary, not redundant
C. Outlier detection only works for gRPC traffic
D. Retries require mTLS to be enabled; outlier detection does not

---

**Q14.** Where should a namespace-wide `STRICT` `PeerAuthentication` typically be combined with permissive rollout, in a production migration scenario, to avoid breaking traffic from services not yet updated to speak mTLS?

A. It cannot be combined with anything; STRICT must be applied all at once
B. By starting with `mode: PERMISSIVE` (accepting both plaintext and mTLS) before switching to STRICT once all clients are confirmed to be meshed
C. By disabling sidecar injection during the migration
D. By applying `AuthorizationPolicy` with `action: DENY` for all traffic first

---

**Q15.** You need `fraud-detection-service` to accept calls only from `payment-service`, not from `gateway` or `order-service` directly. Which field in the `AuthorizationPolicy` rule captures this constraint?

A. `spec.selector.matchLabels`, targeting `fraud-detection-service`, combined with `spec.rules[].from[].source.principals` listing only the `payment-service` ServiceAccount
B. `spec.action: DENY` with no rules
C. A `NetworkPolicy`, since `AuthorizationPolicy` cannot filter by caller identity
D. `spec.rules[].to[].operation.hosts`

---

## Answer Key

| Q | Answer | Why |
|---|---|---|
| 1 | C | Shared identity across versions means principal-based policies can't distinguish which version is calling. |
| 2 | B | Injection is a mutating admission webhook; it only fires on pod creation. |
| 3 | B | Istio VirtualService `http` rules are evaluated in order; first match wins. |
| 4 | C | `DestinationRule.spec.subsets` defines named, label-selected subsets. |
| 5 | B | Outlier detection ejects the offending endpoint for `baseEjectionTime`, not the whole service or pod. |
| 6 | B | `perTryTimeout` bounds one attempt; `timeout` bounds the whole request lifecycle including retries. |
| 7 | D | A `PeerAuthentication` named `default` with no selector sets the namespace-wide default. |
| 8 | B | ALLOW-policy presence switches the workload to default-deny for anything not explicitly matched. |
| 9 | C | `istioctl analyze` is the static-validation tool; it catches this before you'd need to check logs/runtime status. |
| 10 | B | It represents an "unauthorized caller" persona for testing default-deny behavior. |
| 11 | B | No matching virtual host on the Gateway listener means no route — default is 404. |
| 12 | A, B, C | `attempts`, `perTryTimeout`, and `retryOn` are all valid retry fields; `consecutive5xxErrors` belongs to `DestinationRule` outlier detection, not retries. |
| 13 | B | They operate at different layers/timescales and are meant to be used together. |
| 14 | B | `PERMISSIVE` mode is the standard incremental-migration path to `STRICT`. |
| 15 | A | Selector + `from.source.principals` is the standard identity-based authorization pattern. |
