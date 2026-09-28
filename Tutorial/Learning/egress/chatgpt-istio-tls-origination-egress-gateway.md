# Istio TLS Origination on an Egress Gateway

## A Step-by-Step Learning Guide

> **Goal:** Learn how an Istio service mesh can allow application pods
> to make simple HTTP requests while a centralized **Egress Gateway**
> upgrades those requests to HTTPS before they leave the cluster.

------------------------------------------------------------------------

## 1. The Problem We Are Solving

Imagine an enterprise has 100 microservices running in Kubernetes.

Each microservice needs to call an external HTTPS service such as:

``` text
https://finance.yahoo.com
```

The application itself may be perfectly happy to make:

``` text
HTTP request
    |
    v
http://finance.yahoo.com
```

But the organization requires:

``` text
All traffic leaving the Kubernetes cluster
                    |
                    v
              MUST BE TLS
```

A simple solution is to configure TLS origination individually at every
application sidecar.

However, that creates an operational problem:

``` text
Pod A --> Sidecar --> TLS configuration
Pod B --> Sidecar --> TLS configuration
Pod C --> Sidecar --> TLS configuration
...
Pod N --> Sidecar --> TLS configuration
```

TLS-related configuration becomes distributed across many workloads.

### Centralized solution

Instead, let applications send ordinary HTTP requests inside the mesh
and make the **Istio Egress Gateway** responsible for creating the
external TLS connection.

``` text
Application
    |
    | HTTP
    v
Sidecar
    |
    | HTTP
    v
Egress Gateway
    |
    | HTTPS / TLS
    v
finance.yahoo.com
```

The important idea is:

> **TLS is originated at the Egress Gateway, not at every application
> pod.**

Istio's official documentation describes this pattern as combining
egress-gateway routing with TLS origination so that the TLS connection
to the external service is created by the egress gateway.\
Source:
https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/

------------------------------------------------------------------------

# 2. What Does "TLS Origination" Mean?

TLS origination means that the original application request is not
encrypted with TLS, but Istio creates a new TLS connection toward the
external destination.

Conceptually:

``` text
Application request

HTTP
GET /markets/crypto/all/
Host: finance.yahoo.com
        |
        v
+-------------------+
| Istio Egress      |
| Gateway            |
|                   |
| TLS Origination   |
+-------------------+
        |
        | HTTPS
        v
finance.yahoo.com
```

The gateway receives HTTP and creates a new HTTPS connection.

### Important terminology

**TLS termination**

``` text
Client -- HTTPS --> Gateway -- HTTP --> Backend
```

TLS is removed/terminated at the gateway.

**TLS origination**

``` text
Client -- HTTP --> Gateway -- HTTPS --> Backend
```

TLS is created/originated by the gateway.

For this tutorial we are implementing the second pattern.

------------------------------------------------------------------------

# 3. Target Architecture

Our example uses:

-   Application pod with an Istio sidecar
-   Istio Egress Gateway
-   External service: `finance.yahoo.com`
-   HTTP from application toward the gateway
-   HTTPS from the gateway toward Yahoo

## Architecture Diagram

``` text
                     Kubernetes Cluster
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Application Pod                                           │
│   ┌─────────────────────┐                                   │
│   │ Application         │                                   │
│   │ curl                │                                   │
│   └──────────┬──────────┘                                   │
│              │ HTTP :80                                      │
│              ▼                                               │
│   ┌─────────────────────┐                                   │
│   │ Istio Sidecar       │                                   │
│   │ Envoy               │                                   │
│   └──────────┬──────────┘                                   │
│              │                                               │
│              │ VirtualService                                │
│              │ routes to Egress Gateway                      │
│              ▼                                               │
│   ┌─────────────────────────────────┐                       │
│   │ Istio Egress Gateway            │                       │
│   │ Envoy                           │                       │
│   │                                 │                       │
│   │ TLS ORIGINATION                 │                       │
│   │ HTTP  ──────────────> HTTPS     │                       │
│   └───────────────┬─────────────────┘                       │
│                   │                                          │
└───────────────────┼──────────────────────────────────────────┘
                    │ HTTPS :443
                    ▼
          ┌───────────────────────┐
          │ finance.yahoo.com     │
          │ External Internet     │
          └───────────────────────┘
```

------------------------------------------------------------------------

# 4. The Four Main Istio Resources

This example uses four important Istio concepts:

``` text
                    External Service
                    finance.yahoo.com
                           ▲
                           │ HTTPS
                           │
                  ┌────────┴─────────┐
                  │ Egress Gateway   │
                  └────────▲─────────┘
                           │ HTTP
                           │
                  ┌────────┴─────────┐
                  │ Sidecar / Mesh   │
                  └────────▲─────────┘
                           │
                     Application
```

The configuration is built using:

  -----------------------------------------------------------------------
  Resource                            Purpose
  ----------------------------------- -----------------------------------
  `ServiceEntry`                      Tells Istio that
                                      `finance.yahoo.com` is an allowed
                                      external service

  `Gateway`                           Defines the listener on the Egress
                                      Gateway

  `VirtualService`                    Controls how traffic is routed to
                                      and from the Egress Gateway

  `DestinationRule` #1                Defines how mesh traffic reaches
                                      the Egress Gateway

  `DestinationRule` #2                Enables TLS origination toward
                                      Yahoo
  -----------------------------------------------------------------------

A useful mental model is:

``` text
ServiceEntry
     ↓
"Do I know this external service?"

Gateway
     ↓
"Where does the Egress Gateway listen?"

VirtualService
     ↓
"Where should this request go?"

DestinationRule #1
     ↓
"How does the sidecar connect to the Egress Gateway?"

DestinationRule #2
     ↓
"How does the Egress Gateway connect to Yahoo?"
```

------------------------------------------------------------------------

# 5. Before We Configure the Egress Gateway

First understand the baseline.

Suppose the application executes:

``` bash
curl -I http://finance.yahoo.com
```

If Istio is configured to restrict unknown external destinations, the
request can fail because Istio does not have a service definition for
the external host.

Conceptually:

``` text
Application
    |
    | HTTP
    v
Sidecar
    |
    | "I don't know this external host"
    X
  502
```

The important lesson is:

> **A Kubernetes pod being able to resolve a DNS name does not
> automatically mean Istio considers that external service part of its
> service registry.**

------------------------------------------------------------------------

# 6. Step 1 --- Create the ServiceEntry

A `ServiceEntry` adds an external service to Istio's service registry.

Create:

``` yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: finance-yahoo
spec:
  hosts:
  - finance.yahoo.com
  ports:
  - number: 80
    name: http
    protocol: HTTP
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
```

Apply it:

``` bash
kubectl apply -f service-entry.yaml
```

Verify:

``` bash
kubectl get serviceentry
```

You should see:

``` text
NAME             HOSTS
finance-yahoo    finance.yahoo.com
```

------------------------------------------------------------------------

# 7. What Has the ServiceEntry Actually Done?

At this point, Istio knows:

``` text
finance.yahoo.com
        |
        +---- port 80  HTTP
        |
        +---- port 443 HTTPS
```

But **traffic is not yet going through the Egress Gateway**.

This distinction is extremely important.

### Current flow

``` text
Application
     |
     v
Sidecar
     |
     | HTTP
     v
finance.yahoo.com
```

The Egress Gateway is not involved yet.

Istio's documentation demonstrates the same progression: first define
the external service and verify direct access, then configure the Egress
Gateway and routing.

------------------------------------------------------------------------

# 8. Verify the ServiceEntry

From an application/curl pod:

``` bash
curl -I http://finance.yahoo.com
```

You may see a redirect such as:

``` text
HTTP/1.1 301 Moved Permanently
location: https://finance.yahoo.com/markets/crypto/all/
```

Depending on Yahoo's current behavior, the exact response can vary.

The important point is:

``` text
502
```

has changed to a valid response such as:

``` text
301
```

This proves that Istio now recognizes and permits the external service.

------------------------------------------------------------------------

# 9. Step 2 --- Create the Egress Gateway

Now we create a Gateway resource that tells the Istio Egress Gateway:

> "For `finance.yahoo.com`, accept HTTP traffic on port 80."

``` yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: yahoo-egressgateway
spec:
  selector:
    istio: egressgateway

  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP

    hosts:
    - finance.yahoo.com
```

Apply:

``` bash
kubectl apply -f gateway.yaml
```

Verify:

``` bash
kubectl get gateway
```

------------------------------------------------------------------------

# 10. Why Does the Gateway Listen on HTTP Port 80?

This is one of the most important concepts in this example.

The application is sending:

``` text
HTTP :80
```

to the Egress Gateway.

The Egress Gateway will later create:

``` text
HTTPS :443
```

toward Yahoo.

Therefore:

``` text
Inside mesh                    Outside cluster

HTTP :80                       HTTPS :443
   │                               │
   ▼                               ▼
Sidecar ───────────────> Egress Gateway ───────────────> Yahoo
                              │
                              │
                         TLS Origination
```

Do not confuse:

``` text
Gateway listener port 80
```

with:

``` text
External destination port 443
```

They are intentionally different.

------------------------------------------------------------------------

# 11. Step 3 --- DestinationRule #1: Sidecar → Egress Gateway

For a clean enterprise configuration, define a DestinationRule for the
Egress Gateway service.

``` yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-yahoo
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local

  subsets:
  - name: yahoo

    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
```

Apply:

``` bash
kubectl apply -f destination-rule-egress-gateway.yaml
```

### Why do we need this DestinationRule?

It represents the first hop:

``` text
Sidecar
   |
   | HTTP :80
   v
Egress Gateway
```

It is useful to keep this policy separate from the policy that controls
TLS origination to the external service.

> **Think of this as the "inside the cluster" DestinationRule.**

------------------------------------------------------------------------

# 12. Step 4 --- DestinationRule #2: TLS Origination

Now configure the Egress Gateway to create an HTTPS connection to Yahoo.

``` yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-yahoo-com
spec:
  host: finance.yahoo.com

  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE
```

Apply:

``` bash
kubectl apply -f destination-rule-tls.yaml
```

This is the critical configuration.

``` text
tls:
  mode: SIMPLE
```

means:

> Create a normal TLS connection to the external service.

So the Egress Gateway performs:

``` text
HTTP
  ↓
TLS origination
  ↓
HTTPS
```

------------------------------------------------------------------------

# 13. Understanding the Two DestinationRules

This is an important exam/interview concept.

### DestinationRule #1

``` text
egressgateway-for-yahoo
```

Controls:

``` text
Sidecar
   |
   | HTTP
   v
Egress Gateway
```

### DestinationRule #2

``` text
originate-tls-for-yahoo-com
```

Controls:

``` text
Egress Gateway
   |
   | HTTPS
   v
finance.yahoo.com
```

Therefore:

``` text
                DestinationRule #1
                       │
                       ▼
Application → Sidecar ─────────→ Egress Gateway
                                      │
                                      │ DestinationRule #2
                                      │ TLS SIMPLE
                                      ▼
                              finance.yahoo.com
```

------------------------------------------------------------------------

# 14. Step 5 --- Create the VirtualService

The `VirtualService` connects the two routing stages.

``` yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-yahoo-through-egress-gateway

spec:
  hosts:
  - finance.yahoo.com

  gateways:
  - yahoo-egressgateway
  - mesh

  http:

  # Route 1:
  # Application/sidecar -> Egress Gateway
  - match:
    - gateways:
      - mesh
      port: 80

    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: yahoo
        port:
          number: 80

  # Route 2:
  # Egress Gateway -> External Yahoo
  - match:
    - gateways:
      - yahoo-egressgateway
      port: 80

    route:
    - destination:
        host: finance.yahoo.com
        port:
          number: 443
```

Apply:

``` bash
kubectl apply -f virtual-service.yaml
```

------------------------------------------------------------------------

# 15. The VirtualService Has Two Routing Rules

This is the heart of the configuration.

## Rule 1 --- Mesh → Egress Gateway

``` yaml
- match:
  - gateways:
    - mesh
    port: 80

  route:
  - destination:
      host: istio-egressgateway.istio-system.svc.cluster.local
      subset: yahoo
      port:
        number: 80
```

Meaning:

> If the request originates from the mesh and targets
> `finance.yahoo.com:80`, send it to the Egress Gateway.

Flow:

``` text
Application
     |
     | HTTP :80
     v
Sidecar
     |
     | VirtualService
     v
Egress Gateway :80
```

------------------------------------------------------------------------

## Rule 2 --- Egress Gateway → Yahoo

``` yaml
- match:
  - gateways:
    - yahoo-egressgateway
    port: 80

  route:
  - destination:
      host: finance.yahoo.com
      port:
        number: 443
```

Meaning:

> When the request has reached the Egress Gateway, forward it to Yahoo
> on port 443.

Flow:

``` text
Egress Gateway :80
       |
       | DestinationRule
       | tls.mode = SIMPLE
       v
finance.yahoo.com :443
```

------------------------------------------------------------------------

# 16. Complete Traffic Flow

Now put everything together.

``` text
┌────────────────────┐
│ Application Pod    │
│                    │
│ curl               │
└─────────┬──────────┘
          │
          │ HTTP :80
          ▼
┌────────────────────┐
│ Istio Sidecar      │
│ Envoy              │
└─────────┬──────────┘
          │
          │ VirtualService
          │ mesh → egress
          ▼
┌────────────────────────────┐
│ Istio Egress Gateway       │
│                            │
│ Listener: HTTP :80         │
└────────────┬───────────────┘
             │
             │ VirtualService
             │ destination :443
             │
             │ DestinationRule
             │ tls.mode = SIMPLE
             ▼
        TLS Handshake
             │
             │ HTTPS :443
             ▼
┌────────────────────────────┐
│ finance.yahoo.com          │
│ External Service            │
└────────────────────────────┘
```

------------------------------------------------------------------------

# 17. One-Line Mental Model

Remember this:

``` text
ServiceEntry
     ↓
Know the external service
     ↓
VirtualService
     ↓
Send traffic to Egress Gateway
     ↓
Egress Gateway
     ↓
DestinationRule: SIMPLE TLS
     ↓
HTTPS to external service
```

Or even shorter:

``` text
REGISTER → ROUTE → ORIGINATE
```

------------------------------------------------------------------------

# 18. What Happens to the Original HTTP Request?

Suppose the application executes:

``` bash
curl http://finance.yahoo.com/markets/crypto/all/
```

The application thinks it is making:

``` text
HTTP
```

The request reaches the sidecar:

``` text
HTTP
```

The sidecar routes it to:

``` text
Egress Gateway
```

The Egress Gateway creates a new connection:

``` text
HTTPS
```

Therefore:

``` text
Application
    |
    | HTTP
    |
    v
Sidecar
    |
    | HTTP
    |
    v
Egress Gateway
    |
    | HTTPS
    |
    v
Yahoo
```

There is no requirement for the application to implement TLS itself.

------------------------------------------------------------------------

# 19. Why This Is Useful in an Enterprise

Consider 500 microservices.

### Without centralized TLS origination

``` text
Service A → Sidecar → TLS configuration
Service B → Sidecar → TLS configuration
Service C → Sidecar → TLS configuration
Service D → Sidecar → TLS configuration
...
Service 500 → Sidecar → TLS configuration
```

This can increase operational complexity.

### With Egress Gateway

``` text
Service A ─┐
Service B ─┤
Service C ─┤
Service D ─┤
            ├──> Egress Gateway ──> HTTPS ──> External Services
Service 500─┘
```

TLS-related outbound policy can be concentrated at a controlled egress
point.

This can also provide a natural place for:

-   outbound traffic control
-   auditing
-   observability
-   security policy
-   destination allow-listing
-   centralized TLS policy
-   controlled Internet access

------------------------------------------------------------------------

# 20. Verification

Check all resources.

## ServiceEntry

``` bash
kubectl get serviceentry
```

Expected:

``` text
finance-yahoo
```

## Gateway

``` bash
kubectl get gateway
```

Expected:

``` text
yahoo-egressgateway
```

## DestinationRules

``` bash
kubectl get destinationrule
```

Expected resources similar to:

``` text
egressgateway-for-yahoo
originate-tls-for-yahoo-com
```

## VirtualService

``` bash
kubectl get virtualservice
```

Expected:

``` text
direct-yahoo-through-egress-gateway
```

------------------------------------------------------------------------

# 21. Test the Application Request

From your source pod:

``` bash
curl -v http://finance.yahoo.com/markets/crypto/all/
```

You should be able to observe a successful external request or redirect,
depending on Yahoo's current response behavior.

For example:

``` text
HTTP/1.1 301 Moved Permanently
location: https://finance.yahoo.com/markets/crypto/all/
```

If redirects are followed:

``` bash
curl -L -v http://finance.yahoo.com/markets/crypto/all/
```

You may eventually see an HTTPS response.

The exact HTTP response code/content from Yahoo is external-service
behavior and may change over time.

------------------------------------------------------------------------

# 22. How Do We Prove TLS Is Actually Originated at the Egress Gateway?

A successful HTTP response alone does not prove the gateway is doing TLS
origination.

Use Istio configuration inspection and Envoy information.

## Check Egress Gateway listeners

``` bash
istioctl proxy-config listeners \
  deploy/istio-egressgateway \
  -n istio-system
```

## Check clusters

``` bash
istioctl proxy-config clusters \
  deploy/istio-egressgateway \
  -n istio-system
```

Look for the external destination:

``` text
finance.yahoo.com
```

## Check routes

``` bash
istioctl proxy-config routes \
  deploy/istio-egressgateway \
  -n istio-system
```

## Check endpoint information

``` bash
istioctl proxy-config endpoints \
  deploy/istio-egressgateway \
  -n istio-system
```

These commands help determine whether the Egress Gateway received the
expected configuration from Istiod.

------------------------------------------------------------------------

# 23. Troubleshooting Guide

## Problem 1 --- 502 Bad Gateway

Possible causes:

``` text
ServiceEntry missing
        OR
VirtualService not matching
        OR
Gateway not selected
        OR
Egress Gateway service unavailable
```

Check:

``` bash
kubectl get serviceentry
kubectl get gateway
kubectl get virtualservice
kubectl get pods -n istio-system
```

------------------------------------------------------------------------

## Problem 2 --- ServiceEntry works, but Egress Gateway is bypassed

You may see:

``` text
301 Moved Permanently
```

but the request is still going directly to Yahoo.

Remember:

> `ServiceEntry` alone does NOT force traffic through the Egress
> Gateway.

You also need routing configuration.

Check:

``` bash
kubectl get virtualservice direct-yahoo-through-egress-gateway -o yaml
```

Verify that the VirtualService contains:

``` yaml
gateways:
- yahoo-egressgateway
- mesh
```

------------------------------------------------------------------------

# 24. Troubleshooting: Gateway Selector

The Gateway contains:

``` yaml
selector:
  istio: egressgateway
```

Therefore the selected Egress Gateway workload must have the matching
label.

Check:

``` bash
kubectl get pods -n istio-system --show-labels
```

Look for:

``` text
istio=egressgateway
```

If the selector does not match the workload, the Gateway configuration
will not be attached to the intended Envoy.

------------------------------------------------------------------------

# 25. Troubleshooting: VirtualService Has Two Matches

Do not accidentally remove either of these:

``` yaml
gateways:
- mesh
```

and:

``` yaml
gateways:
- yahoo-egressgateway
```

They represent two different traffic stages.

``` text
Stage 1
mesh
 |
 v
Egress Gateway

Stage 2
Egress Gateway
 |
 v
External Service
```

This is why the VirtualService contains two HTTP routes.

------------------------------------------------------------------------

# 26. Troubleshooting: TLS Origination Is Not Happening

Check the DestinationRule:

``` bash
kubectl get destinationrule originate-tls-for-yahoo-com -o yaml
```

You should have:

``` yaml
portLevelSettings:
- port:
    number: 443
  tls:
    mode: SIMPLE
```

The important setting is:

``` yaml
mode: SIMPLE
```

This tells Envoy to create a normal TLS connection.

------------------------------------------------------------------------

# 27. Common Conceptual Mistakes

### Mistake 1

> "ServiceEntry sends traffic through the Egress Gateway."

**Incorrect.**

ServiceEntry primarily makes the external service known/configurable to
Istio.

Routing through the Egress Gateway requires additional routing
configuration.

------------------------------------------------------------------------

### Mistake 2

> "Gateway port 80 means external traffic is HTTP."

**Incorrect.**

In this design:

``` text
Gateway listener
HTTP :80
```

but:

``` text
External destination
HTTPS :443
```

------------------------------------------------------------------------

### Mistake 3

> "`tls.mode: SIMPLE` means mutual TLS."

**Incorrect.**

``` text
SIMPLE
    = normal TLS

MUTUAL
    = mutual TLS

PASSTHROUGH
    = forward existing TLS without terminating/originating it
```

------------------------------------------------------------------------

### Mistake 4

> "TLS origination happens in the application."

**Incorrect for this design.**

The application sends:

``` text
HTTP
```

The Egress Gateway originates:

``` text
HTTPS
```

------------------------------------------------------------------------

# 28. Sidecar TLS Origination vs Egress Gateway TLS Origination

This distinction is useful for certification and architecture
discussions.

## Option A --- TLS origination at Sidecar

``` text
Application
    |
    | HTTP
    v
Sidecar
    |
    | TLS Origination
    |
    | HTTPS
    v
External Service
```

TLS policy is associated with the sidecar's outbound configuration.

## Option B --- TLS origination at Egress Gateway

``` text
Application
    |
    | HTTP
    v
Sidecar
    |
    | HTTP
    v
Egress Gateway
    |
    | TLS Origination
    |
    | HTTPS
    v
External Service
```

The second model introduces a centralized egress control point.

------------------------------------------------------------------------

# 29. Exam-Friendly Comparison

  Feature                                 Sidecar TLS Origination   Egress Gateway TLS Origination
  --------------------------------------- ------------------------- --------------------------------
  TLS created by                          Sidecar                   Egress Gateway
  Application changes                     Usually none              Usually none
  Centralized egress control              Lower                     Higher
  Dedicated egress hop                    No                        Yes
  External TLS policy location            Sidecar                   Egress Gateway
  Useful for controlled Internet egress   Possible                  Strong fit
  Central audit/control point             Less centralized          More centralized

------------------------------------------------------------------------

# 30. The Complete Configuration

For learning, it is useful to see the five logical pieces together.

## 1. ServiceEntry

``` yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: finance-yahoo
spec:
  hosts:
  - finance.yahoo.com
  ports:
  - number: 80
    name: http
    protocol: HTTP
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
```

## 2. Gateway

``` yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: yahoo-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - finance.yahoo.com
```

## 3. DestinationRule --- Sidecar → Egress Gateway

``` yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: egressgateway-for-yahoo
spec:
  host: istio-egressgateway.istio-system.svc.cluster.local
  subsets:
  - name: yahoo
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
```

## 4. DestinationRule --- Egress Gateway → Yahoo

``` yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: originate-tls-for-yahoo-com
spec:
  host: finance.yahoo.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE
```

## 5. VirtualService

``` yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: direct-yahoo-through-egress-gateway
spec:
  hosts:
  - finance.yahoo.com

  gateways:
  - yahoo-egressgateway
  - mesh

  http:

  - match:
    - gateways:
      - mesh
      port: 80

    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        subset: yahoo
        port:
          number: 80

  - match:
    - gateways:
      - yahoo-egressgateway
      port: 80

    route:
    - destination:
        host: finance.yahoo.com
        port:
          number: 443
```

------------------------------------------------------------------------

# 31. Visualizing the Configuration

A very useful way to remember the complete architecture is:

``` text
                    SERVICE ENTRY
                         │
                         │
              "finance.yahoo.com exists"
                         │
                         ▼
┌──────────────┐    HTTP :80    ┌───────────────────┐
│ Application  │ ─────────────> │ Istio Egress      │
│ + Sidecar    │                │ Gateway            │
└──────────────┘                │                   │
                                │ TLS Origination   │
                                └─────────┬─────────┘
                                          │
                                          │ HTTPS :443
                                          ▼
                                ┌───────────────────┐
                                │ finance.yahoo.com │
                                └───────────────────┘

      ↑                         ↑
      │                         │
VirtualService            DestinationRule
      │                         │
"route to gateway"        "TLS SIMPLE"
```

------------------------------------------------------------------------

# 32. The Three Questions You Should Ask Yourself

When troubleshooting this architecture, ask these questions in order.

### Question 1

**Does Istio know the external service?**

Check:

``` text
ServiceEntry
```

### Question 2

**Is the request actually being sent to the Egress Gateway?**

Check:

``` text
VirtualService
Gateway
Gateway selector
```

### Question 3

**Is the Egress Gateway creating HTTPS toward the external service?**

Check:

``` text
DestinationRule
tls.mode: SIMPLE
```

This gives you a very practical troubleshooting sequence:

``` text
        Is service known?
              │
              ▼
        ServiceEntry
              │
              ▼
       Is traffic routed?
              │
              ▼
       VirtualService
              │
              ▼
       Did it reach gateway?
              │
              ▼
      Gateway / Envoy config
              │
              ▼
      Is TLS originated?
              │
              ▼
 DestinationRule SIMPLE TLS
```

------------------------------------------------------------------------

# 33. Certification Memory Trick

Remember:

## **S-G-V-D-D**

``` text
S = ServiceEntry
G = Gateway
V = VirtualService
D = DestinationRule → Egress Gateway
D = DestinationRule → TLS Origination
```

Or remember the traffic story:

``` text
REGISTER
    ↓
SERVICE ENTRY

LISTEN
    ↓
GATEWAY

ROUTE
    ↓
VIRTUAL SERVICE

REACH GATEWAY
    ↓
DESTINATION RULE

ORIGINATE TLS
    ↓
DESTINATION RULE
```

------------------------------------------------------------------------

# 34. Final Mental Picture

If you remember only one diagram from this tutorial, remember this:

``` text
                  INSIDE MESH
┌───────────────────────────────────────────────┐
│                                               │
│  Application                                  │
│      │                                        │
│      │ HTTP                                   │
│      ▼                                        │
│  Sidecar                                      │
│      │                                        │
│      │ VirtualService                         │
│      ▼                                        │
│  Egress Gateway                               │
│      │                                        │
│      │ DestinationRule                        │
│      │ tls.mode = SIMPLE                      │
│      ▼                                        │
└──────┼────────────────────────────────────────┘
       │
       │ HTTPS / TLS
       ▼
┌───────────────────────────┐
│ External Service          │
│ finance.yahoo.com:443     │
└───────────────────────────┘
```

### The key principle

> **The application does not need to know that TLS is being originated.
> It sends HTTP; the centralized Egress Gateway converts the outbound
> connection into HTTPS.**

------------------------------------------------------------------------

# 35. Important Note About Istio Versions

Istio currently documents this scenario using both the **Istio
networking APIs** and the **Kubernetes Gateway API**. This tutorial
intentionally uses the Istio `ServiceEntry`, `Gateway`,
`VirtualService`, and `DestinationRule` resources because they make the
traffic flow easier to understand for learning and certification
purposes.

For newer Istio versions, always check the version-specific
documentation before applying production configuration because Gateway
API support and recommended configuration patterns continue to evolve.

Official reference:

https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/

------------------------------------------------------------------------

# 36. Quick Revision Cheat Sheet

``` text
PROBLEM
-------
Application sends HTTP
External service requires HTTPS


SOLUTION
--------
Application
    ↓ HTTP
Sidecar
    ↓ HTTP
Egress Gateway
    ↓ HTTPS
External Service


SERVICE ENTRY
-------------
Registers external service


GATEWAY
-------
Defines Egress Gateway listener


VIRTUAL SERVICE
---------------
Routes:
1. mesh → Egress Gateway
2. Egress Gateway → External Service


DESTINATION RULE #1
-------------------
Controls Sidecar → Egress Gateway


DESTINATION RULE #2
-------------------
Controls Egress Gateway → External Service

tls:
  mode: SIMPLE


FINAL FLOW
----------
HTTP
  ↓
Sidecar
  ↓
Egress Gateway
  ↓
TLS Origination
  ↓
HTTPS
  ↓
External Service
```

## Official Istio References

-   Egress Gateways with TLS Origination:
    https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/

-   Egress TLS Origination:
    https://istio.io/latest/docs/tasks/traffic-management/egress/egress-tls-origination/

-   Egress Gateways:
    https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/

---

# 37. Complex Practice Question 1 — Traffic Reaches the Egress Gateway but HTTPS Fails

## Scenario

You are running an Istio mesh with the intended architecture:

```text
Application → Sidecar → HTTP :80 → Egress Gateway → HTTPS :443 → api.partner.com
```

The `ServiceEntry`, Gateway, and VirtualService are correctly configured. The application executes:

```bash
curl -v http://api.partner.com
```

The request reaches the Egress Gateway, but the external call fails. You inspect the DestinationRule and find:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: partner-tls
spec:
  host: api.partner.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80
      tls:
        mode: SIMPLE
```

### Question

**What is the most likely configuration problem?**

**A.** The Gateway must listen on port 443 instead of port 80.

**B.** The `DestinationRule` must configure TLS on port 443, because the Egress Gateway connects to `api.partner.com:443`.

**C.** The ServiceEntry should contain only port 443.

**D.** The VirtualService must use `gateways: [mesh]` for both routes.

### Correct Answer

**B**

### Explanation

There are two separate hops:

```text
Application → Sidecar → HTTP :80 → Egress Gateway :80

Egress Gateway → TLS origination → HTTPS :443 → api.partner.com
```

The TLS policy therefore needs to apply to port `443`:

```yaml
portLevelSettings:
- port:
    number: 443
  tls:
    mode: SIMPLE
```

### Exam Trap

Do not confuse the Egress Gateway listener port with the external TLS destination port:

```text
Gateway listener       : 80 / HTTP
External destination   : 443 / HTTPS
```

---

# 38. Complex Practice Question 2 — Request Works but Bypasses the Egress Gateway

## Scenario

An organization requires all traffic from `payment-service` to `api.bank.example.com` to pass through the Istio Egress Gateway.

A `ServiceEntry` exists and the Egress Gateway is correctly installed. However, the following VirtualService is deployed:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: bank-egress
spec:
  hosts:
  - api.bank.example.com
  gateways:
  - mesh
  http:
  - match:
    - port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-system.svc.cluster.local
        port:
          number: 80
```

The application executes:

```bash
curl -v http://api.bank.example.com
```

The request succeeds, but monitoring shows that traffic is going directly to the external service instead of through the Egress Gateway.

### Question

**What is the most likely reason?**

**A.** A `ServiceEntry` cannot be used with an Egress Gateway.

**B.** The VirtualService only defines the mesh-side route and does not define the Egress-Gateway-side route to the external service.

**C.** The Egress Gateway must use TCP instead of HTTP.

**D.** TLS origination must be configured on the application pod.

### Correct Answer

**B**

### Explanation

An Egress Gateway flow has two routing stages:

```text
Stage 1
mesh → Egress Gateway

Stage 2
Egress Gateway → External Service
```

The VirtualService therefore needs to account for both stages, commonly with:

```yaml
gateways:
- mesh
- bank-egress
```

and separate matches such as:

```yaml
- match:
  - gateways:
    - mesh
    port: 80
  route:
  - destination:
      host: istio-egressgateway.istio-system.svc.cluster.local
      port:
        number: 80
```

followed by:

```yaml
- match:
  - gateways:
    - bank-egress
    port: 80
  route:
  - destination:
      host: api.bank.example.com
      port:
        number: 443
```

### Exam Trap

Remember:

```text
ServiceEntry
    ↓
Makes external service known

VirtualService
    ↓
Controls routing

Gateway
    ↓
Defines Egress Gateway listener

DestinationRule
    ↓
Controls TLS origination
```

A request succeeding does not by itself prove that it passed through the Egress Gateway.

---

# 39. Exam Reasoning Technique — Follow the Hops

For these questions, reason hop-by-hop:

```text
1. Where did the request originate?
        ↓
2. What host and port did the application request?
        ↓
3. Is that external host defined by ServiceEntry?
        ↓
4. Does VirtualService route mesh traffic to the Egress Gateway?
        ↓
5. Which Gateway receives the request?
        ↓
6. What port does the Egress Gateway use for the external service?
        ↓
7. Does DestinationRule apply TLS origination to that port?
```

For the standard HTTP → Egress Gateway → HTTPS pattern:

```text
Application
    │
    │ HTTP :80
    ▼
Sidecar
    │
    │ VirtualService
    ▼
Egress Gateway :80
    │
    │ DestinationRule
    │ tls.mode = SIMPLE
    ▼
External Service :443
```

## Fast Exam Rule

> **Never reason about the entire flow as one connection. Think in two connections: Sidecar → Egress Gateway, then Egress Gateway → External Service.**
