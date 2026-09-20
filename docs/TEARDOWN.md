# Teardown Runbook

This project runs in an AWS account that is **not mine** (borrowed / shared), and the person who
built it may not be around to clean up. This document is written so that *anyone* with access to the
account can stop all spending and remove every resource of the project in a few minutes, with or
without the helper script.

**Rule zero:** nothing in this project is created outside CloudFormation, so everything can be removed
by deleting stacks. Every stack is named `sih-<NN>-<name>` and carries the tag `Project=serverless-incident-hub`.

## 1. Fast path (2 commands)

```bash
export AWS_REGION=us-east-1          # the region the project was deployed to
./scripts/teardown.sh list           # read-only: shows the stacks and buckets it will delete
./scripts/teardown.sh destroy        # asks you to type the account ID, then deletes everything
./scripts/teardown.sh verify         # looks for leftovers CloudFormation does not remove
```

`destroy` empties the S3 buckets of each stack (including old versions and delete markers), deletes
stacks from the highest number to the lowest (`sih-90-*` first, `sih-00-*` last) and prints the reason
for any resource that refuses to go away. It is safe to run again after fixing a failure.

Requirements: AWS CLI configured for the right account (`aws sts get-caller-identity`) and bash.

## 2. No script? Use the console (no terminal needed)

The console may be in English or Spanish; both names are given.

1. Make sure you are in the right **account** and **region** (top-right corner of the console).
2. Open **CloudFormation** > **Stacks** (**Pilas**).
3. Filter by name `sih-`. Delete stacks **from the highest number to the lowest**
   (`sih-90-…`, `sih-50-…`, … `sih-00-…`): select the stack > **Delete** (**Eliminar**) > confirm.
4. If a stack ends in `DELETE_FAILED` and mentions an S3 bucket: open **S3**, select the bucket >
   **Empty** (**Vaciar**) > then **Delete** (**Eliminar**) the stack again.
5. Check for leftovers: **Resource Groups & Tag Editor** (**Grupos de recursos y Editor de etiquetas**)
   > **Tag Editor** > *Find resources* > tag `Project` = `serverless-incident-hub`, region = all regions.

## 3. Terminal without the script

```bash
# Delete every project stack (highest number first). S3 buckets must already be empty.
for s in $(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE DELETE_FAILED CREATE_FAILED \
    --query "StackSummaries[?starts_with(StackName,'sih-') && ParentId==null].StackName" \
    --output text | tr '\t' '\n' | sort -r); do
  aws cloudformation delete-stack --stack-name "$s" && aws cloudformation wait stack-delete-complete --stack-name "$s"
done
```

## 4. What costs money while it sits idle?

Serverless services are mostly pay-per-use: with no traffic they cost (almost) nothing. The real
risks are runaway usage and the few resources with a flat charge while they exist.

| Category | Examples | Rule in this project |
| --- | --- | --- |
| Pay-per-use, ~free at rest | Lambda, API Gateway, SQS, SNS, EventBridge, Step Functions (Standard), DynamoDB on-demand, Cognito (free tier), CloudFront, S3 storage of small data | Allowed by default |
| Flat charge while it exists | CloudWatch dashboards and custom metrics, customer-managed KMS keys, Secrets Manager secrets, WAF web ACLs, Route 53 hosted zones, AWS Config | Only in a phase that documents it; deleted first |
| Avoided entirely | NAT gateways, interface VPC endpoints, provisioned DynamoDB capacity, OpenSearch, RDS/Aurora, Kinesis provisioned shards, Lambda@Edge | Not used (cost, or slow / blocked deletion) |

Check current prices on the AWS pricing pages; they change.

## 5. Circuit breakers (stopping a runaway, not just deleting)

The classic serverless bill shock is an **event loop** (for example, a Lambda writes to the same S3
bucket or event bus that triggers it). Guards built into the design:

- Every Lambda has a **reserved concurrency** cap and a short timeout.
- API Gateway has stage-level **throttling** (rate and burst limits).
- SQS queues have a **dead-letter queue** and a bounded `maxReceiveCount`, so failing messages stop retrying.
- Event routing never re-emits an event to the bus it came from without a hop counter.
- A **budget alert** (AWS Budgets) is created when the account permissions allow it (see ADR 002).

Emergency stop without deleting anything: in the console set each Lambda's reserved concurrency to
`0` (**Lambda** > function > **Configuration** > **Concurrency**), disable the EventBridge rules
(**EventBridge** > **Rules** > **Disable**) and stop running Step Functions executions.
Then run the fast path when convenient.

## 6. Common failures and fixes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `DELETE_FAILED`, bucket "not empty" | Buckets must be empty before deletion | Run the script (it empties them) or **Empty** (**Vaciar**) in the console, then delete the stack again |
| `DELETE_FAILED` on a resource you cannot delete | Resource already removed by hand, or blocked by a permission/SCP | Delete the stack again and choose to **retain** that resource (console: *Delete* > *Retain resources*; CLI: `--retain-resources LogicalId`), then remove it manually |
| "Export … cannot be deleted as it is in use" | Another stack imports it | Delete the importing stack first (higher number) |
| Stack is `*_IN_PROGRESS` | An operation is still running | Wait, or `aws cloudformation cancel-update-stack`; then delete |
| Stack is `ROLLBACK_COMPLETE` | Creation failed and rolled back | It can only be deleted, not updated: delete it |
| Termination protection error | Protection enabled on a stack | The script disables it; by hand: **Stack actions** > **Edit termination protection** |
| CloudFront distribution takes 15-20+ minutes | Normal: it must be disabled and propagated first | Wait |
| Orphan log groups after the stacks are gone | A Lambda log group that was not declared in the template | `./scripts/teardown.sh verify` lists them; delete under **CloudWatch** > **Log groups** (**Grupos de registros**). Templates declare their log groups to avoid this |
| KMS key / Secrets Manager secret "pending deletion" | These services delay deletion on purpose (recovery window) | Nothing to do; the name may stay reserved during the window |
| Bucket with S3 Object Lock | Retained versions cannot be deleted before the retention expires | Not used in this project |

## 7. Verification checklist (after destroy)

- [ ] `./scripts/teardown.sh list` reports no stacks.
- [ ] `./scripts/teardown.sh verify` prints "Clean".
- [ ] Console: CloudFormation shows no `sih-*` stacks in the project region.
- [ ] Resources in `us-east-1` if the project used global services (CloudFront, IAM, ACM, WAF).
- [ ] Billing > **Cost Explorer** (**Explorador de costos**), filtered by tag `Project`: look again the next
      day (data can lag ~24 hours) and confirm cost is flat at zero.
- [ ] Tell the account owner it is done.

## 8. Limits of this runbook (honest notes)

- `teardown.sh` was tested against a local AWS emulator (moto), not against a real account yet. The
  first real run should be `list`, which changes nothing.
- The tag search only sees resources that support tagging and were tagged; the name-prefix checks in
  `verify` cover the common gaps, not every possible one.
- Costs shown by AWS can lag; the checklist item on cost data is a next-day task.
