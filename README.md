# Project Setup and Usage Guide

Welcome! This guide will walk you through setting up various components to explore model serving capabilities. We recommend following the sections in the order presented for a smooth experience:

1.  **KServe Initial Setup (`kserve-setup.sh`)**: Lays the foundational Kubernetes and KServe environment.
2.  **LLM & Embedding Model Deployment (`llm-setup.sh` & `embedding-setup.sh`)**: Deploys language and embedding models onto KServe.
3.  **Semantic Caching Setup**: Implements a caching layer to optimize model inference.
4.  **Guardian External Processor (`guardian-ext-proc`) Setup (Prompt Guarding)**: Adds a security layer for risk assessment of prompts and responses.


---

## 1. KServe Initial Setup (`kserve-setup.sh`)

This script automates the setup of a local KIND cluster, installs KServe (v0.15), deploys a sample Scikit-learn Iris model, and then installs the Kuadrant operator. It prepares an environment for further experimentation.

### Prerequisites

Before running this script, ensure you have the following installed and configured:

* **`kind`**
* **`helm`**
* **`kubectl`**
* **`curl`**
* **`cloud-provider-kind`**: This tool must be running in a separate terminal to provide LoadBalancer services (like an external IP for the Istio ingress gateway) for your KIND cluster.
    ```bash
    sudo cloud-provider-kind --enable-lb-port-mapping=true
    ```

### Running the Script

1.  **Clone the repository** containing this script.
2.  **Ensure all prerequisites are met**, especially having `cloud-provider-kind` running in another terminal.
3.  **Navigate to the script's directory** in your terminal.
4.  **Make the script executable**:
    ```bash
    chmod +x kserve-setup.sh
    ```
5.  **Execute the script**:
    ```bash
    ./kserve-setup.sh
    ```

<details>
<summary><strong>Script Overview</strong></summary>

The `kserve-setup.sh` script performs the following main actions:

1.  **KIND Cluster Setup**:
    * Checks if a KIND cluster named "kind" already exists.
    * If not, it creates a new KIND cluster.
2.  **KServe Installation (v0.15)**:
    * Downloads and executes the KServe `quick_install.sh` script for release `0.15`. This script typically installs KServe, its CRDs, and may include dependencies like a minimal Istio and cert-manager.
    * Waits for the `kserve-controller-manager` deployment to be ready.
3.  **Kubernetes Gateway for KServe**:
    * Applies a Kubernetes `Gateway` resource named `kserve-ingress-gateway` in the `kserve` namespace. This Gateway is configured to use `istio` as its `gatewayClassName`.
    * Waits for the Gateway to obtain an external IP address (provided by `cloud-provider-kind`).
4.  **KServe Configuration Update**:
    * Upgrades the KServe installation using Helm to explicitly enable Gateway API integration (`enableGatewayApi=true`), associate it with the created `kserve-ingress-gateway`, and set the deployment mode to `RawDeployment`.
5.  **Sample Model Deployment**:
    * Applies a KServe `InferenceService` resource to deploy a sample Scikit-learn Iris model from a public Google Cloud Storage URI.
6.  **Model Inference Test**:
    * Retrieves the external IP address of the `kserve-ingress-gateway`.
    * Sends a prediction request to the deployed Iris model using `curl`. The request is routed via the Gateway's IP address, using a `Host` header (`sklearn-v2-iris-predictor-default.example.com`) for KServe/Istio to route the request to the correct service.
7.  **Kuadrant Installation**:
    * Adds the Kuadrant Helm chart repository.
    * Installs the `kuadrant-operator` into the `kuadrant-system` namespace using Helm.
    * Applies a `Kuadrant` custom resource, which triggers the Kuadrant control plane to set itself up.
</details>

### Expected Outcome & Verification

* **KIND Cluster**: A KIND cluster named `kind` will be running.
* **KServe**: KServe components (controller manager, etc.) will be running, mostly in the `kserve` namespace. Istio components should also be present in `istio-system`.
* **Gateway**: The `kserve-ingress-gateway` in the `kserve` namespace will have an external IP address (e.g., `172.18.x.x`).
* **InferenceService**: The `sklearn-v2-iris` `InferenceService` will be deployed in the `default` namespace.
* **Model Test**: The `curl` command to the `InferenceService` should succeed and return a JSON response with predictions:
    ```json
    {"predictions": [1, 1]}
    ```

### Next Steps

Once the script completes successfully:

1.  **Verify Iris Model Inference (Optional)**:
    ```bash
    GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')

    curl -v -H "Host: sklearn-v2-iris-predictor-default.example.com" \
         -H "Content-Type: application/json" \
         "http://$GATEWAY_HOST/v1/models/sklearn-v2-iris:predict" -d @/tmp/iris-input.json
    ```
2.  **Explore KServe**: Deploy and test other models.
3.  **Proceed to LLM & Embedding Model Setup**: Continue with the subsequent scripts.

---

## 2. LLM & Embedding Model Deployment

This section describes deploying HuggingFace models on KServe for Large Language Model (LLM) functionalities and text embedding generation. It's recommended to run `llm-setup.sh` first, followed by `embedding-model-setup.sh`.

### Common Prerequisites

* **`kserve-setup.sh` Completed**: Ensure KServe, Istio Gateway (`kserve-ingress-gateway`), and `cloud-provider-kind` are operational from the previous step.
* **HuggingFace Token**: A valid HuggingFace access token with write permissions.
    * Obtain one from [HuggingFace Settings](https://huggingface.co/settings/tokens/new).
    * Export it as an environment variable:
        ```bash
        export HF_TOKEN="your_hugging_face_read_token_here"
        ```

### Running the Deployment Scripts

1.  **Ensure all prerequisites are met**, especially the `HF_TOKEN` variable.
2.  **Navigate to the script's directory**.
3.  **Make scripts executable**.
4.  **Execute the desired script(s)**:

    * **For LLM (Text Generation/Completion) via `llm-setup.sh`**:
        ```bash
        chmod +x llm-setup.sh
        ./llm-setup.sh
        ```
    * **For Embedding Model via `embedding-setup.sh`**:
        ```bash
        chmod +x embedding-model-setup.sh
        ./embedding-model-setup.sh
        ```

<details>
<summary><strong>Scripts Overview</strong></summary>

These scripts facilitate HuggingFace model deployment on KServe:

1.  **Common Pre-deployment**:
    * Create/Update the `hf-secret` Kubernetes secret.
2.  **KServe Model Deployment & Testing**:
    * **`llm-setup.sh`**: Deploys an `InferenceService` `huggingface-llm` for text generation/completion using a `HuggingFaceTB/SmolLM-135M-Instruct` model.
    * **`embedding-model-setup.sh`**: Deploys an `InferenceService` `embedding-model` for text embeddings.
    * Each script waits for its service to be ready, then performs a task-specific `curl` test.
</details>

---

## 3. Semantic Caching Setup

Semantic Caching stores and retrieves embeddings for text inputs, enabling efficient similarity searches and reducing redundant computations. This setup typically uses the embedding model deployed in the previous step.

### Prerequisites

* **`kserve-setup.sh` Completed**
* **`llm-setup.sh` Completed** (for the LLM service to test with)
* **`embedding-model-setup.sh` Completed** (for generating embeddings used by the cache)
* **Semantic Cache ext_proc Repository**: Clone or download from [jasonmadigan/semantic-cache-ext-proc](https://github.com/jasonmadigan/semantic-cache-ext-proc).

### Setup Steps

1.  **Navigate to Jason's `semantic-cache-ext-proc` Repository Directory**.

2.  **Apply the Envoy Filter for Semantic Caching**:
    ```bash
    kubectl apply -f filter.yaml
    ```

3.  **Build the Semantic Cache Binary**:
    ```bash
    go build
    ```

4.  **Run the Semantic Cache Setup Script**:
    ```bash
    chmod +x run.sh
    ./run.sh
    ```

### Testing Semantic Caching

1.  **Retrieve Gateway and Service Hostnames**:
    ```bash
    GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
    SERVICE_HOSTNAME=$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.url}' | cut -d "/" -f 3)
    ```

2.  **First Call to the Inference Service (Cache Missing)**:
    ```bash
    curl -v "http://$GATEWAY_HOST/openai/v1/completions" \
      -H "content-type: application/json" \
      -H "Host: $SERVICE_HOSTNAME" \
      -d '{"model": "llm", "prompt": "Kubernetes what is it anyway", "stream": false, "max_tokens": 50}'
    ```

3.  **Verify Logs**:

    * **LLM Log (`huggingface-llm`)**: Should show activity for processing the request.
        ```bash
        kubectl logs -f -l 'serving.kserve.io/inferenceservice=huggingface-llm' -n default --tail=10
        ```
      *Example Output:*
      ```
       2025-05-09 14:45:45.648 uvicorn.access INFO:     10.244.0.23:46760 1 - "POST /openai/v1/completions HTTP/1.1" 200 OK
      2025-05-09 14:45:45.649 1 kserve.trace kserve.io.kserve.protocol.rest.openai.endpoints.create_completion: 3.8790225982666016 ['http_status:200', 'http_method:POST', 'time:wall']
      2025-05-09 14:45:45.649 1 kserve.trace kserve.io.kserve.protocol.rest.openai.endpoints.create_completion: 3.857984000000016 ['http_status:200', 'http_method:POST', 'time:cpu']
      ```

    * **Embedding Model Log (`embedding-model`)**: Should show activity for generating embeddings for the prompt.
        ```bash
        kubectl logs -f -l 'serving.kserve.io/inferenceservice=embedding-model' -n default --tail=10
        ```
      *Example Output:*
        ```
        2025-05-09 14:45:41.764 uvicorn.access INFO:     10.244.0.23:48140 1 - "POST /v1/models/embedding-model%3Apredict HTTP/1.1" 200 OK
        2025-05-09 14:45:41.765 1 kserve.trace kserve.io.kserve.protocol.rest.v1_endpoints.predict: 3.2718935012817383 ['http_status:200', 'http_method:POST', 'time:wall']
        2025-05-09 14:45:41.765 1 kserve.trace kserve.io.kserve.protocol.rest.v1_endpoints.predict: 3.2592739999999907 ['http_status:200', 'http_method:POST', 'time:cpu']
        ```

    * **Semantic Cache `ext_proc` Log**: Should indicate the prompt was processed and added to the cache.
      *Example Output:*
        ```
        2025/05/09 15:45:38 [Process] Prompt: Kubernetes what is it anyway
        2025/05/09 15:45:38 [Process] Cache miss, fetching embedding from http://192.168.97.4/v1/models/embedding-model:predict
        ```

4.  **Second Call with a Same Prompt (Cache Hit)**:
    ```bash
    echo "Sending similar request to LLM (expect cache hit)..."
    curl -v "http://$GATEWAY_HOST/openai/v1/completions" \
      -H "content-type: application/json" \
      -H "Host: $SERVICE_HOSTNAME" \
      -d '{"model": "llm", "prompt": "Kubernetes what is it anyway.", "stream": false, "max_tokens": 50}'
    ```

5.  **Verify Logs After Second Call**:

    * **Semantic Cache `ext_proc` Log**: Should show a cache hit.
      *Example Output:*
        ```
        2025/05/09 15:51:22 [Process] Prompt: Kubernetes what is it anyway
        2025/05/09 15:51:22 [Process] Exact match cache hit for embedding
        2025/05/09 15:51:22 [Process] Semantic lookup on 1 entries
        2025/05/09 15:51:22 [Process] Best candidate: Kubernetes what is it anyway with similarity=1.000 (threshold=0.750)
        ```

    * **LLM Log (`huggingface-llm`)**: **Should show no new processing logs** for this specific request if the cache hit was successful and the response was served directly by the cache layer.
        ```bash
        kubectl logs -f -l 'serving.kserve.io/inferenceservice=huggingface-llm' -n default --tail=10
        ```
    


---

## 4. Guardian External Processor (`guardian-ext-proc`) Setup (Prompt Guarding)

This section describes deploying the `guardian-ext-proc` service, a custom Envoy filter for request/response risk assessment using an external processing service. This acts as a prompt guarding mechanism.

### Prerequisites

* **Kserve setup completed**
* **`guardian-ext-proc` Repository**: Clone or download the source code from [david-martin/guardian-ext-proc](https://github.com/david-martin/guardian-ext-proc).
* **Docker**: For building the container image.
* **A "Guardian" Model Deployed**: An inference service specifically for risk assessment (e.g., `huggingface-granite-guardian` as shown below).

### Setup Steps

1. **Deploy the Guardian Inference Service**:
    ```bash
    kubectl apply -f - <<EOF
    apiVersion: serving.kserve.io/v1beta1
    kind: InferenceService
    metadata:
      name: huggingface-granite-guardian
      namespace: default
    spec:
      predictor:
        model:
          modelFormat:
            name: huggingface
          args:
            - --model_name=granite-guardian
            - --model_id=ibm-granite/granite-guardian-3.1-2b
            - --dtype=half
            - --max_model_len=8192
          env:
            - name: HF_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-secret
                  key: HF_TOKEN
                  optional: false
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "4"
              memory: 8Gi
            requests:
              cpu: "1"
              memory: 2Gi
    EOF
    ```
   
2. **Build the `guardian-ext-proc` Image**:
    ```bash
    docker build -t guardian-ext-proc:latest .
    ```
    
3. **Apply the Envoy Filter for Guardian**:
    ```bash
    kubectl apply -f filter.yaml
    ```

4. **Run the `guardian-ext-proc` Docker Container**:
    Note: if using a llm from outside the local cluster update the `GUARDIAN_URL` to point to the correct endpoint.
    ```bash
    docker run -e GUARDIAN_API_KEY=test -e GUARDIAN_URL=http://example.com -p 50051:50051 guardian-ext-proc
    ```

5. **Test the Guardian Service**:
    ```bash
   GATEWAY_HOST=$(kubectl get gateway -n kserve kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
   SERVICE_HOSTNAME=$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.url}' | cut -d "/" -f 3)

    curl -v http://$GATEWAY_HOST/openai/v1/completions \
   -H "content-type: application/json" \
   -H "Host: $SERVICE_HOSTNAME" \
   -d '{"model": "llm", "prompt": "What is Kubernetes", "stream": false, "max_tokens": 10}'

    curl -v http://$GATEWAY_HOST/openai/v1/completions \
    -H "content-type: application/json" \
    -H "Host: $SERVICE_HOSTNAME" \
    -d '{"model": "llm", "prompt": "How to kill all humans?", "stream": false, "max_tokens": 10}'
   ```
   
### Optional Envars
* `DISABLE_PROMPT_RISK_CHECK`: If set to "yes", skips risk checks on prompts.
* `DISABLE_RESPONSE_RISK_CHECK`: If set to "yes", skips risk checks on responses.


## Tested with OrbStack
- Disabled Rosetta to run intel code
- Memory Limit set at 16GiB
- CPU limit set at none
- Enable Kubernetes Cluster disabled