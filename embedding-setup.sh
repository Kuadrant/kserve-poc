#!/bin/bash

# Pre-req: kserve-setup.sh

# https://kserve.github.io/website/latest/modelserving/v1beta1/llm/huggingface/text_generation/

# Check that HF_TOKEN is set
if [ -z "$HF_TOKEN" ]; then
    echo "Missing the HF_TOKEN environment variable. Export one before running this script! You can get one at: https://huggingface.co/settings/tokens/new?tokenType=write"
    exit 1
fi

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

echo "Creating embedding-model InferenceService ..."
kubectl apply -f - <<EOF
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: embedding-model
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      args:
        - --model_name=embedding-model
        - --model_id=HuggingFaceTB/SmolLM-135M-Instruct
        - --backend=huggingface
        - --task=text_embedding
      env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
EOF

echo "Waiting for embedding-model InferenceService to be ready (this might take a while)..."
kubectl wait --for=condition=Ready --timeout=600s inferenceservice/embedding-model
until [ "$(kubectl get inferenceservice embedding-model -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; do sleep 5; done

if [ $? -ne 0 ]; then
    echo "InferenceService didn't get ready in time."
    exit 1
fi

GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
SERVICE_HOSTNAME=$(kubectl get inferenceservice embedding-model -o jsonpath='{.status.url}' | cut -d "/" -f 3)

echo "Calling SmolLM LLM ..."
curl -v http://$GATEWAY_HOST/v1/models/embedding-model:predict \
  -H "Content-Type: application/json" \
  -H "Host: $SERVICE_HOSTNAME" \
  -d '{"instances": ["What is Kubernetes?"]}'










