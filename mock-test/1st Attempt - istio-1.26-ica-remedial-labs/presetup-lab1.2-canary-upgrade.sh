#!/usr/bin/env bash
# Presetup for LAB 1.2 - Zero-downtime canary (revision-based) upgrade 1.25 -> 1.26
#
# This lab needs an EXISTING older-revision control plane to upgrade FROM.
# If your cluster is already fully on 1.26 (likely, since you said Istio is
# already set up), this script will download istioctl 1.25.x and install it
# as an isolated practice revision named "1-25-0" so you have something
# realistic to upgrade in the lab, without touching your real mesh.
#
# Usage: ./presetup-lab1.2-canary-upgrade.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PRACTICE_OLD_VERSION="1.25.3"
WORKDIR="$SCRIPT_DIR/.lab12-tools"

echo "== LAB 1.2 prerequisite check =========================="
check_kubectl
check_istioctl
check_k8s_version_compat
check_istio_control_plane
check_no_incluster_operator

echo
echo "-- Detecting existing istiod revisions --"
kubectl get pods -n istio-system -l app=istiod \
  -o custom-columns=NAME:.metadata.name,REV:.metadata.labels.istio\\.io/rev 2>/dev/null

HAS_125_REV=$(kubectl get pods -n istio-system -l app=istiod -o jsonpath='{.items[*].metadata.labels.istio\.io/rev}' 2>/dev/null | grep -o '1-25' || true)

if [ -z "$HAS_125_REV" ]; then
  WARN "No 1.25.x revision detected. Setting up an isolated '1-25-0' practice revision so you have something to upgrade from."
  mkdir -p "$WORKDIR"
  if [ ! -x "$WORKDIR/istio-$PRACTICE_OLD_VERSION/bin/istioctl" ]; then
    INFO "Downloading istioctl $PRACTICE_OLD_VERSION into $WORKDIR (requires internet access) ..."
    (cd "$WORKDIR" && ISTIO_VERSION="$PRACTICE_OLD_VERSION" curl -sL https://istio.io/downloadIstio | sh -) \
      && PASS "Downloaded istioctl $PRACTICE_OLD_VERSION" \
      || FAIL "Could not download istioctl $PRACTICE_OLD_VERSION - check internet access and retry"
  else
    INFO "istioctl $PRACTICE_OLD_VERSION already downloaded"
  fi

  OLD_ISTIOCTL="$WORKDIR/istio-$PRACTICE_OLD_VERSION/bin/istioctl"
  if [ -x "$OLD_ISTIOCTL" ]; then
    INFO "Installing practice revision '1-25-0' using istioctl $PRACTICE_OLD_VERSION ..."
    "$OLD_ISTIOCTL" install --set revision=1-25-0 --set profile=default -y \
      && PASS "Practice revision '1-25-0' installed" \
      || FAIL "Failed to install the practice 1.25 revision"
  fi
else
  PASS "A 1.25.x revision is already present - you can use it directly for this lab"
fi

echo
echo "-- Confirming current istioctl in PATH is 1.26.x (the upgrade target) --"
CURRENT_V=$(istioctl version --remote=false 2>/dev/null | grep -o '1\.26\.[0-9]*' | head -1)
if [ -n "$CURRENT_V" ]; then
  PASS "PATH istioctl is $CURRENT_V - good, this is what you'll use for the 1.26 install step"
else
  WARN "Your PATH istioctl does not report a 1.26.x version. Make sure the 1.26 binary is what you use for the 'new revision' install step in the lab (not the one under .lab12-tools/)."
fi

echo
echo "-- Preparing the target namespace for migration practice --"
ensure_namespace payments
label_injection_on payments
kubectl -n payments get deploy httpbin >/dev/null 2>&1 || kubectl -n payments create deployment httpbin --image=kennethreitz/httpbin --port=80 >/dev/null
kubectl -n payments expose deployment httpbin --port=80 --target-port=80 >/dev/null 2>&1 || true
wait_rollout payments httpbin

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 1.2:
  1. istioctl install --set revision=1-26-0 --set profile=default -y   (uses your PATH istioctl, 1.26.x)
  2. istioctl x precheck && istioctl proxy-status
  3. kubectl label namespace payments istio-injection- istio.io/rev=1-26-0 --overwrite
  4. kubectl rollout restart deployment -n payments
  5. Validate, then promote 1-26-0 to default and remove the old (1-25-0) revision.

Cleanup when done:
  istioctl x uninstall --revision 1-25-0 -y
  istioctl x uninstall --revision 1-26-0 -y   # if you don't want to keep it as your mesh's control plane
  kubectl delete ns payments
EOF
