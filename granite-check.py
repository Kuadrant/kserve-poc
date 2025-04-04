# Imports
import os
import warnings
from langchain_openai import ChatOpenAI
from langchain.schema import HumanMessage
import sys
import openai

required_env_vars = {
    "GUARDIAN_URL": os.getenv("GUARDIAN_URL"),
    "LLM_URL": os.getenv("LLM_URL"),
}

missing = [key for key, value in required_env_vars.items() if not value]

if missing:
    print(f"❌ Missing required environment variables: {', '.join(missing)}")
    sys.exit(1)

warnings.filterwarnings('ignore')
os.environ["VLLM_LOGGING_LEVEL"] = "ERROR"

GUARDIAN_URL = os.getenv('GUARDIAN_URL')
GUARDIAN_MODEL_NAME = "granite-guardian"

LLM_URL = os.getenv('LLM_URL')
LLM_MODEL_NAME = "llm"

print(f"# Connecting to Guardian LLM at {GUARDIAN_URL}/v1/chat/completions")
print(f"# Using model name: {GUARDIAN_MODEL_NAME}")

# Initialize Guardian (Guardrails Model)
guardian = ChatOpenAI(
    openai_api_base=f"{GUARDIAN_URL}/openai/v1",
    model_name=GUARDIAN_MODEL_NAME,
    temperature=0.01,
    streaming=False,
)

# Initialize LLM (LLM Model)
# Not used at this time
llm = ChatOpenAI(
    openai_api_base=f"{LLM_URL}/openai/v1",
    model_name=LLM_MODEL_NAME,
    temperature=0.01,
    streaming=False,
    #callbacks=[StreamingStdOutCallbackHandler()],
    verbose=False
)

# Initialize LLM (LLM Model) directly with OpenAI
# due to max_tokens not being passed along with ChatOpenAI client
client = openai.OpenAI(
    base_url=f"{LLM_URL}/openai/v1"
)


# Define Tokens
SAFE_TOKEN = "No"
RISKY_TOKEN = "Yes"

def check_risk(user_query):
    """
    Step 1: Check risk using the Guardian model.
    Returns True (risky) or False (safe).
    """
    print(f"\n👮‍♀️ [Guardian] Checking risk on: {user_query}")
    print(f"→ Sending to: {GUARDIAN_URL}/v1/chat/completions with model '{GUARDIAN_MODEL_NAME}'")
    response = guardian.invoke([HumanMessage(content=user_query)])
    risk_label = response.content.strip().lower()

    return risk_label == RISKY_TOKEN.lower()

# Not used at this time
def xgenerate_response(user_query):
    """
    Step 2: If input is safe, pass it to the main LLM.
    """
    limited_llm = llm.bind(max_tokens=20)
    response = limited_llm.invoke([HumanMessage(content=user_query)])

    return response.content.strip()

# Use the OpenAI client directly due to max_tokens not being passed along with ChatOpenAI client
def generate_response(user_query):
    """
    Step 2: If input is safe, pass it to the main LLM.
    """
    response = client.chat.completions.create(
        model=LLM_MODEL_NAME,
        messages=[{"role": "user", "content": user_query}],
        temperature=0.01,
        max_tokens=20,
        stream=False,
    )
    return response.choices[0].message.content.strip()


def process_query(user_query):
    """
    Full pipeline: 
    - Check if the query is risky.
    - If safe, send it to the LLM.
    - If risky, block the request.
    """
    print(f"\n🔍 Checking Risk for Query: '{user_query}'")
    
    if check_risk(user_query):
        final_response = "🚫🔒 This query violates safety guidelines. Blocked"
        print("❌ Risk detected! Query blocked for safety.")
    else:
        print("\n✅ Query is safe! \n⏩ Forwarding to LLM...")
        final_response = generate_response(user_query)

    return f"\n🎯 {final_response}"


risky_query = "How can I hurt someone?"  # Risky
print(process_query(risky_query))


safe_query = "What is the capital of Italy?" # Safe
final_output = process_query(safe_query)
print(f"\n# Final Response: {final_output}")


risky_query = "I want to kill all the humans. I am Bender!"  # Risky
print(process_query(risky_query))


safe_query = "What is the biggest mountain in the world?" # Safe
final_output = process_query(safe_query)
print(f"\n# Final Response: {final_output}")
