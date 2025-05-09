#!/bin/bash

# Pre-req: kserve-setup.sh

# https://kserve.github.io/website/latest/modelserving/v1beta1/llm/huggingface/text_generation/

# Check that HF_TOKEN is set
if [ -z "$HF_TOKEN" ]; then
    echo "Missing the HF_TOKEN environment variable. Export one before running this script! You can get one at: https://huggingface.co/settings/tokens/new?tokenType=write"
    exit 1
fi

kubectl delete inferenceservice/huggingface-llm

echo "Creating HuggingFace Secret ..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hf-secret
type: Opaque
stringData:
  HF_TOKEN: ${HF_TOKEN}
EOF

echo "Creating huggingface-llm InferenceService ..."
kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: huggingface-llm
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      args:
        - --model_name=llm
        - --model_id=HuggingFaceTB/SmolLM-135M-Instruct
        - --backend=vllm
        - --dtype=float32
      env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
      resources:
        limits:
          cpu: "2"
          memory: "10Gi"
        requests:
          cpu: "1"
          memory: "8Gi"
EOF

echo "Waiting for huggingface-llm InferenceService to be ready (this might take a while)..."
kubectl wait --for=condition=Ready --timeout=600s inferenceservice/huggingface-llm
until [ "$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; do sleep 5; done

if [ $? -ne 0 ]; then
    echo "InferenceService didn't get ready in time."
    exit 1
fi

GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
SERVICE_HOSTNAME=$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.url}' | cut -d "/" -f 3)

echo "Calling SmolLM LLM ..."
curl -v http://$GATEWAY_HOST/openai/v1/completions \
  -H "content-type: application/json" \
  -H "Host: $SERVICE_HOSTNAME" \
  -d '{"model": "llm", "prompt": "Tell me a fact about Ireland", "stream": false, "max_tokens": 50}'
