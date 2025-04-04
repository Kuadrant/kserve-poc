#!/bin/bash


# Remember to start cloud-provider-kind first:
# sudo cloud-provider-kind --enable-lb-port-mapping=true

#set -euo pipefail

: "${KUADRANT_AWS_ACCESS_KEY_ID:?KUADRANT_AWS_ACCESS_KEY_ID not set}"
: "${KUADRANT_AWS_SECRET_ACCESS_KEY:?KUADRANT_AWS_SECRET_ACCESS_KEY not set}"
: "${KUADRANT_ZONE_ROOT_DOMAIN:?KUADRANT_ZONE_ROOT_DOMAIN not set}"

KSERVE_DOMAIN="kserve-poc.${KUADRANT_ZONE_ROOT_DOMAIN}"

echo "Setting up certificate and dns config"
kubectl -n kserve create secret generic aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

kubectl -n cert-manager create secret generic aws-credentials \
  --type=kuadrant.io/aws \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY

echo "Updating kserve config to use domain=$KSERVE_DOMAIN."
helm upgrade kserve oci://ghcr.io/kserve/charts/kserve --version v0.15.0 --namespace kserve --create-namespace --wait \
  --set kserve.controller.gateway.ingressGateway.enableGatewayApi=true \
  --set kserve.controller.gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway \
  --set kserve.controller.deploymentMode=RawDeployment \
  --set kserve.controller.gateway.domain=$KSERVE_DOMAIN

echo "Checking KServe pods and services..."
kubectl get pods,svc -l serving.kserve.io/gateway=kserve-ingress-gateway -A

echo "Restarting kserve-controller-manager..."
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=300s

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: self-signed
spec:
  selfSigned: {}
EOF

echo "Applying TLSPolicy 'kserve-tls'..."
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
    name: self-signed
EOF

echo "Applying DNSPolicy 'kserve-dnspolicy'..."
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
  - name: aws-credentials
EOF

echo "Updating Gateway with hosts & https listeners..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kserve-ingress-gateway
  namespace: kserve
spec:
  gatewayClassName: envoy
  listeners:
    - name: http-predictor
      hostname: "sklearn-v2-iris-tls-dns-predictor-default.$KSERVE_DOMAIN"
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: http-default
      hostname: "sklearn-v2-iris-tls-dns-default.$KSERVE_DOMAIN"
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https-predictor
      hostname: "sklearn-v2-iris-tls-dns-predictor-default.$KSERVE_DOMAIN"
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: my-secret-predictor
            namespace: kserve
      allowedRoutes:
        namespaces:
          from: All
    - name: https-default
      hostname: "sklearn-v2-iris-tls-dns-default.$KSERVE_DOMAIN"
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: my-secret-default
            namespace: kserve
      allowedRoutes:
        namespaces:
          from: All
  infrastructure:
    labels:
      serving.kserve.io/gateway: kserve-ingress-gateway
EOF

echo "Applying InferenceService..."
kubectl apply -f - <<EOF
apiVersion: "serving.kserve.io/v1beta1"
kind: "InferenceService"
metadata:
  name: "sklearn-v2-iris-tls-dns"
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
kubectl wait inferenceservice sklearn-v2-iris-tls-dns \
  --for=condition=Ready \
  --timeout=300s

echo "Call Inference Predictor at IP $GATEWAY_HOST directly using https..."
curl -v -k -H "Host: sklearn-v2-iris-tls-dns-predictor-default.$KSERVE_DOMAIN" \
     -H "Content-Type: application/json" \
     https://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris-tls-dns:predict -d @/tmp/iris-input.json

dig sklearn-v2-iris-tls-dns-predictor-default.$KSERVE_DOMAIN
echo "If DNS is resolving, try curl via DNS using below command:"
echo "curl -v -k -H \"Content-Type: application/json\" https://sklearn-v2-iris-tls-dns-predictor-default.$KSERVE_DOMAIN/v1/models/sklearn-v2-iris-tls-dns:predict -d @/tmp/iris-input.json"
