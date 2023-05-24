#!/usr/bin/env bash

set -o errexit

export DEMO_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

source ${DEMO_DIR}/demo-magic
source ${DEMO_DIR}/helper.sh

export TERM=xterm-256color

cols=100
if command -v tput &> /dev/null; then
  output=$(echo -e cols | tput -S)
  if [[ -n "${output}" ]]; then
    cols=$((output - 10))
  fi
fi
export cols

TYPE_SPEED=30
DEMO_PROMPT="olm-demo $ "
DEMO_COMMENT_COLOR=$GREEN

# needed for "make deploy"
export KUBECONFIG=${DEMO_DIR}/.demo/hub.kubeconfig

kubectl-hub() {
  kubectl --kubeconfig=${DEMO_DIR}/.demo/hub.kubeconfig $@
}

kubectl-s1() {
  kubectl --kubeconfig=${DEMO_DIR}/.demo/spoke1.kubeconfig "$@"
}


c "Hi, glad that you are looking at the OLM everywhere demo!"
c "Operator Lifecycle Management (OLM) is handy for installing and managing operators from curated catalogs."
c "It comes pre-installed with OpenShift but works well with other Kubernetes distributions too.\n"
c "For this demo we have 2 kind clusters: one for management and a managed one."
pe "kind get clusters"

c "Open Cluster Management (OCM) components are running on these clusters."
c "OCM provides a central point for managing multi-clouds multi-scenarios Kubernetes clusters."
pe "kubectl-hub get pods -A"

c "Let's start with the OLM-addon installation."
c "OLM-addon is based on the OCM extension mechanism (addon framework). It allows installation, configuration and update of OLM on managed clusters."
pushd ${DEMO_DIR}/.. &>/dev/null
# kubectl-hub label managedcluster spoke1 vendor=kind &> /dev/null
pe "make deploy"
popd &>/dev/null

# c "We can now specify that OLM is to be deployed on our clusters. This can also be done once using OCM Placement API."
# c "This should not be needed and covered by the placement rule"
pe "cat <<EOF | kubectl-hub apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: olm-addon
  namespace: spoke1
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
"

c "OLM is now getting automatically installed on the spoke clusters."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/hub.kubeconfig kubectl get managedclusteraddon -A 2>/dev/null | wc -l) -gt 1 ]'
pe "kubectl-hub get managedclusteraddons -A"
c "The selection of clusters where OLM gets installed is driven by a placement resource, which is configurable."
c "Alternatively managedclusteraddons resources can be created manually."
pe "kubectl-hub get placement -n open-cluster-management -o yaml"
c "It only gets installed on clusters with the vendor label set to something else than OpenShift."
c "This check is additionally built in the addon implementation."

c "Let's check what we have on the spoke clusters."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke1.kubeconfig kubectl get pods -n rukpak-system -o name | wc -l) -gt 2 ]'
pe "kubectl-s1 get pods -A -o wide"

c "OLM deployments can be configured globally, per cluster or set of clusters."
pe "kubectl-hub get addondeploymentconfigs -n open-cluster-management -o yaml"
c "Here we have node placement configured globally."

# c "Let's specify a different OLM image for the spoke1 cluster only to simulate a canary deployment."
# pe "cat <<EOF | kubectl-hub apply -f -
# apiVersion: addon.open-cluster-management.io/v1alpha1
# kind: AddOnDeploymentConfig
# metadata:
#   name: olm-release-0.24-0
#   namespace: default
# spec:
# # OLMImage
# # the same image is used for
# # - olm-operator
# # - catalog-operator
# # - packageserver
# # here it is the image for OLM release v0.24.0
#   customizedVariables:
#   - name: OLMImage
#     value: quay.io/operator-framework/olm@sha256:f9ea8cef95ac9b31021401d4863711a5eec904536b449724e0f00357548a31e7
# EOF

# pe "kubectl-hub patch managedclusteraddon -n spoke1 olm-addon --type='merge' -p \"{\\\"spec\\\":{\\\"configs\\\":[{\\\"group\\\":\\\"addon.open-cluster-management.io\\\",\\\"resource\\\":\\\"addondeploymentconfigs\\\",\\\"name\\\":\\\"olm-release-0-24-0\\\",\\\"namespace\\\":\\\"default\\\"}]}}\""

# c "Let's check that the new image has been deployed."
# pe "kubectl-s1 get pods -A -o wide"

# TODO: Add configuration of catalogs to the demo when ready

c "Now it is becoming interesting :-)"
c "Let's look at what we can do with OLM on the managed clusters."
c "2 operational models are supported:"
c "  - the managed cluster is handed over to an application team, that interacts directly with it"
c "  - the installation of operators and the management of their lifecycle stays centralized\n"

c "Let's create a BundleDeployment and install an operator."
c "Alternatively a policy could get defined on the hub to create the same."
pe "cat <<EOF | kubectl-s1 apply -f -
apiVersion: core.rukpak.io/v1alpha1
kind: BundleDeployment
metadata:
  name: combo
spec:
  provisionerClassName: core-rukpak-io-plain
  template:
    metadata:
      labels:
        app: combo
    spec:
      provisionerClassName: core-rukpak-io-plain
      source:
        image:
          ref: quay.io/operator-framework/combo-bundle:v0.0.1
        type: image
EOF
"

c "Checking that the operator is getting installed."
# wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke1.kubeconfig kubectl get pods -n operators -o name | wc -l) -eq 1 ]'
pe "kubectl-s1 get pods -A"
pe "kubectl-s1 get crds"

c "The installed version of the operator is on purpose not the latest."
pe "kubectl-s1 patch  bundledeployment combo --type='merge' -p \"{\\\"spec\\\":{\\\"template\\\":{\\\"spec\\\":{\\\"source\\\":{\\\"image\\\":{\\\"ref\\\":\\\"quay.io/operator-framework/combo-bundle:v0.0.2\\\"}}}}}}\""
c "Let's check that the operator is getting updated."
pe "kubectl-s1 get pods -A"

c "Let's uninstall the operator by deleting the BundleDeplyoment."
pe "kubectl-s1 delete bundledeployment combo"
c "And check that the operator is getting deleted."
pe "kubectl-s1 get pods -A"

c "Finally OLM can get removed by deleting the managedclusteraddon on the hub if it was manually created."
c "Here we will just patch the placement so that our spoke clusters are not covered by the rule anymore."
# pe "kubectl-hub delete managedclusteraddons.addon.open-cluster-management.io -n spoke1 olm-addon"
pe "kubectl-hub patch Placement -n open-cluster-management non-openshift --type='merge' -p  \"{\\\"spec\\\":{\\\"predicates\\\":[{\\\"requiredClusterSelector\\\":{\\\"labelSelector\\\":{\\\"matchLabels\\\":{\\\"demo\\\":\\\"finished\\\"}}}}]}}\""
pe "kubectl-hub get placements -A"
# wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke1.kubeconfig kubectl get pods -n  -o name | wc -l) -lt 2 ]'
pe "kubectl-s1 get pods -n rukpak-system"

c "That's it! Thank you for watching."

