#!/usr/bin/env bash

#Description: Kyma CLI Integration plan on GKE. This scripts implements a pipeline that consists of many steps. The purpose is to install and test Kyma using the CLI on real GKE cluster.
#
#
#Expected vars:
#
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - CLOUDSDK_CORE_PROJECT - GCP project for all GCP resources used during execution (Service Account, IP Address, DNS Zone, image registry etc.)
# - CLOUDSDK_COMPUTE_REGION - GCP compute region
# - CLOUDSDK_DNS_ZONE_NAME - GCP zone name (not its DNS name!)
# - GOOGLE_APPLICATION_CREDENTIALS - GCP Service Account key file path
# - MACHINE_TYPE (optional): GKE machine type
# - CLUSTER_VERSION (optional): GKE cluster version
#
#Permissions: In order to run this script you need to use a service account with permissions equivalent to the following GCP roles:
# - Compute Admin
# - Kubernetes Engine Admin
# - Kubernetes Engine Cluster Admin
# - DNS Administrator
# - Service Account User
# - Storage Admin
# - Compute Network Admin

set -o errexit

discoverUnsetVar=false

for var in KYMA_PROJECT_DIR CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION CLOUDSDK_DNS_ZONE_NAME GOOGLE_APPLICATION_CREDENTIALS; do
    if [ -z "${!var}" ] ; then
        echo "ERROR: $var is not set"
        discoverUnsetVar=true
    fi
done
if [ "${discoverUnsetVar}" = true ] ; then
    exit 1
fi

readonly SUITE_NAME="testsuite-all-$(date '+%Y-%m-%d-%H-%M')"
readonly CONCURRENCY=5
#Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"
# shellcheck source=prow/scripts/library.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/library.sh"
# shellcheck disable=SC1090
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/testing-helpers.sh"

trap gkeCleanup EXIT INT

RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c10)
readonly COMMON_NAME_PREFIX="cli-integration-test-gke"
COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")

### Cluster name must be less than 40 characters!
export CLUSTER_NAME="${COMMON_NAME}"

export GCLOUD_NETWORK_NAME="${COMMON_NAME_PREFIX}-net"
export GCLOUD_SUBNET_NAME="${COMMON_NAME_PREFIX}-subnet"

### For provision-gke-cluster.sh
export GCLOUD_PROJECT_NAME="${CLOUDSDK_CORE_PROJECT}"
export GCLOUD_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE}"

#Local variables
DNS_SUBDOMAIN="${COMMON_NAME}"

#Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"

shout "Authenticate"
date
init
DNS_DOMAIN="$(gcloud dns managed-zones describe "${CLOUDSDK_DNS_ZONE_NAME}" --format="value(dnsName)")"


shout "Reserve IP Address for Ingressgateway"
date
GATEWAY_IP_ADDRESS_NAME="${COMMON_NAME}"
GATEWAY_IP_ADDRESS=$(IP_ADDRESS_NAME=${GATEWAY_IP_ADDRESS_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/reserve-ip-address.sh")
CLEANUP_GATEWAY_IP_ADDRESS="true"
echo "Created IP Address for Ingressgateway: ${GATEWAY_IP_ADDRESS}"


shout "Create DNS Record for Ingressgateway IP"
date
GATEWAY_DNS_FULL_NAME="*.${DNS_SUBDOMAIN}.${DNS_DOMAIN}"
CLEANUP_GATEWAY_DNS_RECORD="true"
IP_ADDRESS=${GATEWAY_IP_ADDRESS} DNS_FULL_NAME=${GATEWAY_DNS_FULL_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-dns-record.sh"


NETWORK_EXISTS=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/network-exists.sh")
if [ "$NETWORK_EXISTS" -gt 0 ]; then
    shout "Create ${GCLOUD_NETWORK_NAME} network with ${GCLOUD_SUBNET_NAME} subnet"
    date
    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-network-with-subnet.sh"
else
    shout "Network ${GCLOUD_NETWORK_NAME} exists"
fi


shout "Provision cluster: \"${CLUSTER_NAME}\""
date
export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
if [ -z "$MACHINE_TYPE" ]; then
      export MACHINE_TYPE="${DEFAULT_MACHINE_TYPE}"
fi
if [ -z "${CLUSTER_VERSION}" ]; then
      export CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION}"
fi
CLEANUP_CLUSTER="true"
"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/provision-gke-cluster.sh"


shout "Generate self-signed certificate"
date
DOMAIN="${DNS_SUBDOMAIN}.${DNS_DOMAIN%?}"
export DOMAIN
CERT_KEY=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/generate-self-signed-cert.sh")
TLS_CERT=$(echo "${CERT_KEY}" | head -1)
TLS_KEY=$(echo "${CERT_KEY}" | tail -1)


shout "Building Kyma CLI"
date
cd "${KYMA_PROJECT_DIR}/cli"
make build-linux
mv "${KYMA_PROJECT_DIR}/cli/bin/kyma-linux" "${KYMA_PROJECT_DIR}/cli/bin/kyma"
export PATH="${KYMA_PROJECT_DIR}/cli/bin:${PATH}"


COMPONENT_OVERRIDES_FILE="component-overrides.yaml"
COMPONENT_OVERRIDES=$(cat << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: "installation-config-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
data:
  global.loadBalancerIP: "${GATEWAY_IP_ADDRESS}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: "istio-overrides"
  namespace: "kyma-installer"
  labels:
    installer: overrides
    kyma-project.io/installation: ""
    component: istio
data:
  kyma_istio_operator: |
    apiVersion: install.istio.io/v1alpha1
    kind: IstioOperator
    metadata:
      namespace: istio-system
    spec:
      components:
        ingressGateways:
          - name: istio-ingressgateway
            k8s:
              service:
                loadBalancerIP: ${GATEWAY_IP_ADDRESS}
                type: LoadBalancer
EOF
)

echo "${COMPONENT_OVERRIDES}" > "${COMPONENT_OVERRIDES_FILE}"

shout "Installing Kyma"
date
kyma install \
    --ci \
    --source master \
    -o "${COMPONENT_OVERRIDES_FILE}" \
    --domain "${DOMAIN}" \
    --tls-cert "${TLS_CERT}" \
    --tls-key "${TLS_KEY}" \
    --timeout 90m

shout "Checking the versions"
date
kyma version


if [ -n "$(kubectl get  service -n kyma-system apiserver-proxy-ssl --ignore-not-found)" ]; then
    shout "Create DNS Record for Apiserver proxy IP"
    date
    APISERVER_IP_ADDRESS=$(kubectl get  service -n kyma-system apiserver-proxy-ssl -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    APISERVER_DNS_FULL_NAME="apiserver.${DNS_SUBDOMAIN}.${DNS_DOMAIN}"
    CLEANUP_APISERVER_DNS_RECORD="true"
    IP_ADDRESS=${APISERVER_IP_ADDRESS} DNS_FULL_NAME=${APISERVER_DNS_FULL_NAME} "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-dns-record.sh"
fi

shout "Create local resources for a sample Function"
date

kyma init function

shout "Apply local resources for the Function to the Kyma cluster"
date

kyma apply function

sleep 30

shout "Check if the Function is running"
date

attempts=3
for ((i=1; i<=attempts; i++)); do
    set +e
    result=$(kubectl get pods -lserverless.kyma-project.io/function-name=first-function,serverless.kyma-project.io/resource=deployment -o jsonpath='{.items[0].status.phase}')
    set -e
    if [[ "$result" == *"Running"* ]]; then
        echo "The Function is in Running state"
        break
    elif [[ "${i}" == "${attempts}" ]]; then
        echo "ERROR: The Function is in ${result} state"
        exit 1
    fi
    echo "Sleep for 15 seconds"
    sleep 15
done

shout "Running Kyma tests"
date

kyma test run \
    --name "${SUITE_NAME}" \
    --concurrency "${CONCURRENCY}" \
    --max-retries 1 \
    --timeout "1h" \
    --watch \
    --non-interactive


echo "Test Summary"
kyma test status "${SUITE_NAME}" -owide

statusSucceeded=$(kubectl get cts "${SUITE_NAME}"  -ojsonpath="{.status.conditions[?(@.type=='Succeeded')]}")
if [[ "${statusSucceeded}" != *"True"* ]]; then
    echo "- Fetching logs due to test suite failure"

    echo "- Fetching logs from testing pods in Failed status..."
    kyma test logs "${SUITE_NAME}" --test-status Failed

    echo "- Fetching logs from testing pods in Unknown status..."
    kyma test logs "${SUITE_NAME}" --test-status Unknown

    echo "- Fetching logs from testing pods in Running status due to running afer test suite timeout..."
    kyma test logs "${SUITE_NAME}" --test-status Running

    echo "ClusterTestSuite details"
    kubectl get cts "${SUITE_NAME}" -oyaml

    exit 1
fi

echo "ClusterTestSuite details"
kubectl get cts "${SUITE_NAME}" -oyaml


shout "Success"

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"
