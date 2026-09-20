#!/usr/bin/env bash
# preflight.sh - find out which AWS services this account lets you use BEFORE designing around them.
#
# For each service below it deploys a tiny one-resource CloudFormation stack, records whether the
# creation worked or was denied (typically by an Organizations SCP or a missing IAM permission),
# and deletes the stack right away (create -> verify -> destroy). Cost: effectively zero.
#
# Usage:
#   ./scripts/preflight.sh                 # probe every service
#   ./scripts/preflight.sh s3 lambda       # probe only some of them
#
# Output: a table on screen and docs/PREFLIGHT.md (account IDs and ARNs are masked, but review the
# file before committing it).
#
# If the script is interrupted, run ./scripts/teardown.sh destroy: probe stacks are named
# "<STACK_PREFIX>-preflight-<service>", so teardown finds them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

ALL_SERVICES=(s3 dynamodb sqs sns eventbridge ssm logs iam-role lambda step-functions apigw-http cognito)
if [ "$#" -gt 0 ]; then SERVICES=("$@"); else SERVICES=("${ALL_SERVICES[@]}"); fi

REPORT="$SCRIPT_DIR/../docs/PREFLIGHT.md"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
trap 'echo; echo "Interrupted. Run ./scripts/teardown.sh destroy to remove any probe stack left behind."; exit 130' INT

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found in PATH." >&2; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "Cannot call AWS STS. Check credentials." >&2; exit 1; }

# Every template carries the same optional permissions-boundary parameter, so roles can be created
# in accounts that force one. The value "none" means "no boundary".
template_for() {
  cat <<'YAML'
Parameters:
  PermissionsBoundary:
    Type: String
    Default: none
Conditions:
  HasBoundary: !Not [!Equals [!Ref PermissionsBoundary, none]]
YAML
  case "$1" in
    s3) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::S3::Bucket
YAML
    ;;
    dynamodb) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::DynamoDB::Table
    Properties:
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - {AttributeName: pk, AttributeType: S}
      KeySchema:
        - {AttributeName: pk, KeyType: HASH}
YAML
    ;;
    sqs) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::SQS::Queue
YAML
    ;;
    sns) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::SNS::Topic
YAML
    ;;
    eventbridge) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::Events::EventBus
    Properties:
      Name: !Sub "${AWS::StackName}-bus"
YAML
    ;;
    ssm) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::SSM::Parameter
    Properties:
      Name: !Sub "/${AWS::StackName}/probe"
      Type: String
      Value: probe
YAML
    ;;
    logs) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub "/${AWS::StackName}/probe"
      RetentionInDays: 1
YAML
    ;;
    iam-role) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: {Service: lambda.amazonaws.com}
            Action: sts:AssumeRole
      PermissionsBoundary: !If [HasBoundary, !Ref PermissionsBoundary, !Ref "AWS::NoValue"]
YAML
    ;;
    lambda) cat <<'YAML'
Resources:
  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: {Service: lambda.amazonaws.com}
            Action: sts:AssumeRole
      PermissionsBoundary: !If [HasBoundary, !Ref PermissionsBoundary, !Ref "AWS::NoValue"]
  Probe:
    Type: AWS::Lambda::Function
    Properties:
      Runtime: python3.12
      Handler: index.handler
      Role: !GetAtt Role.Arn
      Code:
        ZipFile: |
          def handler(event, context):
              return "ok"
YAML
    ;;
    step-functions) cat <<'YAML'
Resources:
  Role:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: {Service: states.amazonaws.com}
            Action: sts:AssumeRole
      PermissionsBoundary: !If [HasBoundary, !Ref PermissionsBoundary, !Ref "AWS::NoValue"]
  Probe:
    Type: AWS::StepFunctions::StateMachine
    Properties:
      RoleArn: !GetAtt Role.Arn
      DefinitionString: '{"StartAt":"Done","States":{"Done":{"Type":"Pass","End":true}}}'
YAML
    ;;
    apigw-http) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::ApiGatewayV2::Api
    Properties:
      Name: !Sub "${AWS::StackName}-api"
      ProtocolType: HTTP
YAML
    ;;
    cognito) cat <<'YAML'
Resources:
  Probe:
    Type: AWS::Cognito::UserPool
    Properties:
      UserPoolName: !Sub "${AWS::StackName}-pool"
YAML
    ;;
    *) return 1 ;;
  esac
}

# Masks account IDs and ARNs, and keeps the note short enough for a table cell.
sanitize() {
  tr '\n|' '  ' \
    | sed -E -e 's#arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:[^ ]+#<arn>#g' \
             -e 's#[0-9]{12}#<account-id>#g' -e 's#  +# #g' \
    | cut -c1-220
}

RESULTS=()
OK_COUNT=0
DENIED_COUNT=0

probe() {
  local svc="$1" stack tpl out reason t
  stack="${STACK_PREFIX}-preflight-${svc}"
  tpl="$WORKDIR/${svc}.yaml"
  if ! template_for "$svc" > "$tpl"; then
    echo "  ?  $svc: unknown service (valid: ${ALL_SERVICES[*]})"
    return 0
  fi

  local tags=("Project=${PROJECT_TAG}" "ManagedBy=cloudformation")
  for t in $EXTRA_TAGS; do tags+=("$t"); done

  printf '  ...  %-16s ' "$svc"
  if out="$(aws cloudformation deploy --stack-name "$stack" --template-file "$tpl" \
      --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
      --parameter-overrides "PermissionsBoundary=${ROLE_PERMISSIONS_BOUNDARY:-none}" \
      --tags "${tags[@]}" 2>&1)"; then
    echo "OK"
    RESULTS+=("| $svc | OK | Created and deleted. |")
    OK_COUNT=$((OK_COUNT + 1))
  else
    reason="$(aws cloudformation describe-stack-events --stack-name "$stack" \
      --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].ResourceStatusReason | [0]" \
      --output text 2>/dev/null || true)"
    if [ -z "$reason" ] || [ "$reason" = "None" ]; then
      reason="$(printf '%s' "$out" | tail -n 3)"
    fi
    reason="$(printf '%s' "$reason" | sanitize)"
    echo "DENIED / FAILED"
    echo "       -> $reason"
    RESULTS+=("| $svc | DENIED / FAILED | $reason |")
    DENIED_COUNT=$((DENIED_COUNT + 1))
  fi

  # Always clean up, whether the probe worked or not (a failed create leaves ROLLBACK_COMPLETE).
  aws cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1 || true
  aws cloudformation wait stack-delete-complete --stack-name "$stack" >/dev/null 2>&1 \
    || echo "       (!) could not confirm deletion of $stack - run ./scripts/teardown.sh list"
}

echo "Preflight in region $AWS_REGION (stack prefix ${STACK_PREFIX}-preflight-*)"
echo
for svc in "${SERVICES[@]}"; do probe "$svc"; done

{
  echo "# Preflight: which AWS services this account allows"
  echo
  echo "Generated by \`scripts/preflight.sh\` on $(date -u '+%Y-%m-%d %H:%M UTC') in region \`$AWS_REGION\`."
  echo "Each service was probed by creating one minimal resource with CloudFormation and deleting it immediately."
  echo "Account IDs and ARNs are masked."
  echo
  echo "| Service | Result | Note |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${RESULTS[@]+"${RESULTS[@]}"}"
} > "$REPORT"

echo
echo "Summary: $OK_COUNT OK, $DENIED_COUNT denied/failed. Written to docs/PREFLIGHT.md (review it before committing)."
echo "Leftover check: ./scripts/teardown.sh list   (should report no stacks)"
