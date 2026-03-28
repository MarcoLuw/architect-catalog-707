# Lab-1: AgentCore E2E Customer Support — Infrastructure Setup

## Overview

The `prereq.sh` script provisions all AWS infrastructure for a Customer Support agent demo powered by Bedrock AgentCore. It creates an S3 bucket, packages and uploads Lambda code, then deploys two CloudFormation stacks: one for infrastructure and one for Cognito auth.

---

## Prerequisites

Before running `prereq.sh`, ensure you have:

- **AWS CLI** configured with valid credentials
- **Permissions** for: IAM, S3, DynamoDB, Lambda, CloudFormation, Cognito, Bedrock, SSM, S3Vectors, CloudWatch Logs, ECR
- **`zip`** CLI installed (script will attempt to install if missing)
- **`AWS_REGION`** set, or a default region in AWS CLI config (falls back to `us-west-2`)
- **Bedrock model access** enabled for Titan Embed Text v2 (and whichever foundation model the agent uses)
- The file `prerequisite/lambda/python/ddgs-layer.zip` must already exist (not built by the script)

### Script Arguments

| Arg | Default | Purpose |
|-----|---------|---------|
| `$1` | `customersupport112` | S3 bucket name prefix |
| `$2` | `CustomerSupportStackInfra` | Infrastructure stack name |
| `$3` | `CustomerSupportStackCognito` | Cognito stack name |

---

## Script Steps

### Step 1 — Create S3 Bucket

Creates `{prefix}-{ACCOUNT_ID}-{REGION}` and verifies ownership.

### Step 2 — Package Lambda Code

Zips contents of `prerequisite/lambda/python` into `lambda.zip`.

### Step 3 — Upload to S3

Uploads `lambda.zip` and `ddgs-layer.zip` to the bucket.

### Step 4 — Deploy CloudFormation Stacks

Deploys two stacks (details below).

---

## Stack 1: Infrastructure (`infrastructure.yaml`)

### 1.1 — IAM Roles for Bedrock AgentCore

| Resource | What | Why |
|----------|------|-----|
| **RuntimeAgentCoreRole** | Role assumed by `bedrock-agentcore.amazonaws.com` | The AgentCore runtime needs to pull ECR images, invoke Bedrock models, read SSM params, access memory APIs, get OAuth tokens, and write logs/metrics. Scoped to `customersupport*` resources. |
| **GatewayAgentCoreRole** | Role assumed by `bedrock-agentcore.amazonaws.com` | The AgentCore gateway only needs to invoke the CustomerSupport Lambda — it's a thin routing layer. Minimal permissions by design. |

### 1.2 — DynamoDB Tables (Demo Data Store)

| Resource | Key | GSIs | Why |
|----------|-----|------|-----|
| **WarrantyTable** | `serial_number` (HASH) | `customer-index` on `customer_id` | Look up warranties by serial number, or query all warranties for a customer. PAY_PER_REQUEST for unpredictable demo load. PITR enabled for recoverability. |
| **CustomerProfileTable** | `customer_id` (HASH) | `email-index`, `phone-index` | Look up customers by ID, email, or phone. The agent needs multiple lookup paths since support interactions may start with any identifier. |

### 1.3 — Seed Data (Lambda + CustomResource)

| Resource | What | Why |
|----------|------|-----|
| **PopulateDataFunction** | Lambda (Python 3.12) triggered as a CloudFormation CustomResource | Inserts 5 fake customers and 8 fake warranty records into DynamoDB on stack creation. Gives the demo something to work with immediately. |
| **PopulateDataRole** | IAM role for the above Lambda | Scoped to `PutItem`/`BatchWriteItem` on the two tables only. |

### 1.4 — CustomerSupport Lambda (Agent Backend)

| Resource | What | Why |
|----------|------|-----|
| **DDGSLayer** | Lambda Layer from `ddgs-layer.zip` in S3 | Provides the DuckDuckGo Search (`ddgs`) Python package — the agent can search the web. |
| **CustomerSupportLambda** | Lambda (Python 3.12) from `lambda.zip` in S3 | The actual customer support agent logic. Uses the DDGS layer. Invoked by the AgentCore gateway. |
| **CustomerSupportLambdaRole** | IAM role for the Lambda | Can read both DynamoDB tables, read SSM params for table names, query CloudWatch Logs (for AgentCore evaluations), and invoke Bedrock foundation models. |

### 1.5 — Bedrock Knowledge Base (RAG)

| Resource | What | Why |
|----------|------|-----|
| **BedrockKnowledgeBaseDataBucket** | S3 bucket (public access fully blocked) | Stores text docs (troubleshooting guides, warranty info, etc.) as the KB source. |
| **Boto3LayerCreator** + **Boto3Layer** | Lambda that builds a fresh boto3 Lambda Layer at deploy time | The KB setup Lambda needs newer boto3 APIs (`s3vectors`, `bedrock-agent`) not in the Lambda runtime's default version. |
| **BedrockServiceRole** | IAM role for Bedrock service | Bedrock needs to read the S3 data bucket, invoke Titan embedding model, and manage S3 Vectors for the vector store. |
| **KnowledgeBaseSetupFunction** | Lambda triggered as CustomResource | On stack create: uploads 6 support docs to S3, creates an S3 Vectors bucket + index (1024-dim cosine), creates a Bedrock Knowledge Base with Titan Embed v2, creates a data source pointing at the S3 docs, stores KB/DS IDs in SSM Parameter Store. |

### 1.6 — SSM Parameters (Service Discovery)

All resource IDs/ARNs are stored under `/app/customersupport/` so the agent and other components can look them up at runtime without hardcoding:

- DynamoDB table names (`/app/customersupport/dynamodb/warranty_table_name`, `/app/customersupport/dynamodb/customer_profile_table_name`)
- AgentCore IAM role ARNs (`/app/customersupport/agentcore/gateway_iam_role`, `/app/customersupport/agentcore/runtime_iam_role`)
- Lambda ARN (`/app/customersupport/agentcore/lambda_arn`)
- Knowledge Base ID + Data Source ID (under `/{ACCOUNT_ID}-{REGION}/kb/`)

---

## Stack 2: Cognito (`cognito.yaml`)

### 2.1 — User Pool

| Resource | Config | Why |
|----------|--------|-----|
| **UserPool** | Email as username, auto-verified, MFA off, case-insensitive | Demo simplicity — users sign in with email. No MFA for a sample app. |
| **AdminGroup** / **CustomerGroup** | Two groups with precedence 1/2 | Role-based access: admins vs customers can get different agent behavior. |

### 2.2 — App Clients

| Resource | Flow | Why |
|----------|------|-----|
| **WebUserPoolClient** | Authorization Code (`code`) flow, no client secret | For browser/SPA apps (Streamlit on `localhost:8501`). No secret because JavaScript can't keep secrets. 60-min access/ID tokens, 30-day refresh. |
| **MachineUserPoolClient** | Client Credentials flow, with secret | For server-to-server (M2M) calls to the agent API. Has a secret because it's a backend service. |
| **ResourceServer** | Defines a `read` scope | Both clients request this custom scope — it controls what the OAuth token authorizes against the AgentCore API. |

### 2.3 — OAuth Domain

| Resource | Why |
|----------|-----|
| **UserPoolDomain** | Cognito hosted UI domain for OAuth endpoints (token, authorize). Required for OAuth flows to work. |

### 2.4 — Post-Signup Lambda (Defined but NOT Wired)

| Resource | Why |
|----------|-----|
| **PostSignupFunction** | Would auto-add new users to the `customer` group. The `LambdaConfig` trigger on the UserPool is **commented out**, so this currently does nothing. |

### 2.5 — SSM Parameters

Stores all Cognito details under `/app/customersupport/agentcore/`:

- Client IDs — machine (`client_id`) and web (`web_client_id`)
- User Pool ID (`pool_id`)
- OAuth scope (`cognito_auth_scope`)
- Discovery URL (`cognito_discovery_url`)
- Token URL (`cognito_token_url`)
- Authorize URL (`cognito_auth_url`)
- Domain (`cognito_domain`)

---

## Deep Dive: Knowledge Base ↔ S3 Vectors ↔ Data Source Relationship

The notebook's sync job (`start_ingestion_job`) only passes a KB ID and data source ID — yet Bedrock knows exactly where to read documents, how to embed them, and where to store vectors. This is because all the links were established at resource creation time during `prereq.sh`.

### The Relationship Chain

```
S3 Data Bucket ──(bucketArn)──► Data Source ──(knowledgeBaseId)──► Knowledge Base ──(indexArn)──► S3 Vectors Index
     │                               │                                   │                             │
 holds the 6                  "where to get                     "which embedding model        "where to store
 .txt docs                     source docs"                      + which vector store"          the vectors"
```

### How Each Link Was Created (`infrastructure.yaml`)

#### Link 1: S3 Vectors Bucket + Index (empty vector store)

```python
s3vectors.create_vector_bucket(vectorBucketName=vector_bucket_name)
s3vectors.create_index(
    vectorBucketName=vector_bucket_name,
    indexName=index_name,
    dimension=1024,          # must match the embedding model output
    distanceMetric='cosine',
    dataType='float32'
)
```

Creates the storage layer. At this point it's empty — no vectors, no connection to any KB.

#### Link 2: Knowledge Base → Embedding Model + Vector Store

```python
bedrock.create_knowledge_base(
    knowledgeBaseConfiguration={
        'embeddingModelArn': 'amazon.titan-embed-text-v2:0',   # ← which model to embed with
        'dimensions': 1024                                       # ← must match the index
    },
    storageConfiguration={
        's3VectorsConfiguration': {
            'indexArn': index_arn    # ← LINKS KB to the S3 Vectors index
        }
    }
)
```

Now the KB knows: "use Titan Embed v2 to create 1024-dim vectors, store them in this specific S3 Vectors index."

#### Link 3: Data Source → S3 Bucket + Knowledge Base

```python
bedrock.create_data_source(
    knowledgeBaseId=kb_id,                          # ← LINKS data source to the KB
    dataSourceConfiguration={
        's3Configuration': {
            'bucketArn': f"arn:aws:s3:::{data_bucket_name}"  # ← LINKS to the S3 docs bucket
        }
    },
    vectorIngestionConfiguration={
        'chunkingStrategy': 'FIXED_SIZE',
        'maxTokens': 200,
        'overlapPercentage': 10          # ← how to split docs before embedding
    }
)
```

Now the data source knows: "my source documents are in this S3 bucket, I belong to this KB, and chunk docs into 200-token pieces with 10% overlap."

### What Happens When the Notebook Runs `start_ingestion_job`

```python
bedrock.start_ingestion_job(knowledgeBaseId=kb_id, dataSourceId=ds_id)
```

Only two IDs are needed. Bedrock resolves the full chain automatically:

1. **Data Source** → reads all files from S3 bucket `{account}-{region}-kb-data-bucket`
2. **Data Source** → chunks each file (200 tokens, 10% overlap)
3. **Knowledge Base** → embeds each chunk using Titan Embed Text v2 → 1024-dim vector
4. **Storage config** → writes vectors into S3 Vectors index `{account}-{region}-kb-vector-index`

The notebook doesn't define these links because **they were already defined once during CloudFormation deployment**. The sync job simply says "run the pipeline that's already configured."

### Why It's Designed This Way

- **Separation of concerns:** Infrastructure (links/config) is set up once via IaC. Runtime (sync/query) only needs resource IDs.
- **Repeatability:** You can re-run the sync job any time new docs are added to S3 — the pipeline config doesn't change.
- **Auditability:** All resource relationships are traceable in the CloudFormation template, not scattered across notebook cells.
