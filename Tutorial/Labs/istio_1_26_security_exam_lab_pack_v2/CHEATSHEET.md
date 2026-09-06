# ICA Security Quick Reference

PeerAuthentication = connection/mTLS posture.
RequestAuthentication = JWT validation.
AuthorizationPolicy = authorization.

Workload identity:
`principals: cluster.local/ns/<namespace>/sa/<service-account>`

JWT identity:
`requestPrincipals: <issuer>/<subject>`

JWT claim:
`request.auth.claims[role]`

Gateway:
`SIMPLE` = terminate TLS
`PASSTHROUGH` = do not terminate application TLS

Debug:
```bash
kubectl get peerauthentication,requestauthentication,authorizationpolicy -A
istioctl analyze -A
istioctl x describe pod <pod> -n <ns>
istioctl proxy-config listener <pod> -n <ns>
istioctl proxy-config cluster <pod> -n <ns>
istioctl proxy-config secret <pod> -n <ns>
```
