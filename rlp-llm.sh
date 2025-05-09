#!/bin/bash



kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: openai-headers-rlp
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: huggingface-llm 
  limits:
    "openai-total-tokens-limit":
      rates:
      - limit: 5
        window: 10s
      counters:
        - expression: context.request.http.headers.x-kuadrant-openai-total-tokens
EOF




kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: openai-headers-rlp
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: huggingface-llm
  limits:
    "per-user":
      rates:
      - limit: 1
        window: 15s
      # counters:
      # - metadata.filter_metadata.envoy\.filters\.http\.ext_authz.identity.userid
      counters:
      - expression: "int(request.headers['x-kuadrant-openai-total-tokens'])"
EOF


kubectl apply -f - <<EOF
apiVersion: limitador.kuadrant.io/v1alpha1
kind: Limitador
metadata:
  name: limitador
spec:
  verbosity: 3
EOF









GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
SERVICE_HOSTNAME=$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.url}' | cut -d "/" -f 3)

echo "Calling SmolLM LLM ..."
curl -v http://$GATEWAY_HOST/openai/v1/completions \
  -H "content-type: application/json" \
  -H "Host: $SERVICE_HOSTNAME" \
  -d '{"model": "llm", "prompt": "What is Kubernetes", "stream": false, "max_tokens": 10}'



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

