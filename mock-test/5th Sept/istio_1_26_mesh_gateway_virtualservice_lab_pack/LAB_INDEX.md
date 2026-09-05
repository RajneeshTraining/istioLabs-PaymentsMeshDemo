# Lab index

| Lab | Core skill | Difficulty |
|---|---|---|
| 1 | `mesh` vs custom Gateway | Intermediate |
| 2 | One VirtualService, two gateway contexts | Intermediate+ |
| 3 | Diagnose Gateway-only VirtualService | Advanced |
| 4 | Gateway + source namespace matching | Advanced |
| 5 | Overlap/conflict troubleshooting | Expert |

## Suggested exam workflow

For every task:

```bash
kubectl get gw,vs,dr -A
istioctl analyze -A
kubectl describe virtualservice <name> -n <ns>
```

Then inspect proxy routes:

```bash
istioctl proxy-config routes <pod> -n <ns>
```

Finally prove behavior with a request from the correct traffic context.
