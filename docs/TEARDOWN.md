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
| `verify` lists a tagged resource that no longer exists | The tagging API is eventually consistent and can keep listing deleted resources (seen with a Cognito user pool that was still listed about 14 minutes after its stack was deleted) | `verify` asks the owning service about every tagged ARN and reports deleted ones as stale index entries. For a type it cannot check, run `./scripts/teardown.sh check-arn <arn>` (prints `alive`, `gone` or `unknown`) |

## 7. Verification checklist (after destroy)

- [ ] `./scripts/teardown.sh list` reports no stacks.
- [ ] `./scripts/teardown.sh verify` prints "Clean".
- [ ] `./scripts/whats-running.sh` ends with "RESULT: nothing to review" (all regions, read-only).
- [ ] Console: CloudFormation shows no `sih-*` stacks in the project region.
- [ ] Resources in `us-east-1` if the project used global services (CloudFront, IAM, ACM, WAF).
- [ ] Billing > **Cost Explorer** (**Explorador de costos**), filtered by tag `Project`: look again the next
      day (data can lag ~24 hours) and confirm cost is flat at zero.
- [ ] Tell the account owner it is done.

## 8. Limits of this runbook (honest notes)

- `list` (step 0.3) and `verify` (step 0.5) have been run against the real account. `destroy` has so far
  only been tested against a local AWS emulator (moto), so the first real `destroy` should follow a `list`.
- `verify` confirms tagged resources with their own service for: Cognito, SNS, SQS, DynamoDB, Lambda,
  Step Functions, EventBridge buses, S3, SSM parameters and API Gateway. Other types are reported as
  "cannot check" and need a manual look (`check-arn` or the console).
- The tag search only sees resources that support tagging and were tagged; the name-prefix checks in
  `verify` cover the common gaps, not every possible one.
- Costs shown by AWS can lag; the checklist item on cost data is a next-day task.

## 9. Quick audit: is anything of mine still running?

`teardown.sh` only knows this project. To answer the wider question (*is anything at all left in my name,
in any region, that could be costing money?*) there is a second, read-only script:

```bash
./scripts/whats-running.sh        # last 3 days of CloudTrail history
./scripts/whats-running.sh 14     # last 14 days
```

For every enabled region it checks four things:

1. **Project stacks** (`sih-*`) that still exist.
2. **Tagged resources** (`Project=serverless-incident-hub`, plus any extra project tags you configure). Each one is
   confirmed with its own service, so a stale tag-index entry is reported as `[stale tag]` and not as a leftover.
3. **EC2 instances** launched with the project key pair (running, pending or stopped: stopped ones still pay for their disks).
4. **Created vs deleted**: what your identity created through the API (from CloudTrail) against what it deleted.
   A `Create*` with fewer matching `Delete*` events is marked `[REVIEW]`. Key pairs and service-linked roles are marked
   `[free]`: they stay behind by design and cost nothing.

Reading the result: exit code `0` and "RESULT: nothing to review" means nothing billable was found. `[REVIEW]` lines
say what to look at; the script never changes anything.

Personal settings live in `scripts/config.local.sh`, which is git-ignored (so client or employer names never reach
the public repository), for example:

```bash
AUDIT_EXTRA_PROJECT_TAGS="tag-value-of-an-earlier-project"
AUDIT_EC2_KEY_PATTERN="my-key-pair*"
```

Limits (honest notes):

- CloudTrail lags about 15 minutes, so the last few minutes of activity may be missing.
- It only sees API actions by *this identity* inside the window. Older resources, or resources created by other
  identities, are found only through tags.
- The created-vs-deleted balance is a heuristic: it counts API calls, not resources.
- It does not read billing data. Cost Explorer (**Explorador de costos**) is the source of truth for money, and it lags about 24 hours.
