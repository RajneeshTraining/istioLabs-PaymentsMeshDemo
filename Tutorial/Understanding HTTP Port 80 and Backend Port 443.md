# Istio Gateway vs VirtualService: Understanding HTTP Port 80 and Backend Port 443

 When working with Istio, one of the most common sources of confusion is seeing **port 80 in an Istio Gateway** while the corresponding `VirtualService` routes traffic to port 443.

 At first glance, this can look contradictory:

 > If the Gateway listens on HTTP port 80, why does the VirtualService send traffic to port 443?

 The answer becomes much clearer once we understand that the Gateway's port and the destination service's port belong to **different sides of the traffic flow**.

 In this tutorial, we'll use a simple booking application to understand:

 - What an Istio `Gateway` does
- What an Istio `VirtualService` does
- Why the Gateway uses port `80`
- Why the backend uses port `443`
- Whether the client should use `http://` or `https://`
- Why port `443` does not automatically mean HTTPS
- How to configure HTTPS correctly
- How to troubleshoot this type of configuration

---

 ## 1\. The Istio Architecture

 Our example contains a client, an Istio ingress gateway, and a backend service called `booking-service`.

 The traffic flow looks like this:

```
                    External Client
                          |
                          |
                    HTTP :80
                          |
                          v
              +-----------------------+
              |   Istio Ingress       |
              |      Gateway          |
              |                       |
              | booking.example.com   |
              |       :80 / HTTP      |
              +-----------+-----------+
                          |
                          |
                   VirtualService
                          |
                          |
                          v
              +-----------------------+
              |    booking-service    |
              |                       |
              |        :443           |
              +-----------------------+
```

 There are two different ports in this architecture:

```
Client --> Istio Gateway
         HTTP :80

Istio Gateway --> booking-service
                :443
```

 These ports should not be confused with each other.

---

 ## 2\. The Istio Gateway

 Let's start with the Gateway manifest:

```
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: booking-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    name: booking
    hosts:
    - booking.example.com
```

 This configuration tells Istio:

 > Accept HTTP traffic for `booking.example.com` on port 80.

 The important part is:

```
port:
  number: 80
  name: http
  protocol: HTTP
```

 Here we explicitly define:

```
Port     = 80
Protocol = HTTP
```

 So the external request should look like:

```
curl http://booking.example.com
```

 Or, explicitly specifying the port:

```
curl http://booking.example.com:80
```

---

 ## 3\. What Does the Gateway Selector Mean?

 The Gateway contains:

```
selector:
  istio: ingressgateway
```

 This tells Istio which Envoy gateway workload should implement this configuration.

 Typically, an Istio installation has an ingress gateway deployment with labels similar to:

```
istio: ingressgateway
```

 Conceptually:

```
                Istio Gateway resource
                         |
                         | selector
                         v
              istio: ingressgateway
                         |
                         v
              Istio Ingress Gateway
                    / Envoy
```

 The Gateway resource itself isn't an application server.

 Instead, it configures the Istio ingress gateway proxy.

---

 ## 4\. The Hostname Matters

 The Gateway specifies:

```
hosts:
- booking.example.com
```

 This means the Gateway is interested in requests for:

```
booking.example.com
```

 For example:

```
curl http://booking.example.com
```

 The HTTP request contains a Host header similar to:

```
Host: booking.example.com
```

 Istio uses this hostname when determining which Gateway and VirtualService configuration should handle the request.

 For testing without DNS, you can also send the Host header manually:

```
curl -H "Host: booking.example.com" http://<INGRESS-IP>
```

 This is particularly useful when testing an Istio ingress gateway before DNS has been configured.

---

 ## 5\. The VirtualService

 Now let's look at the second manifest:

```
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: booking
spec:
  hosts:
  - booking.example.com
  gateways:
  - booking-gateway
  http:
  - route:
    - destination:
        host: booking-service
        port:
          number: 443
```

 The VirtualService answers a different question.

 The Gateway says:

 > "Where can traffic enter?"

 The VirtualService says:

 > "Once traffic enters, where should it go?"

 This distinction is fundamental to understanding Istio.

---

 ## 6\. Gateway vs VirtualService

 A useful mental model is:

```
Gateway
   |
   | Defines the entry point
   |
   v
"I accept HTTP traffic on port 80
 for booking.example.com"

                    |
                    v

VirtualService
   |
   | Defines routing
   |
   v
"When traffic for booking.example.com
 arrives through booking-gateway,
 route it to booking-service:443"
```

 So the two resources have different responsibilities.

 | Resource | Responsibility |
| --- | --- |
| Gateway | Defines how traffic enters the mesh |
| VirtualService | Defines how traffic is routed |
| Destination | Identifies the backend service |
| DestinationRule | Controls traffic policies such as TLS, load balancing, subsets, etc. |

---

 ## 7\. Why Is the Backend Port 443?

 This is the part that usually causes confusion.

 Our VirtualService contains:

```
destination:
  host: booking-service
  port:
    number: 443
```

 This means:

```
Send traffic to:

booking-service:443
```

 It does **not** mean:

```
The client must use HTTPS.
```

 The port number and application protocol are separate concepts.

 Port `443` is conventionally used for HTTPS, but **port 443 alone does not automatically make traffic HTTPS**.

 For example, an application could technically listen for HTTP on port 443.

 Similarly, an application could technically serve HTTPS on port 8443.

 Therefore:

```
443 != automatically HTTPS
```

 The protocol needs to be determined/configured separately.

---

 ## 8\. The Complete Traffic Flow

 With the provided manifests, the conceptual traffic flow is:

```
             CLIENT
                |
                |
                | HTTP
                | TCP :80
                |
                v
     +----------------------+
     | Istio IngressGateway |
     |                      |
     | booking.example.com  |
     | HTTP :80             |
     +----------+-----------+
                |
                |
                | Routed by
                | VirtualService
                |
                v
     +----------------------+
     |   booking-service    |
     |                      |
     |       :443           |
     +----------------------+
```

 Therefore, the client-facing URL is:

```
curl http://booking.example.com
```

 Not:

```
curl https://booking.example.com
```

 because the Gateway has not been configured with an HTTPS listener.

---

 ## 9\. Does `booking-service:443` Mean Istio Uses HTTPS?

 No.

 This is an extremely important Istio concept.

 Consider:

```
port:
  number: 443
```

 This specifies the destination port.

 It doesn't necessarily specify the protocol.

 If the backend expects HTTPS, Istio needs to know that TLS should be used for the upstream connection.

 One common way to configure this is with a `DestinationRule`.

 For example:

```
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: booking-service
spec:
  host: booking-service
  trafficPolicy:
    tls:
      mode: SIMPLE
```

 Now Istio can originate TLS when connecting to the backend.

 The traffic becomes:

```
                  HTTP :80
Client ---------------------------->
                                  |
                                  v
                         Istio IngressGateway
                                  |
                                  |
                                  | HTTPS :443
                                  |
                                  v
                           booking-service
```

 The client still uses:

```
curl http://booking.example.com
```

 while Istio establishes TLS to the backend.

---

 ## 10\. Two Different TLS Scenarios

 It is useful to distinguish **TLS termination at the Gateway** from **TLS to the backend**.

 ### Scenario A — HTTP from Client, HTTPS to Backend

```
Client
  |
  | HTTP :80
  v
Istio Gateway
  |
  | HTTPS :443
  v
booking-service
```

 The client executes:

```
curl http://booking.example.com
```

 TLS exists only between Istio and the backend.

 This is commonly called **TLS origination** from the proxy to the upstream service.

---

 ### Scenario B — HTTPS from Client, HTTP to Backend

 Another common architecture is:

```
Client
  |
  | HTTPS :443
  v
Istio Gateway
  |
  | HTTP :8080
  v
booking-service
```

 Here the Gateway terminates TLS.

 The client executes:

```
curl https://booking.example.com
```

 The Gateway requires an HTTPS server configuration and a certificate.

---

 ## 11\. Configuring HTTPS at the Istio Gateway

 If our requirement is:

 > Clients should connect using HTTPS.

 Then the Gateway needs an HTTPS listener.

 For example:

```
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: booking-gateway
spec:
  selector:
    istio: ingressgateway

  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS

    tls:
      mode: SIMPLE
      credentialName: booking-tls

    hosts:
    - booking.example.com
```

 Now the architecture changes to:

```
                  HTTPS :443
Client ---------------------------->
                                  |
                                  v
                         Istio IngressGateway
                                  |
                                  |
                                  v
                           VirtualService
                                  |
                                  |
                                  v
                           booking-service
```

 The client can now use:

```
curl https://booking.example.com
```

 The certificate referenced by:

```
credentialName: booking-tls
```

 must be available to the Istio ingress gateway according to the Istio/Kubernetes certificate configuration being used.

---

 ## 12\. HTTP vs HTTPS: A Simple Comparison

 With the original Gateway:

```
port:
  number: 80
  protocol: HTTP
```

 Use:

```
curl http://booking.example.com
```

 With an HTTPS Gateway:

```
port:
  number: 443
  protocol: HTTPS
```

 Use:

```
curl https://booking.example.com
```

 The important relationship is:

```
Gateway port + Gateway protocol
              |
              v
       Client connection
```

 Whereas:

```
VirtualService destination port
              |
              v
       Backend connection
```

 They are independent.

---

 ## 13\. A More Complete Production Architecture

 A production deployment will often look more like this:

```
                       Internet
                          |
                          |
                   HTTPS :443
                          |
                          v
              +----------------------+
              | Istio IngressGateway |
              |                      |
              | TLS termination      |
              +----------+-----------+
                         |
                         |
                  VirtualService
                         |
                         v
              +----------------------+
              |    booking-service   |
              |       :8080          |
              +----------+-----------+
                         |
                         v
                    Booking Pods
```

 Or, if TLS is required all the way to the application:

```
                       Internet
                          |
                    HTTPS :443
                          |
                          v
              +----------------------+
              | Istio IngressGateway |
              +----------+-----------+
                         |
                    HTTPS :443
                         |
                         v
              +----------------------+
              |    booking-service   |
              |       :443           |
              +----------+-----------+
                         |
                         v
                    Booking Pods
```

 The exact design depends on where TLS termination and encryption are required.

---

 ## 14\. A Common Mistake

 A common assumption is:

```
VirtualService destination port = 443

therefore

Client should use HTTPS.
```

 That is incorrect.

 The correct interpretation is:

```
Gateway:
    Client-facing listener

VirtualService:
    Routing decision

Destination port:
    Backend service port
```

 Therefore:

```
Gateway :80
      !=
Backend :443
```

 They are two separate network connections.

---

 ## 15\. Think in Terms of Two TCP Connections

 This mental model makes the configuration much easier to understand.

 Imagine:

 ### Connection #1

```
Client
  |
  | TCP :80
  |
  v
Istio Ingress Gateway
```

 Then Istio creates/uses an upstream connection:

 ### Connection #2

```
Istio Ingress Gateway
  |
  | TCP :443
  |
  v
booking-service
```

 So there can be two completely different protocols:

```
Client --> Gateway

HTTP :80

Gateway --> Backend

HTTPS :443
```

 The Gateway acts as the intermediary between them.

---

 ## 16\. How to Test the Configuration

 First, test the external Gateway:

```
curl -v http://booking.example.com
```

 The `-v` option is useful because it shows connection details and HTTP headers.

 If DNS is not configured yet, you can test using the ingress IP and Host header:

```
curl -v \
  -H "Host: booking.example.com" \
  http://<INGRESS-GATEWAY-IP>
```

 You can also explicitly specify port 80:

```
curl -v http://booking.example.com:80
```

---

 ## 17\. Testing the Backend Separately

 If you have access to the Kubernetes cluster, verify that the Service exists:

```
kubectl get svc booking-service
```

 Then inspect its ports:

```
kubectl get svc booking-service -o yaml
```

 You want to verify something similar to:

```
ports:
- port: 443
  targetPort: 443
```

 The exact `targetPort` depends on how the application is configured.

 Remember that Kubernetes `Service.port` and the application's container port are also separate concepts.

 For example:

```
booking-service
      |
      | Service port 443
      |
      v
Pod
      |
      | containerPort 8443
      |
      v
Application
```

 That's another layer where port confusion can occur.

---

 ## 18\. Useful Troubleshooting Commands

 Check the Gateway:

```
kubectl get gateway booking-gateway -o yaml
```

 Check the VirtualService:

```
kubectl get virtualservice booking -o yaml
```

 Check the Kubernetes Service:

```
kubectl get svc booking-service -o yaml
```

 Check the pods:

```
kubectl get pods
```

 Check the Istio ingress gateway:

```
kubectl get pods -l istio=ingressgateway
```

 Check the ingress service:

```
kubectl get svc -l istio=ingressgateway
```

 For detailed Istio configuration troubleshooting, inspecting the Envoy configuration with Istio's diagnostic tooling can also be very useful.

---

 ## 19\. The Most Important Takeaway

 Given the original manifests:

```
Gateway:
  port: 80
  protocol: HTTP
```

 and:

```
VirtualService:
  destination:
    port: 443
```

 the expected external request is:

```
curl http://booking.example.com
```

 The traffic flow is:

```
                         HTTP :80
Client -------------------------------->
                                      |
                                      v
                             Istio Gateway
                                      |
                                      |
                              VirtualService
                                      |
                                      |
                              :443 destination
                                      |
                                      v
                              booking-service
```

 **Port 80 belongs to the Gateway's client-facing listener.**

 **Port 443 belongs to the backend destination.**

 They are not the same connection.

 And most importantly:

 > **Port 443 does not automatically mean HTTPS.**

 If `booking-service:443` expects HTTPS, configure TLS appropriately for the upstream connection, such as with a `DestinationRule`.

 If the client should use HTTPS, configure an HTTPS listener on the Istio Gateway.

---

 ## 20\. Final Cheat Sheet

 | Question | Answer for the provided manifests |
| --- | --- |
| What port does the Gateway listen on? | `80` |
| What protocol does the Gateway use? | HTTP |
| What hostname does it accept? | `booking.example.com` |
| What resource performs routing? | VirtualService |
| What backend is selected? | `booking-service` |
| What backend port is selected? | `443` |
| Should the client use `http://`? | **Yes** |
| Should the client use `https://`? | **No**, not with this Gateway configuration |
| Does destination port `443` automatically mean HTTPS? | **No** |
| How do we enable HTTPS for the client? | Add an HTTPS `:443` Gateway server and TLS configuration |
| How do we use HTTPS to the backend? | Configure appropriate upstream TLS, e.g. with a `DestinationRule` |

---

 ## Conclusion

 Istio becomes much easier to understand when we separate **ingress configuration** from **routing configuration**.

 The `Gateway` controls the **front door**:

```
Where and how does traffic enter?
```

 The `VirtualService` controls the **routing decision**:

```
Where should that traffic go?
```

 In our example:

```
                 FRONT DOOR
                     |
                     v
          HTTP :80 / booking.example.com
                     |
                     v
             Istio Gateway
                     |
                     v
             VirtualService
                     |
                     v
          booking-service:443
             BACKEND PORT
```

 So seeing `80` and `443` in the same Istio configuration isn't inherently contradictory.

 They describe **different sides of the traffic path**.

 Once this distinction is clear, many Istio networking configurations become significantly easier to reason about.
