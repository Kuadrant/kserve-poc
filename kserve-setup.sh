#!/bin/bash


# Remember to start cloud-provider-kind first:
# sudo cloud-provider-kind --enable-lb-port-mapping=true

set -euo pipefail

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cat <<EOF > "/tmp/iris-input.json"
{
  "instances": [
    [6.8,  2.8,  4.8,  1.4],
    [6.0,  3.4,  4.5,  1.6]
  ]
}
EOF

for cmd in kind helm kubectl curl; do
    if ! command_exists "$cmd"; then
        echo "Error: $cmd is required but not found - aborting."
        exit 1
    fi
done

if ! kind get clusters | grep -q "^kind$"; then
    echo "Creating kind cluster..."
    kind create cluster
else
    echo "kind cluster already exists, continuing"
fi

echo "Installing KServe..."
curl -s "https://raw.githubusercontent.com/kserve/kserve/release-0.15/hack/quick_install.sh" | bash

echo "Waiting for kserve-controller-manager to be ready..."
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=300s

echo "Installing Envoy Gateway..."
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.3.2 \
  -n envoy-gateway-system \
  --create-namespace \
  --set config.envoyGateway.extensionApis.enableEnvoyPatchPolicy=true # enable extensionApis

echo "Waiting for Envoy Gateway to be ready..."
if kubectl get pods -n envoy-gateway-system -l app=envoy-gateway >/dev/null 2>&1; then
    kubectl wait --for=condition=Ready pod -n envoy-gateway-system --selector=app.kubernetes.io/instance=eg --timeout=300s
else
    echo "Could not find pods with label 'app=envoy-gateway'"
fi

echo "Create GatewayClass..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

echo "Create Gateway..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF

echo "Waiting for kserve-ingress-gateway to obtain an address..."
for i in {1..30}; do
    GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
    if [ -n "$GATEWAY_HOST" ]; then
        echo "Gateway host obtained: $GATEWAY_HOST"
        break
    else
        echo "Not yet... waiting 10 seconds."
        sleep 10
    fi
done

if [ -z "${GATEWAY_HOST:-}" ]; then
    echo "Failed to obtain Gateway host. Aborting."
    exit 1
fi

echo "Upgrading KServe to v0.15.0-rc1..."
helm upgrade kserve oci://ghcr.io/kserve/charts/kserve --version v0.15.0-rc1 --namespace kserve --create-namespace --wait \
  --set kserve.controller.gateway.ingressGateway.enableGatewayApi=true \
  --set kserve.controller.gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway \
  --set kserve.controller.deploymentMode=RawDeployment

echo "Checking KServe pods and services..."
kubectl get pods,svc -l serving.kserve.io/gateway=kserve-ingress-gateway -A

echo "Restarting kserve-controller-manager..."
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=300s

sleep 10  # TODO: fix this

echo "Applying InferenceService..."
kubectl apply -f - <<EOF
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-v2-iris"
spec:
  predictor:
    model:
      args: ["--enable_docs_url=True"]
      modelFormat:
        name: sklearn
      protocolVersion: v2
      runtime: kserve-sklearnserver
      storageUri: "gs://kfserving-examples/models/sklearn/1.0/model"
EOF

echo "Waiting for the InferenceService..." # TODO: fix this
sleep 60

GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
if [ -z "${GATEWAY_HOST:-}" ]; then
    echo "Failed to re-obtain Gateway host. Aborting."
    exit 1
fi

echo "Call Inference Predictor..."
curl -v -H "Host: sklearn-v2-iris-predictor-default.example.com" \
     -H "Content-Type: application/json" \
     http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json

echo "Adding Kuadrant helm repo..."
helm repo add kuadrant https://kuadrant.io/helm-charts/ --force-update

echo "Installing Kuadrant Operator..."
helm install kuadrant-operator kuadrant/kuadrant-operator --create-namespace --namespace kuadrant-system

echo "Applying Kuadrant CR..."
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
EOF

echo "Applying RateLimitPolicy 'kserve-rlp'..."
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: kserve-rlp
  namespace: kserve
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: kserve-ingress-gateway
  defaults:
    limits:
      "low-limit":
        rates:
        - limit: 1
          window: 10s
EOF

echo "Checking RateLimitPolicy status for 'kserve-rlp'..."
kubectl get ratelimitpolicy kserve-rlp -n kserve -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
echo ""

echo "Starting a curl loop to test rate limiting (it will run for 20 seconds)..."
(
  while true; do 
    curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
    echo ""
    sleep 3
  done
) &
CURL_LOOP_PID=$!
sleep 20
kill $CURL_LOOP_PID
echo "Rate limiting test loop ended."

echo "Applying RateLimitPolicy for HTTPRoute..."
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: kserve-override-rlp
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: sklearn-v2-iris-predictor
  limits:
    "override-limit":
      rates:
      - limit: 4
        window: 10s
EOF

echo "Checking RateLimitPolicy status for 'kserve-override-rlp'..."
kubectl get ratelimitpolicy kserve-override-rlp -n default -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
echo ""

echo "cURL loop – Ctrl+C when you're done..."
while true; do 
    curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
    echo ""
    sleep 2
done
