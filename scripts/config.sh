# shellcheck shell=bash
# Shared configuration for every helper script in this folder.
# Source it, do not execute it. Override any value with an environment variable, e.g.:
#   AWS_REGION=eu-west-1 EXTRA_TAGS="Owner=daniel Environment=dev" ./scripts/teardown.sh list

# Every stack of this project is named "<STACK_PREFIX>-<NN>-<name>" (see ADR 002).
STACK_PREFIX="${STACK_PREFIX:-sih}"

# Value of the "Project" tag applied to every stack (and propagated to its resources).
PROJECT_TAG="${PROJECT_TAG:-serverless-incident-hub}"

# Region used by every command (us-east-1: broadest service availability, and the
# region where global services such as CloudFront/ACM/WAF are managed).
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

# Extra tags the host account may require, space separated (KEY=VALUE KEY=VALUE).
EXTRA_TAGS="${EXTRA_TAGS:-}"

# ARN of the IAM permissions boundary, if the account forces one on every role.
# Leave empty when not required.
ROLE_PERMISSIONS_BOUNDARY="${ROLE_PERMISSIONS_BOUNDARY:-}"

# --- Settings for scripts/whats-running.sh (quick audit) ---------------------------------------
# Other values of the "Project" tag to look for, space separated (e.g. the tag used by an
# earlier project). Better set in scripts/config.local.sh, which is git-ignored.
AUDIT_EXTRA_PROJECT_TAGS="${AUDIT_EXTRA_PROJECT_TAGS:-}"

# EC2 key pair name (wildcards allowed) whose instances must never be left running.
AUDIT_EC2_KEY_PATTERN="${AUDIT_EC2_KEY_PATTERN:-modular-cicd-ansible*}"

# IAM user or role name whose API activity is audited. Empty = the current identity.
AUDIT_USERNAME="${AUDIT_USERNAME:-}"

# Personal, machine-local overrides (git-ignored). Sourced last so it wins over the defaults above.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
fi
