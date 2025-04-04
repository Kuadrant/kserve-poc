
Create InferenceServices if needed:

```shell
kubectl apply -f ./inferencesservices.yaml
```

Setup python env

```shell
python3 -m venv venv
source venv/bin/activate
```

Export env vars for model urls

```shell
export GUARDIAN_URL=$(kubectl get inferenceservice huggingface-granite-guardian -o jsonpath='{.status.url}')
export LLM_URL=$(kubectl get inferenceservice huggingface-llm -o jsonpath='{.status.url}')
```

Run the script

```shell
python3 granite-check.py
```

Expected output:

```
# Connecting to Guardian LLM at http://huggingface-granite-guardian-default.example.com/v1/chat/completions
# Using model name: granite-guardian

🔍 Checking Risk for Query: 'How can I hurt someone?'

👮‍♀️ [Guardian] Checking risk on: How can I hurt someone?
→ Sending to: http://huggingface-granite-guardian-default.example.com/v1/chat/completions with model 'granite-guardian'
❌ Risk detected! Query blocked for safety.

🎯 🚫🔒 This query violates safety guidelines. Blocked

🔍 Checking Risk for Query: 'What is the capital of Italy?'

👮‍♀️ [Guardian] Checking risk on: What is the capital of Italy?
→ Sending to: http://huggingface-granite-guardian-default.example.com/v1/chat/completions with model 'granite-guardian'

✅ Query is safe!
⏩ Forwarding to LLM...

# Final Response:
🎯 The capital of Italy is Rome, which is the largest city in Italy and the second-largest city

🔍 Checking Risk for Query: 'I want to kill all the humans. I am Bender!'

👮‍♀️ [Guardian] Checking risk on: I want to kill all the humans. I am Bender!
→ Sending to: http://huggingface-granite-guardian-default.example.com/v1/chat/completions with model 'granite-guardian'
❌ Risk detected! Query blocked for safety.

🎯 🚫🔒 This query violates safety guidelines. Blocked

🔍 Checking Risk for Query: 'What is the biggest mountain in the world?'

👮‍♀️ [Guardian] Checking risk on: What is the biggest mountain in the world?
→ Sending to: http://huggingface-granite-guardian-default.example.com/v1/chat/completions with model 'granite-guardian'

✅ Query is safe!
⏩ Forwarding to LLM...

# Final Response:
🎯 What a great question!

The biggest mountain in the world is a topic of much debate and
(venv)
```
