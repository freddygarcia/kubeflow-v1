#!/bin/bash
#
# A simple shell script to configure the health checks by using gcloud.
set -x

[ -z ${NAMESPACE} ] && echo Error NAMESPACE must be set && exit 1
[ -z ${SERVICE} ] && echo Error SERVICE must be set && exit 1
[ -z ${INGRESS_NAME} ] && echo Error INGRESS_NAME must be set && exit 1

PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
if [ -z ${PROJECT} ]; then
    echo Error unable to fetch PROJECT from compute metadata
    exit 1
fi

if [[ ! -z "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    # TODO(jlewi): As of 0.7 we should always be using workload identity. We can remove it post 0.7.0 once we have workload identity
    # fully working
    # Activate the service account, allow 5 retries
    for i in {1..5}; do gcloud auth activate-service-account --key-file=${GOOGLE_APPLICATION_CREDENTIALS} && break || sleep 10; done
fi

set_health_check () {
    NODE_PORT=$(kubectl --namespace=${NAMESPACE} get svc ${SERVICE} -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
    echo node port is ${NODE_PORT}

    while [[ -z ${BACKEND_NAME} ]]; do
    BACKENDS=$(kubectl --namespace=${NAMESPACE} get ingress ${INGRESS_NAME} -o jsonpath='{.metadata.annotations.ingress\.kubernetes\.io/backends}')
    echo "fetching backends info with ${INGRESS_NAME}: ${BACKENDS}"
    BACKEND_NAME=$(echo $BACKENDS | grep -o "k8s-be-${NODE_PORT}--[0-9a-z]\+")
    echo "backend name is ${BACKEND_NAME}"
    sleep 2
    done

    while [[ -z ${BACKEND_SERVICE} ]]; do
    BACKEND_SERVICE=$(gcloud --project=${PROJECT} compute backend-services list --filter=name~${BACKEND_NAME} --uri);
    echo "Waiting for the backend-services resource PROJECT=${PROJECT} BACKEND_NAME=${BACKEND_NAME} SERVICE=${SERVICE}...";
    sleep 2;
    done

    while [[ -z ${HEALTH_CHECK_URI} ]]; do
    HEALTH_CHECK_URI=$(gcloud compute --project=${PROJECT} health-checks list --filter=name~${BACKEND_NAME} --uri);
    echo "Waiting for the healthcheck resource PROJECT=${PROJECT} NODEPORT=${NODE_PORT} SERVICE=${SERVICE}...";
    sleep 2;
    done
    echo health check URI is ${HEALTH_CHECK_URI}

    # See: https://cloud.google.com/service-mesh/docs/iap-integration#deploying_the_load_balancer
    HC_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="status-port")].nodePort}')
    echo Setting BackendConfig healthCheck.port to: ${HC_INGRESS_PORT}
    kubectl patch backendconfig iap-backendconfig -n ${NAMESPACE} --type json -p '[{"op": "replace", "path": "/spec/healthCheck/port", "value": '${HC_INGRESS_PORT}'}]'
    
    HC_INGRESS_PATH=$(kubectl get pods -n istio-system -l app=istio-ingressgateway -o jsonpath='{.items[0].spec.containers[?(@.name=="istio-proxy")].readinessProbe.httpGet.path}')
    echo Setting BackendConfig healthCheck.requestPath to ${HC_INGRESS_PATH}
    kubectl patch backendconfig iap-backendconfig -n ${NAMESPACE} --type json -p '[{"op": "replace", "path": "/spec/healthCheck/requestPath", "value": "'${HC_INGRESS_PATH}'"}]'
}

while true; do
    set_health_check
    echo "Backend updated successfully. Waiting 1 hour before updating again."
    sleep 3600
done
