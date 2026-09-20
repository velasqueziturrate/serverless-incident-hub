#!/usr/bin/env bash
# whats-running.sh - quick, read-only audit: is anything of mine still running or left behind?
#
# Usage:
#   ./scripts/whats-running.sh        # last 3 days of CloudTrail history
#   ./scripts/whats-running.sh 14     # last 14 days
#
# For every enabled region it checks:
#   1. project stacks that still exist (CloudFormation, names starting with STACK_PREFIX-)
#   2. resources tagged Project=<PROJECT_TAG> (plus AUDIT_EXTRA_PROJECT_TAGS). Each one is confirmed
#      with its own service, because the tag index can keep listing resources that were deleted
#   3. EC2 instances launched with the key pair AUDIT_EC2_KEY_PATTERN (pending/running/stopped)
#   4. what this identity created vs deleted through the API (CloudTrail event history): a Create*
#      with fewer matching Delete* events is flagged as a possible leftover (heuristic)
#
# Read-only: it never creates, changes or deletes anything.
# Exit code: 0 = nothing to review, 1 = items to review, 2 = bad usage.
#
# Limits: CloudTrail lags ~15 minutes; only API actions by this identity inside the window are
# seen (older resources, or resources made by other identities, only show up through tags).
# Runs on macOS's default bash 3.2 and on modern bash.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

DAYS="${1:-${AUDIT_DAYS:-3}}"
case "$DAYS" in
  ''|*[!0-9]*) echo "Usage: ./scripts/whats-running.sh [days]   (days must be a number)" >&2; exit 2 ;;
esac

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found in PATH." >&2; exit 1; }

IDENTITY_ARN="$(aws sts get-caller-identity --query Arn --output text)" \
  || { echo "ERROR: cannot call AWS STS. Check your credentials / profile." >&2; exit 1; }
USER_NAME="${AUDIT_USERNAME:-${IDENTITY_ARN##*/}}"

if ! SINCE="$(date -u -v-"${DAYS}"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then   # macOS / BSD date
  SINCE="$(date -u -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')"                 # GNU date
fi

REGIONS="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)" \
  || { echo "ERROR: cannot list regions." >&2; exit 1; }

EVENTS="$(mktemp)"
trap 'rm -f "$EVENTS"' EXIT
ITEMS=0
BUF=""
add() { BUF="${BUF}   $1"$'\n'; }
clean() { sed -e '/^$/d' -e '/^None$/d'; }

echo "Identity : $IDENTITY_ARN"
echo "Window   : last $DAYS day(s), since $SINCE"
# shellcheck disable=SC2086  # splitting the tab-separated region list is intended
echo "Regions  : $(printf '%s\n' $REGIONS | wc -l | tr -d ' ') enabled regions scanned"
echo "Read-only: nothing is created, changed or deleted"
echo

for r in $REGIONS; do
  BUF=""

  # 1) Project stacks that still exist
  stacks="$(aws cloudformation list-stacks --region "$r" \
    --stack-status-filter CREATE_COMPLETE CREATE_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED \
      UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED DELETE_FAILED \
      CREATE_IN_PROGRESS UPDATE_IN_PROGRESS DELETE_IN_PROGRESS REVIEW_IN_PROGRESS \
    --query "StackSummaries[?starts_with(StackName, '${STACK_PREFIX}-')].[StackName,StackStatus]" \
    --output text 2>/dev/null | clean)"
  while IFS= read -r line; do
    if [ -n "$line" ]; then add "[REVIEW] CloudFormation stack still exists: $line"; ITEMS=$((ITEMS + 1)); fi
  done <<< "$stacks"

  # 2) Tagged resources, each confirmed with its own service
  for v in "$PROJECT_TAG" $AUDIT_EXTRA_PROJECT_TAGS; do
    # shellcheck disable=SC2016  # the backticks are a JMESPath literal, not a shell expansion
    tagged="$(aws resourcegroupstaggingapi get-resources --region "$r" \
      --tag-filters "Key=Project,Values=$v" \
      --query 'ResourceTagMappingList[].[ResourceARN,Tags[?Key==`Owner`]|[0].Value]' \
      --output text 2>/dev/null | clean)"
    while IFS=$'\t' read -r arn owner; do
      if [ -z "$arn" ]; then continue; fi
      state="$(AWS_REGION="$r" AWS_DEFAULT_REGION="$r" "$SCRIPT_DIR/teardown.sh" check-arn "$arn" 2>/dev/null | awk '{print $1}')"
      case "$state" in
        gone)  add "[stale tag] deleted already, the tag index lags: $arn" ;;
        alive) add "[REVIEW] still exists, tagged Project=$v (Owner=${owner:-None}): $arn"; ITEMS=$((ITEMS + 1)) ;;
        *)     add "[REVIEW] tagged Project=$v (Owner=${owner:-None}), cannot be checked automatically: $arn"; ITEMS=$((ITEMS + 1)) ;;
      esac
    done <<< "$tagged"
  done

  # 3) EC2 instances that use the project key pair
  inst="$(aws ec2 describe-instances --region "$r" \
    --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
              "Name=key-name,Values=$AUDIT_EC2_KEY_PATTERN" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' \
    --output text 2>/dev/null | clean)"
  while IFS= read -r line; do
    if [ -n "$line" ]; then add "[REVIEW] EC2 instance with key pair $AUDIT_EC2_KEY_PATTERN: $line"; ITEMS=$((ITEMS + 1)); fi
  done <<< "$inst"

  # 4) Write events by this identity (kept for the created-vs-deleted balance below)
  aws cloudtrail lookup-events --region "$r" --start-time "$SINCE" \
    --lookup-attributes "AttributeKey=Username,AttributeValue=$USER_NAME" \
    --query "Events[?contains(CloudTrailEvent, '\"readOnly\":false')].EventName" \
    --output text 2>/dev/null | tr '\t' '\n' | clean | sort | uniq -c \
    | awk -v r="$r" '{print r "\t" $1 "\t" $2}' >> "$EVENTS"

  if [ -n "$BUF" ]; then
    echo "== $r"
    printf '%s' "$BUF"
  fi
done

# Created vs deleted, per region (heuristic: counts API calls, not resources)
FLAGGED="$(awk -F'\t' '
  { c[$1 SUBSEP $3] = $2; seen[$1 SUBSEP $3] = 1 }
  END {
    for (k in seen) {
      split(k, p, SUBSEP); r = p[1]; n = p[2]; other = ""
      if (n ~ /^Create/ && n != "CreateChangeSet") other = "Delete" substr(n, 7)
      else if (n == "RunInstances") other = "TerminateInstances"
      else if (n == "AllocateAddress") other = "ReleaseAddress"
      if (other == "") continue
      made = c[k]; gone = c[r SUBSEP other] + 0
      if (made > gone) printf "%s\t%s\t%d\t%d\t%s\n", r, n, made, gone, other
    }
  }' "$EVENTS" | sort)"

echo "== API activity by $USER_NAME (created vs deleted, heuristic)"
if [ -z "$FLAGGED" ]; then
  echo "   every Create/Run in the window has a matching Delete/Terminate"
else
  while IFS=$'\t' read -r reg name made gone other; do
    if [ -z "$name" ]; then continue; fi
    case "$name" in
      CreateKeyPair|CreateServiceLinkedRole)
        echo "   [free] $reg: $name x$made vs $other x$gone (this kind of resource costs nothing)" ;;
      *)
        echo "   [REVIEW] $reg: $name x$made vs $other x$gone - possible leftover"
        ITEMS=$((ITEMS + 1)) ;;
    esac
  done <<< "$FLAGGED"
fi

echo
if [ "$ITEMS" -eq 0 ]; then
  echo "RESULT: nothing to review. No project stacks, no live tagged resources, no project EC2, and"
  echo "        every billable Create in the last $DAYS day(s) has a matching Delete."
  exit 0
fi
echo "RESULT: $ITEMS item(s) to review (marked [REVIEW] above). Nothing was changed."
exit 1
