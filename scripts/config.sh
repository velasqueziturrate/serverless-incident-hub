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
