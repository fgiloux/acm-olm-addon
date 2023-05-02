#!/usr/bin/env bash

set -o errexit

export DEMO_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

source ${DEMO_DIR}/helper.sh

while getopts ":a:p:t:" opt; do
  case ${opt} in
    a )
      IP=${OPTARG}
      ;;
    p )
      HTTP_PORT=${OPTARG}
      ;;
    t )
      TLS_PORT=${OPTARG}
      ;;
    \? ) echo "Usage: $(basename $0) [-a IPADRESS] [-p STARTING_HTTP_PORT] [-t STARTING_TLS_PORT]"
         echo " If no address is provided, 192.168.130.1 is used"
	 echo " If no starting port is provided 8080 and 8443 are used"
         echo " Port numbers are increased by 100 for each subsequent cluster"
	 exit 0
   esac
done

echo " It is recommended to increase OS file watches before running the demo, e.g.:"
echo " $ sudo sysctl -w fs.inotify.max_user_watches=2097152"
echo " $ sudo sysctl -w fs.inotify.max_user_instances=256"

IP=${IP:-192.168.130.1}
HTTP_PORT=${HTTP_PORT:-8080}
TLS_PORT=${TLS_PORT:-8443}

RUN_DIR=${DEMO_DIR}/.demo
mkdir -p ${RUN_DIR}

# hub cluster configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/hub.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = ${HTTP_PORT}" ${RUN_DIR}/hub.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = ${TLS_PORT}" ${RUN_DIR}/hub.cfg

# management configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/management.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = $((HTTP_PORT + 100))" ${RUN_DIR}/management.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = $((TLS_PORT + 100))" ${RUN_DIR}/management.cfg

# spoke configuration
yq ".networking.apiServerAddress = \"${IP}\"" ${DEMO_DIR}/kind.cfg  > ${RUN_DIR}/spoke.cfg
yq -i ".nodes[0].extraPortMappings[0].hostPort = $((HTTP_PORT + 200))" ${RUN_DIR}/spoke.cfg
yq -i ".nodes[0].extraPortMappings[1].hostPort = $((TLS_PORT + 200))" ${RUN_DIR}/spoke.cfg

echo "Creating kind clusters"
kind create cluster --name hub --kubeconfig ${RUN_DIR}/hub-orig.kubeconfig --config ${RUN_DIR}/hub.cfg
kind create cluster --name management --kubeconfig ${RUN_DIR}/management.kubeconfig --config ${RUN_DIR}/management.cfg
kind create cluster --name spoke --kubeconfig ${RUN_DIR}/spoke.kubeconfig --config ${RUN_DIR}/spoke.cfg

echo "Deploying OCM registration operator"
pushd ${RUN_DIR}
if [ ! -d "registration-operator" ];
then
  git clone git@github.com:open-cluster-management-io/registration-operator.git
fi
pushd registration-operator
# export IMAGE_TAG=v0.10.0
export HUB_KUBECONFIG=${RUN_DIR}/hub.kubeconfig
export EXTERNAL_MANAGED_KUBECONFIG=${RUN_DIR}/spoke.kubeconfig

KUBECONFIG=${RUN_DIR}/hub-orig.kubeconfig make deploy-hub
# If the hub components were to be deployed in hosted mode
# export EXTERNAL_HUB_KUBECONFIG=${RUN_DIR}/hub.kubeconfig
# KUBECONFIG=${RUN_DIR}/management.kubeconfig make deploy-hub-hosted
# KUBECONFIG=${RUN_DIR}/management.kubeconfig kubectl apply -f webhook-svc.yaml

KUBECONFIG=${RUN_DIR}/management.kubeconfig  MANAGED_CLUSTER_NAME=management make deploy-spoke
wait_command '[ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep management | wc -l) -eq 1 ]' 60
if [ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep management | wc -l) -ne 1 ]; then
  echo "Error: CSR missing for the registration of the management cluster"
  exit 1
fi
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep management | xargs kubectl certificate approve --kubeconfig=${RUN_DIR}/hub.kubeconfig
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters management --type='merge' -p '{"spec":{"hubAcceptsClient":true}}'
caBundle=$(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get managedclusters management -o jsonpath='{.spec.managedClusterClientConfigs[].caBundle}')
url=$(KUBECONFIG=${RUN_DIR}/management.kubeconfig kubectl config view -o jsonpath='{.clusters[].cluster.server}')
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters management --type='merge' -p "{\"spec\":{\"managedClusterClientConfigs\": [{\"caBundle\":\"${caBundle}\", \"url\":\"${url}\"}]}}"
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl label managedcluster management olm=false

KUBECONFIG=${RUN_DIR}/management.kubeconfig  MANAGED_CLUSTER_NAME=spoke make deploy-spoke-hosted
wait_command '[ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep spoke | wc -l) -eq 1 ]' 60
if [ $(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep spoke | wc -l) -ne 1 ]; then
  echo "Error: CSR missing for the registration of the spoke cluster"
  exit 1
fi
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get csr -o name | grep spoke | xargs kubectl certificate approve --kubeconfig=${RUN_DIR}/hub.kubeconfig
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke --type='merge' -p '{"spec":{"hubAcceptsClient":true}}'
caBundle=$(KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl get managedclusters spoke -o jsonpath='{.spec.managedClusterClientConfigs[].caBundle}')
url=$(KUBECONFIG=${RUN_DIR}/spoke.kubeconfig kubectl config view -o jsonpath='{.clusters[].cluster.server}')
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl patch managedclusters spoke --type='merge' -p "{\"spec\":{\"managedClusterClientConfigs\": [{\"caBundle\":\"${caBundle}\", \"url\":\"${url}\"}]}}"
KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl label managedcluster spoke olm=true

KUBECONFIG=${RUN_DIR}/hub.kubeconfig kubectl apply -k https://github.com/open-cluster-management-io/addon-framework/deploy/

# Somehow missing
KUBECONFIG=${RUN_DIR}/management.kubeconfig kubectl create rolebinding -n kube-system open-cluster-management:management:management-klusterlet-registration:agent --role=extension-apiserver-authentication-reader --serviceaccount=open-cluster-management-agent:klusterlet-registration-sa
popd
popd
