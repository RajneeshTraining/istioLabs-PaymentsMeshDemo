# Istio 1.26 Security — ICA Exam Lab Pack

Five complete, runnable security labs. Istio 1.26 is assumed installed.

Every lab has QUESTION.md, SOLUTION.md, manifests, commands, validation and cleanup.

Labs:
1. STRICT mTLS + workload identity authorization
2. JWT authentication + claim-based authorization
3. HTTPS ingress TLS termination + JWT + backend mTLS
4. Zero-trust ServiceAccount authorization
5. Expert troubleshooting of broken mTLS/JWT/AuthorizationPolicy

Official references:
https://istio.io/latest/docs/concepts/security/
https://istio.io/latest/docs/reference/config/security/peer_authentication/
https://istio.io/latest/docs/reference/config/security/request_authentication/
https://istio.io/latest/docs/reference/config/security/authorization-policy/
https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/

Useful commands:
kubectl get peerauthentication,requestauthentication,authorizationpolicy -A
istioctl analyze -A
istioctl x describe pod <pod> -n <ns>
istioctl proxy-config listener <pod> -n <ns>
istioctl proxy-config cluster <pod> -n <ns>
istioctl proxy-config secret <pod> -n <ns>
