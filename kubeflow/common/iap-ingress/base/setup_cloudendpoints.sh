#!/bin/bash
#
# A simple shell script to configure a cloud endpoint
set -x
[ -z ${NAMESPACE} ] && echo Error NAMESPACE must be set && exit 1
[ -z ${SERVICE} ] && echo Error SERVICE must be set && exit 1
[ -z ${INGRESS_NAME} ] && echo Error INGRESS_NAME must be set && exit 1
[ -z ${ENDPOINT_NAME} ] && echo Error ENDPOINT_NAME must be set && exit 1

__dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
if [ -z ${PROJECT} ]; then
    echo Error unable to fetch PROJECT from compute metadata
    exit 1
fi

PROJECT_NUM=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/numeric-project-id)
if [ -z ${PROJECT_NUM} ]; then
    echo Error unable to fetch PROJECT_NUM from compute metadata
    exit 1
fi

# Activate the service account
if [ ! -z "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
    # As of 0.7.0 we should be using workload identity and never setting GOOGLE_APPLICATION_CREDENTIALS.
    # But we kept this for backwards compatibility but can remove later.
    gcloud auth activate-service-account --key-file=${GOOGLE_APPLICATION_CREDENTIALS}
fi

# Print out the config for debugging
gcloud config list
gcloud auth list

set_endpoint () {
    NODE_PORT=$(kubectl --namespace=${NAMESPACE} get svc ${SERVICE} -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    echo "[DEBUG] node port is ${NODE_PORT}"

    BACKEND_NAME=""
    while [[ -z ${BACKEND_NAME} ]]; do
    BACKENDS=$(kubectl --namespace=${NAMESPACE} get ingress ${INGRESS_NAME} -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}')
    echo "[DEBUG] fetching backends info with ${INGRESS_NAME}: ${BACKENDS}"
    BACKEND_NAME=$(echo $BACKENDS | grep -o "k8s-be-${NODE_PORT}--[0-9a-z]\+")
    echo "[DEBUG] backend name is ${BACKEND_NAME}"
    sleep 2
    done

    BACKEND_ID=""
    while [[ -z ${BACKEND_ID} ]]; do
    BACKEND_ID=$(gcloud compute --project=${PROJECT} backend-services list --filter=name~${BACKEND_NAME} --format='value(id)')
    echo "[DEBUG] Waiting for backend id PROJECT=${PROJECT} NAMESPACE=${NAMESPACE} SERVICE=${SERVICE} filter=name~${BACKEND_NAME}"
    sleep 2
    done
    echo BACKEND_ID=${BACKEND_ID}

    JWT_AUDIENCE="/projects/${PROJECT_NUM}/global/backendServices/${BACKEND_ID}"
    
    # We use a regular expression to obtain the IP address of the target Ingress, assuming IPv4 standard.
    INGRESS_TARGET_IP=$(kubectl get ingress --all-namespaces | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)")
    
    echo "[DEBUG] ENDPOINT_NAME = ${ENDPOINT_NAME}"
    echo "[DEBUG] INGRESS_TARGET_IP = ${INGRESS_TARGET_IP}"
    echo "[DEBUG] JWT_AUDIENCE = ${JWT_AUDIENCE}"
    
    # Create OpenAPI specification for the RESTful Cloud Endpoint
    sed "s|JWT_AUDIENCE|${JWT_AUDIENCE}|;s|ENDPOINT_NAME|${ENDPOINT_NAME}|;s|INGRESS_TARGET_IP|${INGRESS_TARGET_IP}|" /var/envoy-config/swagger_template.yaml > openapi.yaml
    
    # Deploy and enable the endpoint
    gcloud endpoints services deploy openapi.yaml
    gcloud services enable ${ENDPOINT_NAME}

    # Create IAM resources used by the endpoint
    gcloud endpoints services add-iam-policy-binding ${ENDPOINT_NAME} \
        --member serviceAccount:${SERVICE_ACCOUNTNAME} \
        --role roles/servicemanagement.serviceController
    gcloud projects add-iam-policy-binding ${PROJECT} \
        --member serviceAccount:${SERVICE_ACCOUNTNAME} \
        --role roles/cloudtrace.agent
}

while true; do
    set_endpoint
    echo "Sleeping 30 seconds..."
    sleep 30
done
