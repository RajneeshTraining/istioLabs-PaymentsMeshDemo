#!/usr/bin/env bash
# Presetup for LAB 1.1 - Customized install + validating the render before applying
#
# This lab's TASK is the install itself, so this script only VERIFIES your
# environment is ready and does NOT create the overlay.yaml or run istioctl
# install for you - that's what you practice in the lab.
#
# Usage: ./presetup-lab1.1-install.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

echo "== LAB 1.1 prerequisite check =========================="
check_kubectl
check_istioctl
check_k8s_version_compat
check_no_incluster_operator

echo
echo "-- Existing Istio state (informational) --"
if kubectl get deploy -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q .; then
  WARN "An Istio control plane is already installed in this cluster."
  WARN "To avoid disturbing your existing mesh, install this lab's customized"
  WARN "control plane as a SEPARATE REVISION, e.g.:"
  WARN "    istioctl install -f overlay.yaml --set revision=lab11 -y"
  WARN "and clean it up afterwards with:"
  WARN "    istioctl x uninstall --revision lab11 -y"
else
  INFO "No existing Istio control plane detected - you can install directly as 'default'."
fi

echo
echo "-- Cluster capacity check --"
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${NODE_COUNT:-0}" -ge 1 ]; then
  PASS "Cluster has $NODE_COUNT node(s) available"
else
  FAIL "Could not detect any nodes in the cluster"
fi

final_verdict

cat <<'EOF'

Ready. You may now begin Lab 1.1:
  1. Write overlay.yaml (profile: demo, accessLogFile, pilot replicaCount/resources)
  2. istioctl manifest generate -f overlay.yaml > generated-manifest.yaml
  3. istioctl manifest diff generated-manifest.yaml <(istioctl manifest generate --set profile=demo)
  4. istioctl install -f overlay.yaml -y   (add --set revision=lab11 if you already have Istio)
  5. Verify replicas, pod health, and that no in-cluster Operator exists.
EOF
