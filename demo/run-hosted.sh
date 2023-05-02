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

kubectl-mgmt() {
  kubectl --kubeconfig=${DEMO_DIR}/.demo/management.kubeconfig "$@"
}

kubectl-s() {
  kubectl --kubeconfig=${DEMO_DIR}/.demo/spoke.kubeconfig $@
}

c "Hi, glad that you are looking at the OLM everywhere demo!"
c "Operator Lifecycle Management (OLM) is handy for installing and managing operators from curated catalogs."
c "It comes pre-installed with OpenShift but works well with other Kubernetes distributions too.\n"
c "For this demo we have 3 kind clusters: one hub, one management and a managed one."
c "This setup is called hosted mode, where Open Cluster Management (OCM) and addon components run on the management rather than the managed cluster."
pe "kind get clusters"

c "OCM provides a central point for managing multi-clouds multi-scenarios Kubernetes clusters."
pe "kubectl-hub get pods -A"
pe "kubectl-mgmt get pods -A"
pe "kubectl-s get pods -A"
c "As you can see no ACM agent run on the managed cluster."

c "Let's start with the OLM-addon installation."
c "OLM-addon is based on the OCM extension mechanism (addon framework). It allows installation, configuration and update of OLM on managed clusters."
pushd ${DEMO_DIR}/.. &>/dev/null
pe "make deploy"
popd &>/dev/null
kubectl-hub patch Placement -n open-cluster-management non-openshift --type='merge' -p  "{\"spec\":{\"predicates\":[{\"requiredClusterSelector\":{\"labelSelector\":{\"matchLabels\":{\"olm\":\"true\"}}}}]}}" &> /dev/null

# c "We can now specify that OLM is to be deployed on our clusters. This can also be done once using OCM Placement API."
# pe "cat <<EOF | kubectl-hub apply -f -
# apiVersion: addon.open-cluster-management.io/v1alpha1
# kind: ManagedClusterAddOn
# metadata:
#  name: olm-addon
#  namespace: spoke
# spec:
#  installNamespace: open-cluster-management-agent-addon
# EOF
# "

c "OLM is now getting automatically installed for the spoke cluster."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/hub.kubeconfig kubectl get managedclusteraddons -A -o name | wc -l) -gt 0 ]'
pe "kubectl-hub get managedclusteraddons -A"
c "The selection of clusters where OLM gets installed is driven by a placement resource, which is configurable."
c "Alternatively managedclusteraddons resources can be created manually."
pe "kubectl-hub get placement -n open-cluster-management -o yaml"
c "It only gets installed on clusters with the label olm=true."
c "Let's annotate the managedclusteraddon resource to specify that we want the addon to be installed in hosted mode."
# This step is unfortunate but it is not possible to specify that the managedclusteraddon resource is to be created with the annotation
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/hub.kubeconfig kubectl get managedclusteraddon -n spoke -o name | grep olm | wc -l) -gt 0 ]'
pe "kubectl annotate managedclusteraddon -n spoke olm-addon \"addon.open-cluster-management.io/hosting-cluster-name\"=\"management\""
c "Let's check what we have on the management cluster."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/management.kubeconfig kubectl get pods -n olm -o name | wc -l) -gt 1 ]'
pe "kubectl-mgmt get pods -A -o wide"
pe "kubectl-mgmt get crds | grep coreos || true"
c "And on the spoke cluster."
pe "kubectl-s get pods -A -o wide"
pe "kubectl-s get crds | grep coreos"
c "The APIs have been created on the managed cluster but the controllers are running on the management cluster!"

# credentials for the managed cluster API need to be made available to the olm components on the management cluster before the next steps can work
skip() {

c "OLM deployments can be configured globally, per cluster or set of clusters."
pe "kubectl-hub get addondeploymentconfigs -n open-cluster-management -o yaml"
c "Here we have node placement configured globally."

c "Let's specify a different OLM image for the spoke cluster only to simulate a canary deployment."
pe "cat <<EOF | kubectl-hub apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: AddOnDeploymentConfig
metadata:
  name: olm-release-0.24-0
  namespace: default
spec:
# OLMImage
# the same image is used for
# - olm-operator
# - catalog-operator
# - packageserver
# here it is the image for OLM release v0.24.0
  customizedVariables:
  - name: OLMImage
    value: quay.io/operator-framework/olm@sha256:f9ea8cef95ac9b31021401d4863711a5eec904536b449724e0f00357548a31e7
EOF
"

pe "kubectl-hub patch managedclusteraddon -n spoke olm-addon --type='merge' -p \"{\\\"spec\\\":{\\\"configs\\\":[{\\\"group\\\":\\\"addon.open-cluster-management.io\\\",\\\"resource\\\":\\\"addondeploymentconfigs\\\",\\\"name\\\":\\\"olm-release-0-24-0\\\",\\\"namespace\\\":\\\"default\\\"}]}}\""

c "Let's check that the new image has been deployed on the spoke cluster."
pe "kubectl-s get pods -A -o wide"

# TODO: Add configuration of catalogs to the demo when ready

c "Now it is becoming interesting :-)"
c "Let's look at what we can do with OLM on the managed cluster."
c "2 operational models are supported:"
c "  - the managed cluster is handed over to an application team, that interacts directly with it"
c "  - the installation of operators and the management of their lifecycle stays centralized\n"

c "Let's look at OLM catalogs and what they provide"
pe "kubectl-s get catalogsources -n olm"
c "The default catalog is for community operators available on operatorhub.io."
c "Users are free to prevent the installation of this catalog and to have their own curated catalog instead."
c "The content of catalogs is simply stored as container images in a standard registry, which can be on- or offline." 

c "Here are the operators of this catalog."
pe "kubectl-s get packagemanifests | more"
c "That's quite a few of them"

c "Let's pick one of them and install it by creating a subscription directly on the managed cluster."
c "Alternatively a policy could get defined on the hub to create subscriptions on the matching managed clusters."
pe "cat <<EOF | kubectl-s apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-postgresql
  namespace: operators
spec:
  channel: v5
  name: postgresql
  source: operatorhubio-catalog
  sourceNamespace: olm
  # OLM can automatically update the operator to the latest and greatest version available
  # or the user may decide to manually approve updates and possibly pin the operator
  # to a validated and trusted version like here.
  installPlanApproval: Manual
  startingCSV: postgresoperator.v5.2.0
EOF
"

c "Let's approve the installation."
installplan=$(kubectl-s get installplans -n operators -o name)
pe "kubectl-s patch ${installplan} -n operators --type='merge' -p \"{\\\"spec\\\":{\\\"approved\\\":true}}\""
c "And check that the operator is getting installed."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke.kubeconfig kubectl get pods -n operators -o name | wc -l) -eq 1 ]'
pe "kubectl-s get pods -n operators"
pe "kubectl-s get crds | grep postgres"

c "The installed version of the operator is on purpose not the latest."
c "Let's look at the installplans."
pe "kubectl-s get installplans -n operators"
c "Besides the installplan we have just approved there is one for a newer version."
c "This matches the latest version in the channel we have subscribed to."
c "We have it here right away as we purposefully installed an older version."
c "This would however automatically pops up when the operator authors publish a new version to the channel the subscription is for."
c "Updating the operator is as simple as approving the new installplan."

installplans=$(kubectl-s get installplans -n operators -o=jsonpath='{range .items[*]}{@.metadata.name}{" "}{@.spec.approved}{"\n"}{end}')
while IFS= read -r line; do
  array=($line)
  if [ "${array[1]}" = "false" ];
  then
    installplan="${array[0]}"
  fi
done <<< "$installplans"
pe "kubectl-s patch installplans ${installplan} -n operators --type='merge' -p \"{\\\"spec\\\":{\\\"approved\\\":true}}\""
c "Let's check that the operator is getting updated."
pe "kubectl-s get csv -n operators"
pe "kubectl-s get pods -n operators"

c "Let's uninstall the operator by deleting the subscription and the clusterserviceversion."
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke.kubeconfig kubectl get csv -n operators -o name | wc -l) -eq 1 ]'

csv=$(kubectl-s get csv -n operators -o name)
sub=$(kubectl-s get subscription -n operators -o name)
pe "kubectl-s delete $sub -n operators"
pe "kubectl-s delete $csv -n operators"
c "And check that the operator is deleted."
pe "kubectl-s get pods -n operators"

c "Finally OLM can get removed by deleting the managedclusteraddon on the hub if it was manually created."
c "Here we will just patch the placement so that our spoke clusters are not covered by the rule anymore."
# pe "kubectl-hub delete managedclusteraddons.addon.open-cluster-management.io -n spoke olm-addon"
pe "kubectl-hub patch Placement -n open-cluster-management non-openshift --type='merge' -p  \"{\\\"spec\\\":{\\\"predicates\\\":[{\\\"requiredClusterSelector\\\":{\\\"labelSelector\\\":{\\\"matchLabels\\\":{\\\"demo\\\":\\\"finished\\\"}}}}]}}\""
pe "kubectl-hub get placements -A"
wait_command '[ $(KUBECONFIG=${DEMO_DIR}/.demo/spoke.kubeconfig kubectl get pods -n olm -o name | wc -l) -lt 2 ]'
pe "kubectl-s get pods -n olm"


# skip end
}

c "That's it! Thank you for watching."

