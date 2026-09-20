# ADR 002: Layered stacks, naming convention and teardown order

- **Status:** Proposed (to be marked *Accepted* after the Phase 0 preflight)
- **Date:** 2026-09-19
- **Related:** ADR 001, `docs/TEARDOWN.md`, `scripts/teardown.sh`

## Context

In [`modular-cicd-pipeline`](https://github.com/velasqueziturrate/modular-cicd-pipeline) an accidental
`terraform destroy` removed resources that were meant to be permanent, because permanent and
ephemeral resources shared the same state. The fix there was to separate them by lifecycle.

Here the situation is the opposite: **nothing is permanent**. The account is borrowed, so the whole
project must be disposable in one operation, in a predictable order, without the risk of forgetting
something. The lifecycle lesson still applies in a different form: separate stacks by *layer*, so
that redeploying the compute layer never touches data, and so that deletion order is obvious.

## Decision

1. **Naming:** every stack is called `sih-<NN>-<name>` (`sih` = serverless incident hub). `NN` is the
   layer number. Deploy in ascending order, destroy in descending order.
2. **Planned layers:**

   | NN | Stack | Contents |
   | --- | --- | --- |
   | 00 | `bootstrap` | Artifacts bucket for packaged Lambda code (deleted last) |
   | 10 | `data` | DynamoDB, S3 buckets |
   | 20 | `messaging` | EventBridge bus, SQS queues + DLQs, SNS topics |
   | 30 | `compute` | Lambda functions, Step Functions, schedulers |
   | 40 | `api` | API Gateway, Cognito |
   | 50 | `frontend` | S3 + CloudFront |
   | 90 | `observability` | CloudWatch dashboards/alarms, budget alert (deleted first) |

   The list is a plan; phases may add or drop layers based on what the account allows (`docs/PREFLIGHT.md`).
3. **No nested stacks.** `teardown.sh` deletes top-level stacks and empties their buckets; nesting would hide resources from it.
4. **Tags:** every stack is deployed with `--tags Project=serverless-incident-hub ManagedBy=cloudformation`
   (plus any tags the host account requires). CloudFormation propagates stack tags to resources that support tagging, which powers the leftover search.
5. **Names:** all named resources start with `sih-`. Log groups are declared explicitly in the templates
   (`/aws/lambda/<function name>` for Lambda) so they are deleted with the stack.
6. **Everything deletable:** default `DeletionPolicy` (delete), no termination protection, no `Retain`. Data in this project is demo data.
7. **Avoid idle-cost and slow-delete resources** (NAT gateways, interface endpoints, provisioned capacity,
   Lambda@Edge, customer-managed KMS keys, Secrets Manager) unless a phase documents the reason and its teardown.
   Configuration values go to SSM Parameter Store (standard tier) by default.
8. **Circuit breakers by design:** reserved concurrency and short timeouts on Lambda, API throttling,
   DLQs, and a budget alert when permissions allow it (Budgets may require billing permissions the borrowed account does not grant).
9. **Preflight first:** before designing a layer, `scripts/preflight.sh` probes whether the account allows its services (an Organizations SCP already blocked ECR in the previous project; see its ADR 003).

## Consequences

**Positive**

- Teardown is one command (or a predictable console procedure) and its order is encoded in the stack names.
- Redeploying a layer does not affect the others; failures are contained.
- Leftovers are detectable by prefix and by tag.

**Negative / trade-offs**

- More stacks means more cross-stack references (Outputs/Exports). Exports also protect ordering (a stack whose export is in use cannot be deleted), but they cannot be changed while imported.
- Numeric prefixes are a convention, not something CloudFormation enforces.
- Not using KMS CMKs or Secrets Manager by default gives up features that a production system would likely use; the trade-off is documented and revisited per phase.
