#!/usr/bin/env bash
#
# End-to-end local test for the scale-to-zero plugin.
# Requires: Rancher Desktop with CNPG operator installed, nerdctl, kubectl.
#
# Usage:
#   ./hack/test-local.sh          # deploy and create test cluster
#   ./hack/test-local.sh teardown # remove test cluster and plugin
#
set -euo pipefail

PLUGIN_NS="cnpg-system"
TEST_NS="default"
CLUSTER_NAME="scale-to-zero-test"
INACTIVITY_MINUTES="2"

info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; }

teardown() {
    info "Tearing down test resources..."
    kubectl delete cluster "${CLUSTER_NAME}" -n "${TEST_NS}" --ignore-not-found=true 2>/dev/null
    kubectl delete scheduledbackup "${CLUSTER_NAME}" -n "${TEST_NS}" --ignore-not-found=true 2>/dev/null
    kubectl delete clusterrolebinding "${CLUSTER_NAME}-scale-to-zero-binding" --ignore-not-found=true 2>/dev/null
    kubectl delete -f manifest-dev.yaml --ignore-not-found=true 2>/dev/null
    info "Teardown complete."
}

check_prereqs() {
    local missing=0
    for cmd in nerdctl kubectl; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd not found"
            missing=1
        fi
    done

    if ! kubectl get deployment cloudnative-pg -n "${PLUGIN_NS}" &>/dev/null; then
        error "CNPG operator not found in ${PLUGIN_NS}. Install it first:"
        error "  kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

build_and_deploy_plugin() {
    info "Building container images..."
    make build-images-dev

    info "Generating dev manifest..."
    make manifest-dev

    info "Deploying scale-to-zero plugin..."
    kubectl apply -f manifest-dev.yaml

    info "Waiting for plugin deployment..."
    kubectl wait --for=condition=available --timeout=120s deployment/scale-to-zero -n "${PLUGIN_NS}"
    info "Plugin is running."
}

create_test_cluster() {
    info "Creating test cluster '${CLUSTER_NAME}' (inactivity: ${INACTIVITY_MINUTES}m)..."

    # RBAC for the sidecar
    sed "s/CLUSTER_NAME/${CLUSTER_NAME}/g; s/NAMESPACE/${TEST_NS}/g" \
        doc/examples/rbac-template.yaml | kubectl apply -f -

    # The cluster itself
    cat <<YAML | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${TEST_NS}
  annotations:
    xata.io/scale-to-zero-enabled: "true"
    xata.io/scale-to-zero-inactivity-minutes: "${INACTIVITY_MINUTES}"
spec:
  instances: 1
  enableSuperuserAccess: true
  plugins:
  - name: cnpg-i-scale-to-zero.xata.io
  storage:
    size: 1Gi
YAML

    info "Waiting for cluster to start (this takes a minute or two)..."
    kubectl wait --for=condition=Ready cluster/"${CLUSTER_NAME}" -n "${TEST_NS}" --timeout=300s 2>/dev/null || true

    # Wait for the pod to exist and be ready
    local retries=0
    while [[ $retries -lt 60 ]]; do
        local pod
        pod=$(kubectl get pods -n "${TEST_NS}" -l cnpg.io/cluster="${CLUSTER_NAME}" -o name 2>/dev/null | head -1)
        if [[ -n "$pod" ]]; then
            if kubectl wait --for=condition=Ready "${pod}" -n "${TEST_NS}" --timeout=10s 2>/dev/null; then
                break
            fi
        fi
        retries=$((retries + 1))
        sleep 5
    done
}

verify_sidecar() {
    info "Verifying sidecar injection..."
    local pod
    pod=$(kubectl get pods -n "${TEST_NS}" -l cnpg.io/cluster="${CLUSTER_NAME}" -o name 2>/dev/null | head -1)

    if [[ -z "$pod" ]]; then
        error "No pods found for cluster ${CLUSTER_NAME}"
        return 1
    fi

    local containers
    containers=$(kubectl get "${pod}" -n "${TEST_NS}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    echo "    Pod: ${pod}"
    echo "    Containers: ${containers}"

    if echo "$containers" | grep -q "scale-to-zero"; then
        info "Sidecar injected successfully!"
    else
        # Check init containers (native sidecar)
        local init_containers
        init_containers=$(kubectl get "${pod}" -n "${TEST_NS}" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null)
        echo "    Init containers: ${init_containers}"
        if echo "$init_containers" | grep -q "scale-to-zero"; then
            info "Sidecar injected as native sidecar (init container) successfully!"
        else
            error "Sidecar NOT found in pod containers or init containers"
            return 1
        fi
    fi

    info "Checking sidecar logs..."
    kubectl logs "${pod}" -n "${TEST_NS}" -c scale-to-zero --tail=10 2>/dev/null || echo "    (no logs yet)"

    echo ""
    info "Test cluster is running. The sidecar will hibernate after ${INACTIVITY_MINUTES} minutes of inactivity."
    info "Watch it happen:"
    echo "    kubectl logs ${pod} -n ${TEST_NS} -c scale-to-zero -f"
    echo ""
    info "To tear down:"
    echo "    ./hack/test-local.sh teardown"
}

# Main
if [[ "${1:-}" == "teardown" ]]; then
    teardown
    exit 0
fi

check_prereqs
build_and_deploy_plugin
create_test_cluster
verify_sidecar
