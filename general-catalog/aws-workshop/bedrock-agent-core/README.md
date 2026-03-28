# Bedrock AgentCore
Reference: [Official Lab](https://catalog.us-east-1.prod.workshops.aws/v2/workshops/bedrock-agent-core/labs/build-strands-agent)

A platform for building and deploying AI agents on AWS Bedrock. It provides a framework for creating intelligent agents that can interact with users, access data, and perform tasks using the capabilities of AWS Bedrock.

People create agents thanks to open source frameworks like Strands Agent, LangChain, LangGraph, CrewAI and can easily deploy them on Bedrock AgentCore which leverages different models from Bedrock and reliable AWS infrastructure to run them at scale.

## Features
- Amazon Bedrock AgentCore Runtime: runtime environment for executing agents built on agent frameworks.
- Amazon Bedrock AgentCore Identity: identity management for agents, e.g users authen/author flows, enabling secure access to AWS resources and services. Service used: Cognito, IAM
- Amazon Bedrock AgentCore Gateway: provides a secure way for agents to discover and use tools along with easy transformation of APIs, Lambda functions, and existing services into agent-compatible tools
- Amazon Bedrock AgentCore Policy: policies are constructed using Cedar, enables developers to define and enforce security controls for AI agent interactions with tools
- Amazon Bedrock AgentCore Code Interpreter: gives agent a **sandboxed environment** where it can write and execute code on the fly during a conversation. The agent decides it needs to run code, writes it, executes it, gets the result, and uses that result to continue. 
    - Example: Transform data: User: "Convert this JSON into a cleaned-up Excel file with only the fields I care about" → Agent: (writes Python to parse, filter, and export to xlsx)
- Amazon Bedrock AgentCore Browser: giving your agent a real browser that it can control — click buttons, fill forms, navigate pages, scroll, interact with web apps — just like a human sitting in front of a screen. Difference between Web Search and Browser:
    - Web Search tool: "Find the cheapest flight to Tokyo" → returns a list of links
    - Browser: Actually goes to a travel site → enters your dates → filters by price → compares options → maybe even completes the booking
- Amazon Bedrock AgentCore Memory: provides industry-leading accuracy along with support for both short-term memory for multi-turn conversations and long-term memory that can be shared across agents and sessions.
- Amazon Bedrock AgentCore Observability: helps developers trace, debug, and monitor agent performance in production through unified operational dashboards.
- Amazon Bedrock AgentCore Evaluations: provides automated assessment tools to measure agent performance, quality.

# Strands Agent
An open-source SDK (a toolkit/library) that you use to build your own agents from scratch.

## Different From Other SDKs Like LangChain:
- Strands takes a "model-driven" approach. Instead of defining complex workflows and step-by-step orchestration logic, you just give the agent three things — a model, a prompt, and a list of tools — and let the LLM figure out the rest.
- LangChain and others are more "orchestration-driven". You have to define the exact sequence of steps, how the agent should use tools, when to call the model, etc. It’s more hands-on and gives you more control, but also requires more work to set up.

## Agent
- In agent, the model doesn't match results by tool name, it matches only by `toolUseId`. Why?
    - The tool name tells the framework which function to call/execute, but the ID (`toolUseId`) tells the model which result is which
    - Thus, even though two tools might have the different (or same) names, if they have the same `toolUseId`, it causes ambuiguity for the model and leads to incorrect requests - results mapping.
    - The model receives results as a flat list of `toolUseId + result` pairs and relies solely on the `toolUseId` to map results back to the correct tool call.

    ```
    # Example:
    Tool Call #1:  toolUseId: "aaa"  - tool: retrieve()
    Tool Call #2:  toolUseId: "bbb"  - tool: calculator()

    Result for "aaa": "30-day refund..."
    Result for "bbb": "42"
    ---
    # If both had the same ID "aaa"
    Result for "aaa": "30-day refund..."
    Result for "aaa": "42"

    Model: "Two results, same ID...
        which one was retrieve?
        which one was calculator?"
    ```

# How Bedrock AgentCore and Strands Agent Work Together
They work as two layers that work together:
- **Strands** = how you build the agent (the code, the logic, the tools)
- **AgentCore** = where you deploy and run the agent (the infrastructure)

# Prerequisites
## Start Jupyter Lab Server
```bash
uv run --active --with jupyter jupyter lab --ip=0.0.0.0 --port=8889
```

# Lab 1: Build a Strands Agent
Build a customer support agent prototype using Strands Agents and Amazon Nova 2 Lite with four core tools:
- Look up return policies for different product categories.
- Search product information and specifications.
- Search the web for troubleshooting help.
- Query a Bedrock Knowledge Base for technical support documentation.

What is missing from this agent?
- Customer-based conversation history and context - Remember every interaction to provide seamless support
- Customer preference learning - Understand individual needs and adapt responses accordingly
- Personalized interactions - Tailor every conversation to each customer's unique situation

## Clean-up:
- Following the instructions in the lab to delete the agent you created.
- IMPORTANT! it turns out that the cleanup section didn't cover deleting the resources that were created by the Lambda scripts embedded in the cloudformation. Thus, you can run the following commands to clean up those resources:

    ```bash
    ./Lab-1/additional_cleanup.sh
    ```

# Lab 2: Enhance the Agent with Memory
## Pain point
Every conversation starts from zero, creating:
- Frustrated customers who must repeat their information repeatedly
- Inefficient support that cannot build on previous interactions
- Lost opportunities to provide personalized, proactive service
- Poor customer satisfaction due to impersonal, generic responses

What need to be achieved?
- AI Agents must have an ability to maintain context over time, remember important facts, and deliver consistent, personalized experiences

## AgentCore Memory
AgentCore Memory operates on two levels:

- **Short-Term Memory**: chat history in current session

    ```
    # Example:
    User: "My name is Minh" → Agent remembers
    User: "What's the weather in Hanoi?" → Agent answers
    User: "Should I bring umbrella?" → Agent still knows "Minh" and "Hanoi" from above

    Session ends → all gone.
    ```
- **Long-Term Memory**: extracted facts that survive across sessions.

    ```
    Session #1: User says "I'm allergic to peanuts" → extracted & saved to persistent store

    Session #2 (weeks later): User says "Suggest me lunch" → Agent retrieves allergy info → avoids peanuts without user mentioning it again
    ```

## Memory Strategies
### What is a Memory Strategy?
A Memory Strategy is a method for determining:
- What information should be stored in an agent's long-term (not short-term or session-based) memory
- How information should be stored, organized, and retrieved from that long-term memory store.

### Why we need different strategies?
Two problems arise if we don't use memory strategies:
- **Accuracy reduction**: store everything into one bucket → when retrieving, get a lot of irrelevant information → confuses the model → worse performance and consume unnecessary tokens
- **Efficiency reduction**: In fact, different data types require different search methods in order to be retrieved effectively. For example:
    - **Preferences:** best retrieved by key lookup (What does this user prefer?)
    - **Facts:** best retrieved by semantic similarity ("Find anything related to damaged orders") → best stored in a vector database
    - **Summaries:** best retrieved by session/actor ID ("What happened last time?")

### Multi-tenant Long-Term Memory
**Namespaces** supports logical grouping of memories by customer and context type.

Example of namespaces:
```
support/customer/{actorId}/preferences/
support/customer/{actorId}/facts/

# Template variables:
support/customer/{actorId}/{strategyId}/

{actorId} = unique identifier for each customer (e.g., user ID, email)
{strategyId} = identifier for the memory strategy (e.g., preferences, facts, summaries)
```

# Lab 3: Scale with Gateway and Identity
## AgentCore Gateway
The Gateway provides a secure way for agents to discover and use tools. It transforms APIs, Lambda functions, and existing services into agent-compatible tools.

### The dual auth model:
```
Agent/App ──► [INBOUND AUTH] ──► AgentCore Gateway ──► [OUTBOUND AUTH] ──► Lambda/API/Service
  (caller)      "who are you?"     (middleman)          "let me in"        (target)
```

**Inbound Auth = Who's calling the Gateway?**
- **Direction**: Caller → Gateway
- **Purpose**: Validates the identity of whoever is trying to use the gateway's tools.
- **Caller**: AI agent, an application, or any MCP client
- **Supported inbound auth methods**: IAM credentials, JWT (OAuth, e.g., from Cognito/Okta), or no auth (not recommended)

**Outbound Auth = How does the Gateway prove itself to the target?**
- **Direction**: Gateway → Target (Lambda, API, 3rd-party Service)
- **Purpose**: The gateway needs its own credentials to call the downstream tool on your behalf.
- **Supported outbound auth methods**: Lambda: (IAM Role), API Gateway: (IAM Role, API Key), REST/OpenAPI: (OAuth 2.0, API Key), MCP Server: (OAuth Client Credentials), 3rd-party Service: (OAuth Authorization Code)

**Example**
```
1. Agent calls Gateway to post a Slack message
2. Inbound auth: Gateway checks "is this agent allowed to use me?" (via IAM or JWT)
3. Outbound auth: Gateway uses OAuth token to authenticate to Slack API on behalf of the agent
4. Slack accepts the request, message posted
```

**The three permission layers**
- Gateway management — who can create/modify/delete Gateways (IAM policies)
- Inbound — who can invoke tools through the Gateway
- Outbound — what credentials Gateway uses to reach each target

## Does AgentCore Gateway actually transform APIs into tools or vice versa?
No, it doesn't magically transform any REST API to MCP or vice versa. The direction is both:

```
Agent sends MCP request → Gateway translates to REST API/Lambda call → Target executes
Target returns REST/Lambda response → Gateway translates back to MCP response → Agent receives
```

### 1. Core mechanism: API Spec, parsing and mapping
Everything is always easier to understand with an example. Let's say you have a REST API endpoint for canceling orders feature:

```
1. You have: POST /api/orders/{id}/cancel  (REST API with OpenAPI spec)

2. You give Gateway the OpenAPI spec

3. Gateway auto-generates MCP tool:
  name: "cancel_order"
  input: { id: string }

4. Agent calls MCP: cancel_order({ id: "12345" })
→ Gateway reads the spec, knows this maps to POST /api/orders/12345/cancel
→ Sends the HTTP request
→ Gets HTTP response
→ Wraps it back as MCP response
→ Returns to agent
```

#### Is this magical? Not really because the Gateway is just doing a heavy lifting of parsing and mapping.

**How it auto-generates MCP tools**
1. An OpenAPI spec is a structured document, contains: `endpoint path`, `HTTP method`, `parameters`, `descriptions`, `request/response schemas`. 
2. Gateway parses this spec and maps each endpoint to an MCP tool definition. 
3. Endpoint name -> tool name, parameters -> input schema, description -> tool description.

**How it knows to map to the correct HTTP call**
1. Agent calls the tool with specific input (e.g., cancel_order({ id: "12345" }))
2. Gateway looks up the tool definition it created from the OpenAPI spec, sees that `cancel_order` maps to `POST /api/orders/{id}/cancel`
3. It takes the input parameters, fills them into the endpoint path (replacing {id} with "12345"),
4. Executes the HTTP request to the correct URL with the correct method and parameters.

**Full flow example**
- **Step 1: Agent connects to Gateway's MCP endpoint**. Your agent code points to the Gateway URL, just like connecting to any MCP server.
- **Step 2: Agent calls `listTools`** (standard MCP operation) -> Gateway responds with all available tools (or a subset). Each tool has a `name, description, and input schema` — all auto-generated from the API specs you registered.
- **Step 3: These tool definitions go into the model's prompt.** The agent framework (Strands, LangGraph, etc.) takes the tool list and injects them into the LLM's context. Now the model knows what tools exist and how to call them.
- **Step 4: Model decides which tool to call**. Based on the user's request ("cancel my order 12345"), the model picks `cancel_order` and generates `{ id: "12345" }` -> This is the model's job — pattern matching between user intent and tool descriptions.
- **Step 5: Agent framework sends MCP call to Gateway**. Gateway translates to REST -> calls the target API -> gets response -> translates back to MCP -> returns to agent.

### 2. Other operational features of the Gateway
Please refer to the official documentation: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-quick-start.html

## Semantic tool selection
AgentCore Gateway supports semantic tool selection, which help to avoids "tool overload" where too many tools confuse the model and cost more tokens.

### How it works
- You have numerous tools registered in the Gateway, sending all of them (via `listTools`) to the model is impractical (token limits, tool overload).
- Instead, agents can call Gateway's built-in search tool `x_amz_bedrock_agentcore_search` + query `"order cancellation"`
- Gateway uses embeddings to find the most relevant tools and return only those to the model context.

### LLM involve?
- No LLM but using embedding model + vector similarity search (with OpenSearch, S3 vector store,...)
- The embedding happens at tool registration time, not query time.
- `Semantic search` feature must be explicitly enabled at gateway creation:

    ```bash
    aws bedrock-agentcore create-gateway \
        --name "my-gateway" \
        --semantic-search-config '{"embeddingModelId": "model-for-embeddings", "vectorStoreConfig": {"type": "opensearch", "endpoint": "https://my-opensearch-endpoint"}}'
    ```
    ```python
    # or
    create_gateway(
        protocolConfiguration={
            "mcp": {
                "searchType": "SEMANTIC"   # ← must be set, or it doesn't exist
            }
        }
    )
    ```