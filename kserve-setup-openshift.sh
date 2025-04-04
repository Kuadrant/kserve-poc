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


echo "Do you have Kuadrant and its dependencies (Istio, cert-manager, API Gateway) already installed on your cluster, y/n ?"
read kuadrant


if [ "${kuadrant}" != "y" ]; then
echo "Installing API gateway ..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

echo "Installing certmanager ..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.3 \
  --set crds.enabled=true

echo "Installing Istio ..."
helm install sail-operator \
        --create-namespace \
        --namespace istio-system \
        --wait \
        --timeout=300s \
        https://github.com/istio-ecosystem/sail-operator/releases/download/0.1.0/sail-operator-0.1.0.tgz

kubectl apply -f -<<EOF
apiVersion: sailoperator.io/v1alpha1
kind: Istio
metadata:
  name: default
spec:
  # Supported values for sail-operator v0.1.0 are [v1.22.4,v1.23.0]
  version: v1.23.0
  namespace: istio-system
  # Disable autoscaling to reduce dev resources
  values:
    pilot:
      autoscaleEnabled: false
EOF

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

echo "Kuadrant installed, ready to apply policies."

else
  echo "Using existing Kuadrant setup, continuing..."
fi

echo "Installing kserve CRD's ..."
helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.15.0 --namespace kserve --create-namespace --wait


echo "Create a Gateway..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: istio
  listeners:
    - name: http-wildcard
      hostname: "*.$KUADRANT_ZONE_ROOT_DOMAIN"
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https-widlcard
      hostname: "*.$KUADRANT_ZONE_ROOT_DOMAIN"
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: https-widlcard
            namespace: kserve
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF

echo "Installing kserve controller..."
helm install kserve oci://ghcr.io/kserve/charts/kserve --version v0.15.0 --namespace kserve --create-namespace --wait \
--set kserve.controller.gateway.ingressGateway.enableGatewayApi=true \
--set kserve.controller.gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway \
--set kserve.controller.deploymentMode=RawDeployment \
--set kserve.controller.gateway.domain=$KUADRANT_ZONE_ROOT_DOMAIN

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

echo "Waiting for the InferenceService..." 
kubectl wait inferenceservice sklearn-v2-iris \
  --for=condition=Ready \
  --timeout=300s

echo "Creating DNS secrets"
kubectl -n kserve create secret generic kserve-aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

kubectl -n cert-manager create secret generic kserve-aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

echo "Creating cluster issuer"
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: kserve-self-signed
spec:
  selfSigned: {}
EOF

echo "Creating TLSPolicy"
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: TLSPolicy
metadata:
  name: kserve-tls
  namespace: kserve
spec:
  targetRef:
    name: kserve-ingress-gateway
    group: gateway.networking.k8s.io
    kind: Gateway
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: kserve-self-signed
EOF
sleep 10
echo "Creating DNSPolicy"
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: DNSPolicy
metadata:
  name: kserve-dnspolicy
  namespace: kserve
spec:
  loadBalancing:
    defaultGeo: true
    geo: GEO-NA
    weight: 120
  targetRef:
    name: kserve-ingress-gateway
    group: gateway.networking.k8s.io
    kind: Gateway
  providerRefs:
  - name: kserve-aws-credentials
EOF

sleep 10

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
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
  curl -k -H "Content-Type: application/json" \
       https://sklearn-v2-iris-predictor-default.$KUADRANT_ZONE_ROOT_DOMAIN/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
  echo ""
  sleep 3
done
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

echo "Starting a curl loop to test rate limiting (it will run for 20 seconds)..."
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
  curl -k -H "Content-Type: application/json" \
       https://sklearn-v2-iris-predictor-default.$KUADRANT_ZONE_ROOT_DOMAIN/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
  echo ""
  sleep 3
done
echo "Rate limiting test loop ended."

echo "Applying AuthPolicy 'kserve-auth' for Gateway..."
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: kserve-auth
  namespace: kserve
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: kserve-ingress-gateway
  defaults:
   when:

     - predicate: "request.path != '/health'"
   rules:
    authorization:
      deny-all:
        opa:
          rego: "allow = false"
    response:
      unauthorized:
        headers:
          "content-type":
            value: application/json
        body:
          value: |
            {
              "error": "Forbidden",
              "message": "Access denied by default by the gateway operator. If you are the administrator of the service, create a specific auth policy for the route."
            }
EOF

echo "Checking AuthPolicy status for 'kserve-auth'..."
kubectl get AuthPolicy kserve-auth -n kserve -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
echo ""


echo "Setting up API Key auth flow"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bob-key
  namespace: kuadrant-system
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: toystore
  annotations:
    secret.kuadrant.io/user-id: bob
stringData:
  api_key: IAMBOB
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  name: alice-key
  namespace: kuadrant-system
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: toystore
  annotations:
    secret.kuadrant.io/user-id: alice
stringData:
  api_key: IAMALICE
type: Opaque
EOF

echo "Applying AuthPolicy 'kserve-override-auth' for HTTPRoute..."
kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: kserve-override-auth
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: sklearn-v2-iris-predictor
  defaults:
   when:
     - predicate: "request.path != '/health'"  
   rules:
    authentication:
      "api-key-users":
        apiKey:
          selector:
            matchLabels:
              app: toystore
        credentials:
          authorizationHeader:
            prefix: APIKEY
    response:
      success:
        filters:
          "identity":
            json:
              properties:
                "userid":
                  selector: auth.identity.metadata.annotations.secret\.kuadrant\.io/user-id
EOF

echo "Checking AuthPolicy status for 'kserve-override-auth'..."
kubectl get AuthPolicy kserve-override-auth -n default -o=jsonpath='{.status.conditions[?(@.type=="Accepted")].message}{"\n"}{.status.conditions[?(@.type=="Enforced")].message}'
echo ""


echo "Starting a curl loop to test auth succeeds with correct API Key (it will run for 20 seconds)..."
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
  curl -k -H "Content-Type: application/json" \
      -H "Authorization: APIKEY IAMALICE" \
       https://sklearn-v2-iris-predictor-default.$KUADRANT_ZONE_ROOT_DOMAIN/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
  echo ""
  sleep 3
done
echo "Auth test loop ended."

