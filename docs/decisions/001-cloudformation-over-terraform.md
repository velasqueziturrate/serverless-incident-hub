# ADR 001: CloudFormation as the IaC tool (instead of Terraform, SAM or CDK)

- **Status:** Proposed (to be marked *Accepted* once confirmed after the Phase 0 preflight)
- **Date:** 2026-09-19
- **Related:** ADR 002 (stack layering and teardown order), `docs/TEARDOWN.md`

## Context

This project is built in an AWS account that belongs to someone else. Three constraints shape the
choice of infrastructure-as-code tool:

1. **Everything must be removable quickly and by anyone.** The author may lose access to the tools or
   assistants used to build it at any time, so cleanup cannot depend on a specific laptop or on local state.
2. **Cost control comes first.** The rule from the previous project still applies: create, verify, destroy.
3. **Portfolio breadth.** The previous project, [`modular-cicd-pipeline`](https://github.com/velasqueziturrate/modular-cicd-pipeline),
   already demonstrates Terraform. Repeating it would add little; a second tool shows the trade-offs.

## Decision

Use **plain CloudFormation** (YAML templates, deployed with the AWS CLI), organised as several
small stacks by layer (ADR 002). Lambda code is packaged with `aws cloudformation package` into an
artifacts bucket that lives in the bootstrap stack.

## Alternatives considered

| Option | For | Against (in this context) | Verdict |
| --- | --- | --- | --- |
| **Terraform** | Readable `plan`, huge ecosystem, multi-cloud, already used in my first project | State lives in a backend plus local config (`init`, credentials, matching versions). If the state or machine is unavailable, cleanup falls back to the console, resource by resource | Not chosen here; used and documented in `modular-cicd-pipeline` |
| **CloudFormation** | State is kept by AWS itself: `delete-stack` works from the console or any CLI, with no local files. Change sets act as a plan. Drift detection. Native to every AWS service, including brand new ones | Verbose, slow feedback loop, limited logic, AWS-only. Some resources are not removed with the stack (e.g. Lambda log groups that are not declared) and non-empty S3 buckets block deletion | **Chosen** |
| **AWS SAM** | Much less boilerplate for Lambda, API Gateway, Step Functions; `sam delete` | It *is* CloudFormation with a transform, so the underlying resource model is hidden, which is what this portfolio wants to show | Documented alternative, not implemented |
| **AWS CDK** | Real programming language, high-level constructs | Needs a one-time *bootstrap* stack with roles and a bucket that `cdk destroy` does not remove, which goes against "leave nothing behind" in a borrowed account | Not chosen |

## Consequences

**Positive**

- Cleanup does not depend on anything stored on my machine: the console path in `docs/TEARDOWN.md` works for any person with access.
- The portfolio now shows two IaC tools and the reasoning for each, not just tool usage.
- Change sets give a review step before touching infrastructure.

**Negative / risks (and how they are handled)**

- Non-empty S3 buckets block stack deletion: `scripts/teardown.sh` empties them first.
- Resources created implicitly (Lambda log groups) can outlive the stack: templates declare them explicitly and `teardown.sh verify` looks for stragglers.
- CloudFormation is slower and more verbose than Terraform: accepted; small stacks and `cfn-lint` keep it manageable.
- Stack failures can leave `ROLLBACK_COMPLETE` stacks that must be deleted before retrying: documented in the runbook.
