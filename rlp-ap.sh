#!/bin/bash

# Pre-req: kserve-setup.sh

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
  curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
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
  curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
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

echo "Starting a curl loop to test auth fails (it will run for 20 seconds)..."
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
 curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
    echo ""
    sleep 3
done
echo "Auth test loop ended."


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

echo "Starting a curl loop to test auth fails with wrong API Key (it will run for 20 seconds)..."
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
  curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         --write-out '%{http_code}\n' \
         --output /dev/null \
         -H "Content-Type: application/json" \
         -H 'Authorization: APIKEY IAMALICED' \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
    sleep 2
done
echo "Auth test loop ended."

echo "Starting a curl loop to test auth succeeds with correct API Key (it will run for 20 seconds)..."
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt 20 ]; do
 curl -s -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         --write-out '%{http_code}\n' \
         --output /dev/null \
         -H "Content-Type: application/json" \
         -H 'Authorization: APIKEY IAMALICE' \
         http://"$GATEWAY_HOST"/v1/models/sklearn-v2-iris:predict -d @/tmp/iris-input.json
    sleep 2
done
echo "Auth test loop ended."
