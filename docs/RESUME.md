# Resume guide

How to pick this project up cold after a long pause. Last updated: 2026-09-20 (end of Phase 0).

## 1. State in one paragraph

Phase  (guardrails) is complete. **Nothing is deployed in AWS**: no stacks, buckets or functions. Everything
needed to deploy, verify and remove resources is in this repository. The next work is Phase 1 (foundation).

## 2. Ten-minute checklist to get running again

1. Open the repository and read the last entries at the bottom of `docs/SETUP.md`.
2. Check the git identity of this repository. The global identity on the development machine is the work
   one, so this repo must carry its own local settings:
   `git config --local --list | grep -E 'user\.|credential'`
   Expected: personal name and email, `credential.https://github.com.username` and `credential.helper=osxkeychain`.
3. Check AWS access: `aws sts get-caller-identity`, then `export AWS_REGION=us-east-1`.
4. Confirm the clean baseline:
   - `./scripts/teardown.sh list` reports "No stacks found".
   - `./scripts/whats-running.sh` ends with "RESULT: nothing to review".
5. If the account may have changed since the last run, re-probe it: `./scripts/preflight.sh`
   (creates and deletes one tiny stack per service, a few minutes).

## 3. What to recreate

Nothing. Phase 0 leaves no AWS resources. From Phase 1 on, this section lists the stacks in deploy order.

## 4. Where everything is

| Path | Purpose |
| --- | --- |
| `scripts/config.sh` | Shared settings (stack prefix `sih`, `Project` tag, region). Personal overrides go in `scripts/config.local.sh` (git-ignored) |
| `scripts/teardown.sh` | `list`, `destroy`, `verify`, `check-arn <arn>` for this project's stacks |
| `scripts/preflight.sh` | Probes which AWS services the account allows |
| `scripts/whats-running.sh` | Read-only audit of all regions: is anything of mine still running? |
| `docs/SETUP.md` | Chronological build log with real outputs and incidents |
| `docs/TEARDOWN.md` | Runbook to remove everything, with and without the scripts |
| `docs/PREFLIGHT.md` | Generated result of the service probe |
| `docs/decisions/` | ADRs (one per real decision) |
| `cfn/`, `lambda/` | Templates and function code (empty until Phase 1) |

## 5. Conventions

- Stacks are named `sih-<NN>-<name>`; deploy in ascending order, destroy in descending order (ADR 002).
- Every stack is tagged `Project=serverless-incident-hub` and `ManagedBy=cloudformation`.
- Region `us-east-1`. Documentation in English. One unit of work per commit (change, add, commit, push together).
- Verify before moving on and paste the real output. Document each step when it is completed.
- One ADR per real decision. Incidents are documented with root cause and fix.

## 6. Known pitfalls (from real incidents)

- **Git identity:** the first commit once carried the work email. Set the repo-local identity before the first commit of any new project.
- **Tag index lag:** the Resource Groups Tagging API can list deleted resources for a long time. Never call something a leftover or clean based on it alone; `verify` confirms with the owning service.
- **CloudTrail** lags about 15 minutes and **Cost Explorer** about 24 hours.
- **Shared account:** other people's resources exist. Never delete anything that lacks the `sih-` prefix or the project tag.

## 7. Session close checklist

- [ ] `./scripts/teardown.sh list` shows no stacks (or only the ones intentionally kept, documented in `docs/SETUP.md`).
- [ ] `./scripts/whats-running.sh` reports nothing to review.
- [ ] Documentation for the session is committed and pushed.

## 8. Next step: Phase 1 (foundation)

1. Read-only check that AWS Budgets is reachable:
   `aws budgets describe-budgets --account-id "$(aws sts get-caller-identity --query Account --output text)"`
2. Write `cfn/00-bootstrap.yaml` (artifacts bucket for packaged Lambda code, tags).
3. Deploy it as `sih-00-bootstrap` with the project tags, verify the result, document it in `docs/SETUP.md`, and
   write an ADR if a real decision comes out of it.
4. End the phase by destroying the stack or explicitly documenting that it was kept.
