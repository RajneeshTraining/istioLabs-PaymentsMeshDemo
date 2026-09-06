These manifests combine **three very important ICA exam concepts**:

1. **Mesh-wide STRICT mTLS using `PeerAuthentication`**
2. **Ingress Gateway TLS termination using `Gateway`**
3. **TLS origination to an external HTTPS service using `ServiceEntry` + `DestinationRule`**

There is also an exam-worthy subtlety here: the external service is exposed logically as **HTTP on port 80**, but `targetPort: 443` plus `DestinationRule` TLS origination causes Istio to establish TLS to the external endpoint.

Below are **4 practical, exam-style labs**—one based directly on your manifests and three new scenarios testing similar concepts from different angles.

---

# Lab 1 — Secure the Mesh and Expose an HTTPS Application

### Difficulty: ⭐⭐⭐⭐ ICA Exam Style

## Scenario

You are operating a Kubernetes application called `order-service`. The security team has mandated the following:

* All service-to-service communication inside the Istio mesh must use **mutual TLS**.
* Clients must access the application through an Istio Ingress Gateway using:
  `https://app.example.com`
* TLS must be terminated at the Istio Ingress Gateway.
* The backend application itself should continue receiving normal HTTP traffic.
* The application also needs to call an external HTTPS API:
  `api.external.com`
* The application should be able to call the external API using:

```text
http://api.external.com
```

but Istio must transparently establish TLS with the external server on port `443`.

### Your Task

Configure Istio to satisfy all requirements.

You must create:

* A mesh-wide `PeerAuthentication`
* An Istio `Gateway`
* A `ServiceEntry`
* A `DestinationRule`

### Expected Architecture

```text
                         INTERNET
                            |
                            | HTTPS :443
                            | app.example.com
                            v
                  +----------------------+
                  | Istio IngressGateway |
                  | TLS TERMINATION      |
                  +----------+-----------+
                             |
                             | HTTP
                             v
                     +---------------+
                     | order-service  |
                     +-------+-------+
                             |
                             | HTTP :80
                             v
                     Istio Sidecar
                             |
                             | TLS ORIGINATION
                             | HTTPS :443
                             v
                   api.external.com
```

### Important Exam Requirements

The candidate must ensure:

```text
Ingress:
Client HTTPS → Gateway TLS termination → HTTP backend

Egress:
Application HTTP → Istio TLS origination → External HTTPS
```

### Concepts Tested

| Concept                      | Tested |
| ---------------------------- | ------ |
| `PeerAuthentication`         | ✅      |
| STRICT mTLS                  | ✅      |
| Root namespace configuration | ✅      |
| Gateway HTTPS                | ✅      |
| `tls.mode: SIMPLE`           | ✅      |
| `credentialName`             | ✅      |
| TLS termination              | ✅      |
| `ServiceEntry`               | ✅      |
| `DestinationRule`            | ✅      |
| TLS origination              | ✅      |
| `targetPort`                 | ✅      |
| SNI                          | ✅      |

---

# Lab 2 — Troubleshoot a Broken HTTPS Ingress

### Difficulty: ⭐⭐⭐⭐⭐ ICA Exam Style

This one is closer to the type of **troubleshooting-oriented certification question** I would strongly recommend practicing.

## Scenario

A team has deployed an online payment application.

The following resources already exist:

```text
payment.example.com
        |
        | HTTPS :443
        v
Istio Ingress Gateway
        |
        | HTTP
        v
payment-service
```

The application is accessible over HTTP internally, but users receive:

```text
503 Service Unavailable
```

when accessing:

```text
https://payment.example.com
```

The security team also reports that some internal workloads cannot communicate with `payment-service`.

You discover the following requirements:

1. The mesh must use STRICT mTLS.
2. External HTTPS traffic must terminate TLS at the Gateway.
3. Traffic from Gateway to the application should be HTTP.
4. The TLS certificate is stored in secret:

```text
payment-tls
```

5. The Gateway should only accept:

```text
payment.example.com
```

### Your Task

Configure or correct the Istio resources so that:

```text
HTTPS client
     |
     | TLS
     v
Ingress Gateway
     |
     | TLS termination
     v
HTTP payment-service
```

and:

```text
service A
    |
    | mTLS
    v
payment-service
```

### Candidate Must Determine

The candidate should identify and correctly configure:

* `PeerAuthentication`
* Gateway selector
* HTTPS server
* `credentialName`
* Gateway host
* TLS termination mode
* backend routing
* compatibility between STRICT mTLS and Gateway traffic

### Suggested Verification

The candidate should prove:

```bash
istioctl analyze
```

and:

```bash
kubectl get gateway -A
kubectl get peerauthentication -A
kubectl get secret -A
```

Then test:

```bash
curl -vk https://payment.example.com
```

### Exam Traps

This lab intentionally tests whether you understand the difference between:

```yaml
tls:
  mode: SIMPLE
```

and:

```yaml
tls:
  mode: PASSTHROUGH
```

The candidate must understand:

> **SIMPLE = Gateway terminates TLS**

whereas:

> **PASSTHROUGH = Gateway does not terminate TLS.**

---

# Lab 3 — HTTP-to-HTTPS TLS Origination for an External API

### Difficulty: ⭐⭐⭐⭐⭐ ICA Exam Style

This is an especially good lab because it tests a configuration that initially looks contradictory.

## Scenario

Your application `report-service` has been written to call:

```text
http://secure-api.partner.com
```

The application cannot be modified.

However, the external partner has recently changed its security policy and now requires:

```text
HTTPS :443
```

The application still needs to use:

```text
http://secure-api.partner.com
```

The Istio platform team wants Istio to transparently perform TLS origination.

### Required Behavior

Application:

```text
report-service
       |
       | HTTP :80
       v
Istio Sidecar
       |
       | TLS origination
       | HTTPS :443
       v
secure-api.partner.com
```

The application must **not** be changed.

### Your Task

Create the appropriate:

```text
ServiceEntry
DestinationRule
```

such that:

```text
http://secure-api.partner.com
```

from the application results in:

```text
TLS/HTTPS → secure-api.partner.com:443
```

### Required Configuration Characteristics

Your configuration should model:

```yaml
ServiceEntry
    |
    +-- host: secure-api.partner.com
    +-- logical port: 80
    +-- protocol: HTTP
    +-- targetPort: 443
    +-- location: MESH_EXTERNAL
```

and use a `DestinationRule` to configure:

```yaml
tls:
  mode: SIMPLE
  sni: secure-api.partner.com
```

### Candidate Verification

Deploy a test client:

```bash
kubectl run curl \
  --image=curlimages/curl \
  --restart=Never \
  --command -- sleep 3600
```

Inject the Istio sidecar into the namespace and execute:

```bash
curl -v http://secure-api.partner.com
```

Then inspect the Envoy configuration:

```bash
istioctl proxy-config clusters <pod> -n <namespace>
```

and:

```bash
istioctl proxy-config endpoints <pod> -n <namespace>
```

### Key ICA Concepts

This lab tests whether the candidate understands:

```text
ServiceEntry
    ↓
Makes external service known to Istio

DestinationRule
    ↓
Controls traffic policy

TLS SIMPLE
    ↓
Istio originates TLS

SNI
    ↓
Identifies the external TLS virtual host
```

### Important Exam Trap

Do **not** confuse:

```yaml
Gateway
  tls:
    mode: SIMPLE
```

with:

```yaml
DestinationRule
  trafficPolicy:
    tls:
      mode: SIMPLE
```

They both say `SIMPLE`, but they perform **different jobs**.

| Configuration            | Meaning                |
| ------------------------ | ---------------------- |
| Gateway `SIMPLE`         | Terminate incoming TLS |
| DestinationRule `SIMPLE` | Originate outgoing TLS |

That distinction is highly exam-worthy.

---

# Lab 4 — Mixed Security: STRICT mTLS + TLS Passthrough + External TLS Origination

### Difficulty: ⭐⭐⭐⭐⭐⭐ Advanced ICA Practice

This is the lab I would use as the **final challenge**.

## Scenario

Your organization operates an `inventory.example.com` application.

Security requirements are:

### Internal traffic

All workload-to-workload traffic must use:

```text
STRICT mTLS
```

### External traffic

The application is exposed through:

```text
https://inventory.example.com
```

However, the backend application—not the Istio Gateway—owns the TLS certificate and must perform TLS termination.

Therefore:

```text
Client
  |
  | HTTPS
  v
Istio Gateway
  |
  | HTTPS
  v
inventory-service
```

The Gateway must **not terminate TLS**.

### External API

The application also calls:

```text
http://warehouse.partner.com
```

The partner requires HTTPS:

```text
warehouse.partner.com:443
```

The application cannot be modified.

Therefore Istio must perform TLS origination.

---

# Your Task

Configure the complete traffic-security architecture.

You need to implement:

### 1. Mesh security

Configure:

```text
PeerAuthentication
```

so that workload-to-workload communication is:

```text
STRICT mTLS
```

### 2. Ingress

Configure a Gateway that accepts:

```text
inventory.example.com:443
```

but **does not terminate TLS**.

### 3. Internal routing

Forward the encrypted connection to:

```text
inventory-service
```

without decrypting it at the Gateway.

### 4. External API

Allow:

```text
http://warehouse.partner.com
```

from workloads while Istio transparently originates:

```text
HTTPS :443
```

### Expected Architecture

```text
                         CLIENT
                           |
                           |
                     HTTPS :443
                           |
                           v
                +---------------------+
                | Istio Gateway       |
                | PASSTHROUGH         |
                +----------+----------+
                           |
                           | HTTPS
                           |
                           v
                  +----------------+
                  | inventory      |
                  | service        |
                  | TLS TERMINATE  |
                  +----------------+


                  INTERNAL MESH
                       
       service-A ───── mTLS ─────> inventory-service
       
       service-B ───── mTLS ─────> inventory-service


                  EGRESS

       application
           |
           | HTTP :80
           v
       Istio Sidecar
           |
           | TLS Origination
           | HTTPS :443
           v
       warehouse.partner.com
```

---

# The Critical Exam Comparison

These four labs deliberately cover the following matrix:

| Scenario  | Gateway TLS   | Backend | External TLS |
| --------- | ------------- | ------- | ------------ |
| **Lab 1** | `SIMPLE`      | HTTP    | Origination  |
| **Lab 2** | `SIMPLE`      | HTTP    | —            |
| **Lab 3** | —             | —       | Origination  |
| **Lab 4** | `PASSTHROUGH` | HTTPS   | Origination  |

The distinction is extremely important:

### Gateway TLS termination

```yaml
tls:
  mode: SIMPLE
```

means:

```text
Client
  ↓ HTTPS
Gateway
  ↓ HTTP
Backend
```

---

### Gateway TLS passthrough

```yaml
tls:
  mode: PASSTHROUGH
```

means:

```text
Client
  ↓ HTTPS
Gateway
  ↓ HTTPS
Backend
```

The Gateway does not possess/consume the application certificate for TLS termination.

---

### DestinationRule TLS origination

```yaml
trafficPolicy:
  tls:
    mode: SIMPLE
```

means:

```text
Application
    ↓ HTTP
Sidecar
    ↓ HTTPS
External service
```

---

# 🎯 What I Would Prioritize for ICA Preparation

Given your recent focus on **ICA troubleshooting and security**, I would practice these in this order:

**Lab 3 → Lab 2 → Lab 4 → Lab 1**

because they progressively test:

```text
TLS Origination
      ↓
TLS Termination troubleshooting
      ↓
PASSTHROUGH vs SIMPLE
      ↓
STRICT mTLS + Ingress + Egress combined
```

And I would make **Lab 4 an actual timed exam lab**, because it forces you to distinguish four things that are very easy to mix up:

> **PeerAuthentication controls workload mTLS.**
> **Gateway controls inbound listener behavior.**
> **ServiceEntry registers external services.**
> **DestinationRule controls outbound TLS behavior.**

That four-way distinction is one of the most useful mental models for these ICA security labs.
