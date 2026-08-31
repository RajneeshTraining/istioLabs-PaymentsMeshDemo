#!/usr/bin/env bash
# common.sh - shared prerequisite checks & helpers sourced by every lab's presetup.sh
# This file is not meant to be run directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS() { echo -e "${GREEN}[PASS]${NC} $1"; }
FAIL() { echo -e "${RED}[FAIL]${NC} $1"; FAILED=1; }
WARN() { echo -e "${YELLOW}[WARN]${NC} $1"; }
INFO() { echo "[INFO] $1"; }

FAILED=0

check_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then PASS "kubectl is installed"; else FAIL "kubectl is not installed / not on PATH"; fi
  if kubectl cluster-info >/dev/null 2>&1; then PASS "kubectl can reach the cluster"; else FAIL "kubectl cannot reach a cluster (check kubeconfig/context)"; fi
}

check_istioctl() {
  if command -v istioctl >/dev/null 2>&1; then
    PASS "istioctl is installed"
    local v
    v=$(istioctl version --remote=false 2>/dev/null | head -1)
    INFO "Local istioctl client version: ${v:-unknown}"
  else
    FAIL "istioctl is not installed / not on PATH"
  fi
}

check_istio_control_plane() {
  if kubectl get ns istio-system >/dev/null 2>&1 && kubectl get deploy -n istio-system -l app=istiod --no-headers 2>/dev/null | grep -q .; then
    PASS "Istio control plane (istiod) found in istio-system"
    kubectl get pods -n istio-system -l app=istiod
  else
    FAIL "No istiod deployment found in istio-system. Install Istio before running this lab."
  fi
}

check_k8s_version_compat() {
  # Istio 1.26 is officially supported on Kubernetes 1.29-1.32 (1.33 expected to work)
  local kv
  kv=$(kubectl version -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | tail -1 | grep -o 'v[0-9]*\.[0-9]*' | head -1)
  if [ -n "$kv" ]; then
    INFO "Detected Kubernetes server version: $kv"
    case "$kv" in
      v1.29|v1.30|v1.31|v1.32|v1.33) PASS "Kubernetes version is within Istio 1.26's supported range (1.29-1.32, 1.33 expected)";;
      *) WARN "Kubernetes version $kv is outside Istio 1.26's officially tested range (1.29-1.32). Lab may still work, proceed with caution.";;
    esac
  else
    WARN "Could not determine Kubernetes server version automatically"
  fi
}

check_no_incluster_operator() {
  if kubectl get deployment -n istio-system istio-operator >/dev/null 2>&1 || kubectl get crd istiooperators.install.istio.io >/dev/null 2>&1; then
    WARN "Deprecated in-cluster Istio Operator (or its CRD) detected. It cannot be used with 1.26. Consider: istioctl operator remove"
  else
    PASS "No deprecated in-cluster Istio Operator found (expected/healthy on 1.26)"
  fi
}

ensure_namespace() {
  local ns="$1"
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    INFO "Namespace '$ns' already exists, reusing it"
  else
    kubectl create ns "$ns" >/dev/null
    PASS "Created namespace '$ns'"
  fi
}

label_injection_on() {
  kubectl label namespace "$1" istio-injection=enabled istio.io/rev- --overwrite >/dev/null
  PASS "Namespace '$1' labeled for sidecar injection (istio-injection=enabled)"
}

label_injection_off() {
  kubectl label namespace "$1" istio-injection- --overwrite >/dev/null 2>&1
  PASS "Namespace '$1' left WITHOUT sidecar injection (on purpose for this lab)"
}

wait_rollout() {
  local ns="$1"; shift
  for dep in "$@"; do
    INFO "Waiting for deployment/$dep in ns/$ns to become ready..."
    if kubectl rollout status deployment/"$dep" -n "$ns" --timeout=180s >/dev/null 2>&1; then
      PASS "deployment/$dep in ns/$ns is ready"
    else
      FAIL "deployment/$dep in ns/$ns did not become ready in time"
    fi
  done
}

final_verdict() {
  echo
  if [ "$FAILED" -eq 0 ]; then
    echo -e "${GREEN}=========================================================${NC}"
    echo -e "${GREEN} All prerequisites verified. Lab environment is ready.${NC}"
    echo -e "${GREEN}=========================================================${NC}"
  else
    echo -e "${RED}=========================================================${NC}"
    echo -e "${RED} One or more prerequisite checks FAILED (see [FAIL] above).${NC}"
    echo -e "${RED} Fix the issues, then re-run this script.${NC}"
    echo -e "${RED}=========================================================${NC}"
    exit 1
  fi
}
