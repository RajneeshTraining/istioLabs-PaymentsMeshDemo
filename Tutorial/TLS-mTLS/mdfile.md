SERVICE MESH SECURITY · TUTORIAL · EXAM PREP

Istio Security Deep Dive: Ingress mTLS, Passthrough Gateways & Sidecar TLS Termination
======================================================================================

A step-by-step, exam-ready walkthrough of where TLS actually "ends" in an Istio service mesh — with architecture diagrams, working YAML, and a comparison table you'll want to bookmark.

CI

**Cloud Infra Notes** · 14 min read · Istio 1.22+

Client / external traffic Ingress Gateway Sidecar / mesh mTLS App container

If you've worked with Istio for more than a week, you've probably hit this wall: _"Where exactly does my TLS connection get decrypted?"_ The docs mention Gateways, PeerAuthentication, DestinationRules, `MUTUAL`, `PASSTHROUGH`, `ISTIO_MUTUAL`… and none of it clicks until you see the actual traffic flow.

This post fixes that. By the end, you'll be able to draw the architecture from memory, write the YAML without copy-pasting, and answer any CKA/CKS-style or Istio certification question on this topic.

01The one idea that explains everything
---------------------------------------

A request in Istio travels through **three potential decryption points:**

    Client  →  Ingress Gateway  →  Envoy Sidecar  →  App Container

Every "pattern" you'll ever configure is just an answer to: **at which of these points does the TLS connection actually get decrypted?**

Where Can TLS Terminate in Istio? Client (with cert) TLS Ingress Gateway Point A: terminate or passthrough? TLS / mTLS Envoy Sidecar Point B: mesh mTLS terminates here plaintext (localhost) App Container Every design decision below is really about choosing WHICH of these points decrypts the traffic.

Fig. 1 — The three hops a request takes, and the point at which each pattern chooses to decrypt.

Once this clicks, the rest of Istio's security model stops feeling like magic and starts feeling like plumbing.

**Exam tip.** If a question describes a scenario and asks "which component decrypts the traffic," don't think about products — think about hops. Every hop is either "TLS ends here" or "TLS passes through unchanged."

02The building blocks — know these cold
---------------------------------------

Resource

What it controls

Gateway

The listener config on the ingress/egress proxy — port, protocol, and **TLS mode**

VirtualService

Routing rules for traffic that already arrived at the Gateway

DestinationRule

The **client-side** TLS behavior when a proxy calls another service

PeerAuthentication

The **server-side** mTLS requirement for a sidecar (STRICT / PERMISSIVE / DISABLE)

There's a trap here that examiners love:

**Two different mTLS systems exist, and mixing them up is the #1 conceptual mistake.**

*   **Ingress mTLS** — your own PKI, verifying external clients (partners, devices, browsers with client certs) at the edge.
*   **Mesh mTLS** — Istio's own auto-managed PKI, issued by `istiod`, authenticating workload-to-workload traffic using SPIFFE identities.

Keep these mentally separate. A Gateway with `mode: MUTUAL` has nothing to do with `PeerAuthentication` unless you explicitly wire them together.

03Pattern A — Ingress Gateway terminates mTLS
---------------------------------------------

### The classic "zero-trust edge" setup

Clients — often B2B partners or IoT devices — present a certificate, and the **Gateway itself** verifies it and decrypts the payload.

Pattern A — Gateway Terminates mTLS (mode: MUTUAL) Client cert + key mTLS handshake Ingress Gateway 1\. Presents server cert 2\. Verifies client cert against CA bundle 3\. DECRYPTS payload credentialName: server-cert re-encrypt via ISTIO\_MUTUAL Sidecar mesh mTLS (separate hop) plaintext App Two independent TLS sessions: (Client ↔ Gateway) and (Gateway ↔ Sidecar). The gateway is a real TLS endpoint.

Fig. 2 — mode: MUTUAL makes the Gateway a real TLS endpoint with its own cert and CA-verified client auth.

    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: mtls-ingress
    spec:
      selector:
        istio: ingressgateway
      servers:
      - port:
          number: 443
          name: https
          protocol: HTTPS
        tls:
          mode: MUTUAL                  # Gateway is a real TLS server
          credentialName: server-cert   # k8s Secret: tls.crt, tls.key, ca.crt
        hosts:
        - "api.example.com"

### What's really happening

1.  The Gateway presents its own server certificate to the client.
2.  It requests and **verifies the client's certificate** against a CA bundle stored in the `server-cert` Secret.
3.  It **decrypts** the payload right there.
4.  Anything after this point (Gateway → Sidecar → App) is a brand-new, independent connection — usually secured separately with mesh mTLS (`ISTIO_MUTUAL`).

#### WHEN TO USE IT

Partner/B2B APIs where clients hold certs you issued · you want centralized cert rotation and a single, auditable TLS termination point · you're fine with the Gateway seeing plaintext (it's inside your trust boundary).

#### THE TRADE-OFF

The Gateway becomes a single point of decrypted-traffic exposure. If it's compromised, everything flowing through it is visible in plaintext, for every service behind it.

04Pattern B — Gateway without TLS termination (Passthrough)
-----------------------------------------------------------

### Now flip it

The Gateway never decrypts anything. It peeks at the **SNI (Server Name Indication)** field — sent in plaintext even during a TLS handshake — and routes the encrypted bytes untouched.

Pattern B — Gateway PASSTHROUGH (no termination) Client cert + key encrypted TLS bytes Ingress Gateway Reads SNI only "secure.example.com" Never decrypts same TLS stream (byte-for-byte forwarded) Sidecar Envoy Verifies client cert DECRYPTS here plaintext App One unbroken TLS session: Client ↔ Sidecar. The gateway is a transparent router, not a TLS endpoint.

Fig. 3 — The Gateway reads only the SNI hostname; the encrypted stream passes through byte-for-byte.

    apiVersion: networking.istio.io/v1
    kind: Gateway
    metadata:
      name: passthrough-gateway
    spec:
      selector:
        istio: ingressgateway
      servers:
      - port:
          number: 443
          name: tls
          protocol: TLS
        tls:
          mode: PASSTHROUGH        # Gateway never decrypts
        hosts:
        - "secure.example.com"

    apiVersion: networking.istio.io/v1
    kind: VirtualService
    metadata:
      name: passthrough-route
    spec:
      hosts:
      - "secure.example.com"
      gateways:
      - passthrough-gateway
      tls:
      - match:
        - port: 443
          sniHosts:
          - "secure.example.com"
        route:
        - destination:
            host: my-backend-service
            port:
              number: 443

Notice: because the payload is still encrypted, you **can't** match on HTTP paths or headers here — routing has to be done via `tls.match.sniHosts`, not `http.match`.

#### WHEN TO USE IT

True end-to-end encryption is a hard compliance requirement — not even Istio's own proxy should see plaintext · the backend runs its own custom TLS stack that shouldn't be replaced.

#### THE TRADE-OFF

You lose HTTP-layer features at the Gateway — no path-based routing, no header manipulation, no request-level observability at the edge, since it's just watching encrypted bytes fly past.

05Pattern C — Sidecar terminates TLS (Mesh mTLS)
------------------------------------------------

### Where Pattern B's story finishes

This is also what secretly runs for **all** east-west (pod-to-pod) traffic in a mesh by default.

Pattern C — Sidecar Terminates Mesh mTLS istiod (CA) issues short-lived certs SDS: cert for sa/service-a SDS: cert for sa/service-b Pod: service-a App Container Envoy Sidecar Pod: service-b App Container Envoy Sidecar Mesh mTLS (STRICT) SPIFFE ID: spiffe://cluster.local/ns/prod/sa/service-a ↔ service-b plaintext over localhost plaintext over localhost

Fig. 4 — istiod issues short-lived, SPIFFE-based certs to every sidecar via SDS; sidecars mutually authenticate before decrypting to plaintext on localhost.

**Part 1 — server-side requirement:**

    apiVersion: security.istio.io/v1
    kind: PeerAuthentication
    metadata:
      name: default
      namespace: prod
    spec:
      mtls:
        mode: STRICT      # sidecar REJECTS anything that isn't mTLS

**Part 2 — client-side behavior:**

    apiVersion: networking.istio.io/v1
    kind: DestinationRule
    metadata:
      name: my-backend-mtls
    spec:
      host: my-backend-service
      trafficPolicy:
        tls:
          mode: ISTIO_MUTUAL   # use istiod-issued certs automatically

### What's really happening (the part everyone forgets to explain)

1.  `istiod`'s built-in CA issues every pod a **short-lived certificate**, tied to its Kubernetes **service account** — its SPIFFE identity, e.g. `spiffe://cluster.local/ns/prod/sa/my-backend`.
2.  Certs are delivered via **SDS (Secret Discovery Service)** and live only **in-memory** inside the sidecar — never written to disk.
3.  When Sidecar A calls Sidecar B, both sides present these certs and **mutually authenticate**.
4.  Only then does the sidecar decrypt and hand off **plaintext over localhost** to its own app container.

**Exam tip.** STRICT mode rejects plaintext. PERMISSIVE mode (the default during migrations) accepts both plaintext and mTLS on the same port — this is the safe way to roll out mTLS without breaking existing traffic mid-migration.

06Putting it together — the full end-to-end flow
------------------------------------------------

Combine Pattern B (Gateway passthrough) with Pattern C (sidecar termination) and you get genuine, unbroken, end-to-end encryption:

The Complete Picture: Passthrough Gateway + Sidecar mTLS Termination Client 1 cert Ingress Gateway mode: PASSTHROUGH routes by SNI only step 1: no decrypt Sidecar Envoy PeerAuthentication: STRICT step 2: DECRYPT here plaintext App One continuous encrypted channel from the client's device all the way to the workload's sidecar — the ingress gateway never possesses decrypted data at any point.

Fig. 5 — One continuous encrypted channel from client to sidecar. The Gateway never possesses decrypted data.

    1. Client opens a TLS connection to secure.example.com, presenting its cert.
    2. Ingress Gateway (PASSTHROUGH) reads only the SNI — never decrypts —
       and forwards the raw TCP stream untouched.
    3. The destination pod's Envoy sidecar terminates the TLS:
         - validates the client cert against the configured CA
         - decrypts the payload
    4. Sidecar hands plaintext to the app container over localhost.
    5. Response flows back the same way — sidecar re-encrypts,
       gateway passes the bytes through untouched.

This is the architecture to reach for whenever the requirement is _"nothing in our infrastructure, including the ingress proxy, may ever see decrypted data outside the target workload."_

07Pattern A vs. Pattern B+C — the comparison table
--------------------------------------------------

Concern

A: Gateway terminates

B+C: Sidecar terminates

Private key location

Shared ingress Gateway

Isolated per workload, managed by istiod

Blast radius if edge is compromised

Attacker sees decrypted traffic for **every** service behind it

Attacker sees **nothing** — traffic stays encrypted through the Gateway

Cert rotation

Centralized, manual / your responsibility

Automatic, per-service, short-lived

HTTP-layer routing at the edge

✅ Full (paths, headers)

❌ SNI-only

Per-service custom TLS policy

Hard — one Gateway config for all

✅ Easy — each service gets its own PeerAuthentication

Typical use case

Partner/B2B APIs, centralized cert mgmt

Regulatory/compliance-grade E2E encryption

08Exam-style quick review
-------------------------

Use these as flash questions before a certification exam or an interview.

Q1 — What does tls.mode: MUTUAL on a Gateway actually do?

Makes the Gateway a real TLS server: it presents its own cert and requires/verifies a client certificate, decrypting the traffic at the edge.

Q2 — What does tls.mode: PASSTHROUGH do, and what field does routing rely on?

The Gateway never decrypts; it forwards raw bytes based solely on the SNI field read from the unencrypted ClientHello. Routing uses VirtualService.tls.match.sniHosts, not HTTP matches.

Q3 — Which resource enforces what a sidecar accepts as a server, and which enforces what it sends as a client?

PeerAuthentication = server-side acceptance policy (STRICT/PERMISSIVE/DISABLE). DestinationRule (tls.mode: ISTIO\_MUTUAL) = client-side behavior when calling another service.

Q4 — Why is PERMISSIVE mode useful during a migration?

It lets a sidecar accept both plaintext and mTLS on the same port simultaneously, so you can migrate workloads to mTLS one at a time without breaking traffic from not-yet-migrated services.

Q5 — In a fully end-to-end encrypted setup (passthrough + sidecar mTLS), does the Ingress Gateway ever see decrypted payload?

No — it only reads the SNI from the handshake; the actual decryption happens exclusively at the destination sidecar.

Q6 — What identity system underlies mesh mTLS, and who issues the certificates?

SPIFFE identities (e.g. spiffe://cluster.local/ns/<namespace>/sa/<service-account>), issued as short-lived certs by istiod's built-in CA and delivered via SDS.

09Mental model to carry forward
-------------------------------

*   `mode: MUTUAL` on a Gateway → "I _am_ the TLS server. Verify me, I'll verify you."
*   `mode: PASSTHROUGH` on a Gateway → "I'm just a router. I never touch your bytes."
*   `PeerAuthentication: STRICT` → "My sidecar refuses anything that isn't mTLS."
*   `DestinationRule: ISTIO_MUTUAL` → "When I call someone, wrap it in Istio's mesh mTLS automatically."

Every Istio security question — in an exam, in a design review, in an incident postmortem — boils down to tracing the request through these hops and asking: **who holds the private key, and where does decryption actually happen?**

* * *

👏 If this helped, share it with a teammate prepping for the same exam. Follow-ups worth writing next: debugging PASSTHROUGH + SNI routing failures, and a hands-on PERMISSIVE-to-STRICT migration walkthrough.
