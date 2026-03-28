#!/bin/bash
#
# additional_cleanup.sh
#
# Cleans up resources created by the KnowledgeBaseSetupFunction Lambda
# (CustomResource) that are NOT managed by CloudFormation and therefore
# NOT deleted when the infra stack is removed.
#
# Orphaned resources:
#   - Bedrock Knowledge Base + Data Source
#   - S3 Vectors bucket + index
#   - SSM parameters for KB/DS IDs
#
# After cleanup, runs a full verification against ALL resources from both
# CloudFormation stacks (infrastructure.yaml + cognito.yaml) plus the
# Lambda-created resources above.
#
# Usage:
#   bash additional_cleanup.sh              # uses AWS_REGION or CLI default
#   AWS_REGION=us-west-2 bash additional_cleanup.sh

set -euo pipefail

# ----- Config -----
echo "Resolving account and region..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "${AWS_REGION:-}" ]; then
  REGION=$(aws configure get region 2>/dev/null || echo "us-west-2")
else
  REGION="$AWS_REGION"
fi

BUCKET_PREFIX="customersupport112"
DEPLOY_BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}-${REGION}"

echo "Account: $ACCOUNT_ID"
echo "Region:  $REGION"
echo ""

# =============================================================================
# CLEANUP — Lambda-created resources not managed by CloudFormation
# =============================================================================

# ----- 1. Delete Bedrock Knowledge Base and Data Source -----
echo "--- Step 1: Bedrock Knowledge Base ---"

KB_ID=$(aws ssm get-parameter \
  --name "/${ACCOUNT_ID}-${REGION}/kb/knowledge-base-id" \
  --region "$REGION" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")

if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
  DS_ID=$(aws ssm get-parameter \
    --name "/${ACCOUNT_ID}-${REGION}/kb/data-source-id" \
    --region "$REGION" \
    --query "Parameter.Value" --output text 2>/dev/null || echo "")

  if [ -n "$DS_ID" ] && [ "$DS_ID" != "None" ]; then
    echo "Deleting data source: $DS_ID"
    aws bedrock-agent delete-data-source \
      --knowledge-base-id "$KB_ID" \
      --data-source-id "$DS_ID" \
      --region "$REGION" 2>/dev/null || echo "  Warning: data source deletion failed (may already be gone)"
  else
    echo "No data source ID found in SSM, skipping"
  fi

  echo "Deleting knowledge base: $KB_ID"
  aws bedrock-agent delete-knowledge-base \
    --knowledge-base-id "$KB_ID" \
    --region "$REGION" 2>/dev/null || echo "  Warning: knowledge base deletion failed (may already be gone)"
else
  echo "No knowledge base ID found in SSM, skipping"

  # KB may exist but SSM param already gone — trigger delete if still ACTIVE
  KB_ID=$(aws bedrock-agent list-knowledge-bases \
    --region "$REGION" \
    --query "knowledgeBaseSummaries[?name=='${ACCOUNT_ID}-${REGION}-kb'].knowledgeBaseId" \
    --output text 2>/dev/null || echo "")

  if [ -n "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
    KB_STATUS=$(aws bedrock-agent get-knowledge-base \
      --knowledge-base-id "$KB_ID" \
      --region "$REGION" \
      --query "knowledgeBase.status" --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$KB_STATUS" = "ACTIVE" ]; then
      echo "Found orphaned KB $KB_ID in ACTIVE state — triggering delete..."
      aws bedrock-agent delete-knowledge-base \
        --knowledge-base-id "$KB_ID" \
        --region "$REGION" 2>/dev/null || echo "  Warning: delete failed"
    else
      echo "Found orphaned KB $KB_ID with status: $KB_STATUS — deletion already in progress"
    fi
  fi
fi

# ----- 2. Delete S3 Vectors index and bucket -----
echo ""
echo "--- Step 2: S3 Vectors ---"

VECTOR_BUCKET="${ACCOUNT_ID}-${REGION}-kb-vector-bucket"
INDEX_NAME="${ACCOUNT_ID}-${REGION}-kb-vector-index"

echo "Deleting S3 Vectors index: $INDEX_NAME"
aws s3vectors delete-index \
  --vector-bucket-name "$VECTOR_BUCKET" \
  --index-name "$INDEX_NAME" \
  --region "$REGION" 2>/dev/null || echo "  Warning: index deletion failed (may already be gone)"

echo "Deleting S3 Vectors bucket: $VECTOR_BUCKET"
aws s3vectors delete-vector-bucket \
  --vector-bucket-name "$VECTOR_BUCKET" \
  --region "$REGION" 2>/dev/null || echo "  Warning: vector bucket deletion failed (may already be gone)"

# ----- 3. Delete orphaned SSM parameters -----
echo ""
echo "--- Step 3: Orphaned SSM Parameters ---"

for param in \
  "/${ACCOUNT_ID}-${REGION}/kb/knowledge-base-id" \
  "/${ACCOUNT_ID}-${REGION}/kb/data-source-id"; do
  echo "Deleting SSM parameter: $param"
  aws ssm delete-parameter \
    --name "$param" \
    --region "$REGION" 2>/dev/null || echo "  Warning: parameter not found (may already be gone)"
done

echo ""
echo "Cleanup complete."

# =============================================================================
# VERIFICATION — Check ALL resources from both stacks + Lambda-created
# =============================================================================

echo ""
echo "============================================================"
echo " VERIFICATION: Checking all resources are gone (timeout: 3min)"
echo "============================================================"

VERIFY_TIMEOUT=180
VERIFY_INTERVAL=10

check() {
  local label="$1"
  local cmd="$2"

  result=$(eval "$cmd" 2>&1) || true

  # Trim leading/trailing whitespace (--output text can return blank lines)
  result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n')

  # Determine if resource still exists
  # - Empty, "None", or error messages = CLEAN
  # - Actual data = STILL EXISTS
  if echo "$result" | grep -qiE "does not exist|not found|ResourceNotFoundException|ParameterNotFound|NoSuchBucket|NoSuchEntity|404|not be found|An error occurred|UnknownServiceError|Invalid choice|invalid choice|Unknown service"; then
    return 0  # CLEAN
  elif [ -z "$result" ] || [ "$result" = "[]" ] || [ "$result" = "None" ]; then
    return 0  # CLEAN
  else
    LAST_RESULT="$result"
    return 1  # EXISTS
  fi
}

run_all_checks() {
  PASS=0
  FAIL=0
  LAST_RESULT=""

  # -------------------------------------------------------
  # infrastructure.yaml — CloudFormation-managed resources
  # -------------------------------------------------------
  echo ""
  echo "--- CloudFormation Stacks ---"
  if check "Infra stack (CustomerSupportStackInfra)" \
    "aws cloudformation describe-stacks --stack-name CustomerSupportStackInfra --region $REGION --query 'Stacks[0].StackStatus' --output text"; then
    echo "  CLEAN  Infra stack (CustomerSupportStackInfra)"; PASS=$((PASS+1))
  else
    echo "  EXISTS Infra stack (CustomerSupportStackInfra)"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
  fi
  if check "Cognito stack (CustomerSupportStackCognito)" \
    "aws cloudformation describe-stacks --stack-name CustomerSupportStackCognito --region $REGION --query 'Stacks[0].StackStatus' --output text"; then
    echo "  CLEAN  Cognito stack (CustomerSupportStackCognito)"; PASS=$((PASS+1))
  else
    echo "  EXISTS Cognito stack (CustomerSupportStackCognito)"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
  fi

  echo ""
  echo "--- IAM Roles (infrastructure.yaml) ---"
  for role in \
    "${ACCOUNT_ID}-${REGION}-RuntimeAgentCoreRole" \
    "${ACCOUNT_ID}-${REGION}-GatewayAgentCoreRole" \
    "${ACCOUNT_ID}-${REGION}-kb-bedrock-service-role" \
    "${ACCOUNT_ID}-${REGION}-kb-setup-function-role" \
    "${ACCOUNT_ID}-${REGION}-kb-boto3-layer-creator-role"; do
    if check "$role" "aws iam get-role --role-name $role --query 'Role.RoleName' --output text"; then
      echo "  CLEAN  $role"; PASS=$((PASS+1))
    else
      echo "  EXISTS $role"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  echo ""
  echo "--- DynamoDB Tables ---"
  for table in CustomerWarranties CustomerProfiles; do
    if check "$table table" "aws dynamodb describe-table --table-name $table --region $REGION --query 'Table.TableName' --output text"; then
      echo "  CLEAN  $table table"; PASS=$((PASS+1))
    else
      echo "  EXISTS $table table"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  echo ""
  echo "--- Lambda Functions ---"
  for fn in \
    "CustomerSupportLambda" \
    "${ACCOUNT_ID}-${REGION}-kb-setup-function" \
    "${ACCOUNT_ID}-${REGION}-kb-boto3-layer-creator"; do
    if check "$fn" "aws lambda get-function --function-name $fn --region $REGION --query 'Configuration.FunctionName' --output text"; then
      echo "  CLEAN  $fn"; PASS=$((PASS+1))
    else
      echo "  EXISTS $fn"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done
  for prefix in "CustomerSupportStackInfra-PopulateDataFunction" "CustomerSupportStackCognito-PostSignupFunction"; do
    if check "$prefix-*" "aws lambda list-functions --region $REGION --query \"Functions[?starts_with(FunctionName,'$prefix')].FunctionName\" --output text"; then
      echo "  CLEAN  $prefix-*"; PASS=$((PASS+1))
    else
      echo "  EXISTS $prefix-*"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  echo ""
  echo "--- S3 Buckets ---"
  for bucket in "$DEPLOY_BUCKET" "${ACCOUNT_ID}-${REGION}-kb-data-bucket"; do
    if check "$bucket" "aws s3api head-bucket --bucket $bucket --expected-bucket-owner $ACCOUNT_ID"; then
      echo "  CLEAN  $bucket"; PASS=$((PASS+1))
    else
      echo "  EXISTS $bucket"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  echo ""
  echo "--- SSM Parameters (infrastructure.yaml) ---"
  for param in \
    "/app/customersupport/dynamodb/warranty_table_name" \
    "/app/customersupport/dynamodb/customer_profile_table_name" \
    "/app/customersupport/agentcore/gateway_iam_role" \
    "/app/customersupport/agentcore/runtime_iam_role" \
    "/app/customersupport/agentcore/lambda_arn"; do
    if check "SSM $param" "aws ssm get-parameter --name '$param' --region $REGION --query 'Parameter.Value' --output text"; then
      echo "  CLEAN  SSM $param"; PASS=$((PASS+1))
    else
      echo "  EXISTS SSM $param"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  # -------------------------------------------------------
  # cognito.yaml — CloudFormation-managed resources
  # -------------------------------------------------------
  echo ""
  echo "--- Cognito User Pool ---"
  if check "UserPool (CustomerSupportGatewayPool)" \
    "aws cognito-idp list-user-pools --max-results 20 --region $REGION --query \"UserPools[?Name=='CustomerSupportGatewayPool'].Id\" --output text"; then
    echo "  CLEAN  UserPool (CustomerSupportGatewayPool)"; PASS=$((PASS+1))
  else
    echo "  EXISTS UserPool (CustomerSupportGatewayPool)"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
  fi

  echo ""
  echo "--- SSM Parameters (cognito.yaml) ---"
  for param in \
    "/app/customersupport/agentcore/client_id" \
    "/app/customersupport/agentcore/web_client_id" \
    "/app/customersupport/agentcore/pool_id" \
    "/app/customersupport/agentcore/cognito_auth_scope" \
    "/app/customersupport/agentcore/cognito_discovery_url" \
    "/app/customersupport/agentcore/cognito_token_url" \
    "/app/customersupport/agentcore/cognito_auth_url" \
    "/app/customersupport/agentcore/cognito_domain"; do
    if check "SSM $param" "aws ssm get-parameter --name '$param' --region $REGION --query 'Parameter.Value' --output text"; then
      echo "  CLEAN  SSM $param"; PASS=$((PASS+1))
    else
      echo "  EXISTS SSM $param"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done

  # -------------------------------------------------------
  # Lambda-created resources (NOT in CloudFormation)
  # -------------------------------------------------------
  echo ""
  echo "--- Lambda-Created Resources (orphans) ---"
  if check "Bedrock Knowledge Base (${ACCOUNT_ID}-${REGION}-kb)" \
    "aws bedrock-agent list-knowledge-bases --region $REGION --query \"knowledgeBaseSummaries[?name=='${ACCOUNT_ID}-${REGION}-kb'].knowledgeBaseId\" --output text"; then
    echo "  CLEAN  Bedrock Knowledge Base (${ACCOUNT_ID}-${REGION}-kb)"; PASS=$((PASS+1))
  else
    echo "  EXISTS Bedrock Knowledge Base (${ACCOUNT_ID}-${REGION}-kb)"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
  fi
  if check "S3 Vectors bucket (${ACCOUNT_ID}-${REGION}-kb-vector-bucket)" \
    "aws s3vectors list-vector-buckets --region $REGION --query \"vectorBuckets[?vectorBucketName=='${ACCOUNT_ID}-${REGION}-kb-vector-bucket'].vectorBucketName\" --output text"; then
    echo "  CLEAN  S3 Vectors bucket (${ACCOUNT_ID}-${REGION}-kb-vector-bucket)"; PASS=$((PASS+1))
  else
    echo "  EXISTS S3 Vectors bucket (${ACCOUNT_ID}-${REGION}-kb-vector-bucket)"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
  fi
  for param in \
    "/${ACCOUNT_ID}-${REGION}/kb/knowledge-base-id" \
    "/${ACCOUNT_ID}-${REGION}/kb/data-source-id"; do
    if check "SSM $param" "aws ssm get-parameter --name '$param' --region $REGION --query 'Parameter.Value' --output text"; then
      echo "  CLEAN  SSM $param"; PASS=$((PASS+1))
    else
      echo "  EXISTS SSM $param"; echo "         $LAST_RESULT" | head -3; FAIL=$((FAIL+1))
    fi
  done
}

# -------------------------------------------------------
# Poll until all clean or timeout
# -------------------------------------------------------
VERIFY_START=$(date +%s)
ATTEMPT=0

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  PASS=0
  FAIL=0

  echo ""
  echo "--- Attempt $ATTEMPT ---"
  run_all_checks

  if [ "$FAIL" -eq 0 ]; then
    break
  fi

  ELAPSED=$(( $(date +%s) - VERIFY_START ))
  if [ "$ELAPSED" -ge "$VERIFY_TIMEOUT" ]; then
    echo ""
    echo "  Timed out after ${VERIFY_TIMEOUT}s — $FAIL resource(s) still not clean."
    break
  fi

  echo ""
  echo "  $FAIL resource(s) still exist — retrying in ${VERIFY_INTERVAL}s..."
  sleep "$VERIFY_INTERVAL"
done

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "============================================================"
TOTAL=$((PASS + FAIL))
echo " Result: $PASS/$TOTAL CLEAN"
if [ "$FAIL" -gt 0 ]; then
  echo " $FAIL resource(s) still exist — manual cleanup needed"
  echo "============================================================"
  exit 1
else
  echo " All resources verified clean"
  echo "============================================================"
  exit 0
fi
