#!/usr/bin/env bash
# teardown.sh - list, destroy or verify every AWS resource created by this project.
#
# Usage:
#   ./scripts/teardown.sh list      # default. Read-only: shows what "destroy" would delete
#   ./scripts/teardown.sh destroy   # deletes all project stacks (asks for confirmation)
#   ./scripts/teardown.sh verify    # looks for leftovers that CloudFormation does not remove
#
# Everything is found by the stack-name prefix (STACK_PREFIX, default "sih") and deleted in
# reverse alphabetical order, i.e. sih-90-* first ... sih-00-* last (see ADR 002).
# The script is idempotent: if something fails, fix the cause and run it again.
#
# Written to run on macOS's default bash 3.2 as well as on modern bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

MODE="${1:-list}"

# Stack states in which a stack can be deleted (in-progress states are excluded on purpose).
STABLE_STATUSES=(CREATE_COMPLETE CREATE_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED
  UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED DELETE_FAILED
  IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE IMPORT_ROLLBACK_FAILED REVIEW_IN_PROGRESS)

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found in PATH."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
  || die "Cannot call AWS STS. Check your credentials / profile (aws sts get-caller-identity)."

# Prints one item per line, dropping blanks and the literal "None" the CLI prints for null.
clean_lines() { tr '\t' '\n' | sed -e '/^$/d' -e '/^None$/d'; }

list_stacks() {
  aws cloudformation list-stacks \
    --stack-status-filter "${STABLE_STATUSES[@]}" \
    --query "StackSummaries[?starts_with(StackName, '${STACK_PREFIX}-') && ParentId==null].StackName" \
    --output text | clean_lines | sort -r
}

stack_buckets() {
  aws cloudformation list-stack-resources --stack-name "$1" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket' && ResourceStatus!='DELETE_COMPLETE'].PhysicalResourceId" \
    --output text | clean_lines
}

# Empties a bucket completely: current objects, old versions and delete markers.
# (Buckets under S3 Object Lock retention cannot be emptied this way - see docs/TEARDOWN.md.)
empty_bucket() {
  local bucket="$1" payload
  log "    emptying s3://$bucket"
  aws s3 rm "s3://$bucket" --recursive --only-show-errors || true
  while true; do
    # shellcheck disable=SC2016  # the backticks are a JMESPath literal, not a shell expansion
    payload="$(aws s3api list-object-versions --bucket "$bucket" --max-items 500 \
      --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}, Quiet: `true`}' \
      --output json)" || { log "    could not list versions of $bucket"; return 1; }
    if ! printf '%s' "$payload" | grep -q '"Key"'; then
      break
    fi
    aws s3api delete-objects --bucket "$bucket" --delete "$payload" >/dev/null
  done
}

delete_stack() {
  local stack="$1" bucket
  log "==> $stack"
  # Full teardown is the goal here, so termination protection must not get in the way.
  aws cloudformation update-termination-protection --no-enable-termination-protection \
    --stack-name "$stack" >/dev/null 2>&1 || true
  while IFS= read -r bucket; do
    if [ -n "$bucket" ]; then empty_bucket "$bucket"; fi
  done < <(stack_buckets "$stack")
  aws cloudformation delete-stack --stack-name "$stack"
  if aws cloudformation wait stack-delete-complete --stack-name "$stack"; then
    log "    deleted"
  else
    log "    FAILED. Resources that could not be deleted:"
    aws cloudformation list-stack-resources --stack-name "$stack" \
      --query "StackResourceSummaries[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceType,ResourceStatusReason]" \
      --output text | sed 's/^/      /' || true
    return 1
  fi
}

load_stacks() {
  STACKS=()
  local line
  while IFS= read -r line; do
    if [ -n "$line" ]; then STACKS+=("$line"); fi
  done < <(list_stacks)
}

show_plan() {
  log "AWS account : $ACCOUNT_ID"
  log "Region      : $AWS_REGION"
  log "Stack prefix: ${STACK_PREFIX}-   (delete order below)"
  log ""
  if [ "${#STACKS[@]}" -eq 0 ]; then
    log "No stacks found. Nothing to delete."
    return 0
  fi
  local s b
  for s in "${STACKS[@]}"; do
    log "  - $s"
    while IFS= read -r b; do
      if [ -n "$b" ]; then log "        S3 bucket (will be emptied): $b"; fi
    done < <(stack_buckets "$s")
  done
}

FOUND=0
report() { # $1 = title, $2 = newline separated findings
  if [ -n "$2" ]; then
    FOUND=$((FOUND + 1))
    log "  [!!] $1"
    printf '%s\n' "$2" | sed 's/^/         /'
  else
    log "  [ok] $1: none"
  fi
}

case "$MODE" in
  list)
    load_stacks
    show_plan
    ;;

  destroy)
    load_stacks
    show_plan
    if [ "${#STACKS[@]}" -eq 0 ]; then exit 0; fi
    log ""
    if [ "${CONFIRM_ACCOUNT_ID:-}" != "$ACCOUNT_ID" ]; then
      printf 'This DELETES the stacks above. Type the AWS account ID (%s) to confirm: ' "$ACCOUNT_ID"
      read -r answer
      [ "$answer" = "$ACCOUNT_ID" ] || die "Confirmation did not match. Nothing was deleted."
    fi
    FAILED=()
    for s in "${STACKS[@]}"; do
      if ! delete_stack "$s"; then FAILED+=("$s"); fi
    done
    log ""
    if [ "${#FAILED[@]}" -gt 0 ]; then
      log "Some stacks failed to delete: ${FAILED[*]}"
      log "Read the reasons above, fix them (see docs/TEARDOWN.md, 'Common failures') and run again."
      exit 1
    fi
    log "All project stacks deleted. Now run: ./scripts/teardown.sh verify"
    ;;

  verify)
    log "AWS account : $ACCOUNT_ID"
    log "Region      : $AWS_REGION"
    log "Looking for leftovers (things CloudFormation does not always remove)..."
    log ""
    load_stacks
    report "CloudFormation stacks" "$(printf '%s\n' "${STACKS[@]+"${STACKS[@]}"}")"
    report "Resources tagged Project=$PROJECT_TAG" "$(aws resourcegroupstaggingapi get-resources \
      --tag-filters "Key=Project,Values=$PROJECT_TAG" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | clean_lines || true)"
    report "S3 buckets named ${STACK_PREFIX}-*" "$(aws s3api list-buckets \
      --query "Buckets[?starts_with(Name, '${STACK_PREFIX}-')].Name" --output text 2>/dev/null | clean_lines || true)"
    for prefix in "/aws/lambda/${STACK_PREFIX}-" "/${STACK_PREFIX}/" "/aws/vendedlogs/${STACK_PREFIX}"; do
      report "CloudWatch log groups $prefix*" "$(aws logs describe-log-groups --log-group-name-prefix "$prefix" \
        --query 'logGroups[].logGroupName' --output text 2>/dev/null | clean_lines || true)"
    done
    report "IAM roles named ${STACK_PREFIX}-*" "$(aws iam list-roles \
      --query "Roles[?starts_with(RoleName, '${STACK_PREFIX}-')].RoleName" --output text 2>/dev/null | clean_lines || true)"
    log ""
    log "Not covered by this script (check by hand, see docs/TEARDOWN.md): KMS keys or Secrets Manager"
    log "secrets in 'pending deletion', CloudFront distributions in other accounts/regions, and cost data"
    log "(Cost Explorer lags by up to ~24h, so look again tomorrow)."
    if [ "$FOUND" -gt 0 ]; then
      log ""
      log "Leftovers found. Delete them by hand or re-run destroy if stacks remain."
      exit 1
    fi
    log ""
    log "Clean: no project resources found."
    ;;

  *)
    die "Unknown mode '$MODE'. Use: list | destroy | verify"
    ;;
esac
