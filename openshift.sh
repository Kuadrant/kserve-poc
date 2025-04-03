#!/bin/bash

# Prereq Kuadrant, istio, gatewayapi certamanger installed on openshift cluster
: "${KUADRANT_AWS_ACCESS_KEY_ID:?KUADRANT_AWS_ACCESS_KEY_ID not set}"
: "${KUADRANT_AWS_SECRET_ACCESS_KEY:?KUADRANT_AWS_SECRET_ACCESS_KEY not set}"
: "${KUADRANT_ZONE_ROOT_DOMAIN:?KUADRANT_ZONE_ROOT_DOMAIN not set}"


echo "Installing kserve CRD's ..."
helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.15.0 --namespace kserve --create-namespace --wait


echo "Creating a gateway ..."
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

echo "Creating AWS secrets..."
kubectl -n kserve create secret generic kserve-aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

kubectl -n cert-manager create secret generic kserve-aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

echo "Creating clusterIssuer..."
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: kserve-self-signed
spec:
  selfSigned: {}
EOF

echo "Creating TLSPolicy..."
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

echo "Creating DNSPolicy..."
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

echo "Creating InferenceService"
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

kubectl wait inferenceservice sklearn-v2-iris \
  --for=condition=Ready \
  --timeout=300s

echo "Applying RateLimitPolicy and Auth Policies "
if [[ ! -x "./rlp-ap.sh" ]]; then
        chmod +x ./rlp-ap.sh
    fi
./rlp-ap.sh
