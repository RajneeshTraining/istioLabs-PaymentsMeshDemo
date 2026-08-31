# Istio 1.26 ICA Remedial Labs — Presetup Scripts

These scripts prepare (and verify prerequisites for) each of the 6 labs from
the ICA remedial guide. They assume Istio is **already installed** on your
cluster (except Lab 1.1, which is the install lab itself).

## Files

| File | Lab |
|---|---|
| `common.sh` | shared library — not run directly, sourced by the others |
| `presetup-lab1.1-install.sh` | 1.1 — customized install + dry-run diff |
| `presetup-lab1.2-canary-upgrade.sh` | 1.2 — revision-based canary upgrade |
| `presetup-lab2.1-mtls-authz.sh` | 2.1 — STRICT mTLS + deny-by-default authz |
| `presetup-lab2.2-jwt-authz.sh` | 2.2 — JWT auth + claim-based authz |
| `presetup-lab3.1-subset-mismatch.sh` | 3.1 — troubleshoot broken DestinationRule subset |
| `presetup-lab3.2-gateway-mismatch.sh` | 3.2 — troubleshoot broken Gateway/VirtualService binding |

## Usage

```bash
chmod +x *.sh
./presetup-lab2.1-mtls-authz.sh
```

Each script:
1. Runs prerequisite checks (`kubectl` access, `istioctl` present, Istio
   control plane running, Kubernetes/Istio version compatibility, and
   confirms no deprecated in-cluster Operator is present).
2. **Stops with a non-zero exit code and a `[FAIL]` summary if any check
   fails** — fix the issue and re-run before continuing.
3. Only if all checks pass, builds that lab's scenario (namespaces, sample
   workloads, and — for the two troubleshooting labs — an intentionally
   broken resource that *is* the bug you're meant to find).
4. Prints a short "Ready" block with the exact next commands for that lab.

Labs 3.1 and 3.2 deliberately apply broken YAML as part of setup — that's
the bug you're meant to diagnose and fix as the lab exercise, not a script
error.

## Cleanup

Each script's "Ready" output also lists that lab's cleanup commands
(typically `kubectl delete ns <lab-namespace>`). Run those before moving to
the next lab if you want a clean slate — none of the scripts auto-clean
previous labs for you.

## Requirements

- `kubectl` configured against a working cluster with Istio 1.26 already
  installed (Lab 1.1 excepted).
- `istioctl` (1.26.x) on your `PATH`.
- Outbound internet access for: Lab 1.2 (downloads istioctl 1.25.x) and Lab
  2.2 (downloads sample JWT/JWKS files from Istio's GitHub repo). If you're
  offline, both scripts will warn but let you continue — you'll just need to
  substitute your own old-revision control plane / JWT issuer.
