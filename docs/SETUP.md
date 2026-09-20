# Setup log

Chronological record of how this project was built: what was run, what happened, what failed and how
it was fixed. Entries are added **after** each step is executed for real (command, real output, result),
never before. Decisions that come out of a step become ADRs in `docs/decisions/`.

Conventions: region `us-east-1`; stacks named `sih-<NN>-<name>`; docs in English.

---

## Phase 0 - Guardrails (teardown first)

Goal: before creating a single real resource, know how to remove everything, and know which services
the account allows.

Status: **complete (0.1 to 0.6 done).**

### Steps

- [x] 0.1 Create the GitHub repository `serverless-incident-hub` under the personal account and push this scaffold.
- [x] 0.2 Confirm the AWS identity and account: `aws sts get-caller-identity` (do not commit the account ID).
- [x] 0.3 Dry-run the teardown script: `./scripts/teardown.sh list` (expected: "No stacks found").
- [x] 0.4 Run the preflight: `./scripts/preflight.sh`, then review and commit `docs/PREFLIGHT.md`.
- [x] 0.5 Confirm nothing is left behind: `./scripts/teardown.sh list` and `./scripts/teardown.sh verify`.
- [x] 0.6 Mark ADR 001 and ADR 002 as *Accepted* (or adjust them) based on the preflight results.

### Log

_Each executed step is recorded in this format:_

```
#### 0.X <step title> - <date>
Command:   ...
Output:    ... (real, trimmed)
Result:    OK | problem found
Fix/notes: ...
```

#### 0.1 Create the repository and push the scaffold - 2026-09-20

Commands:

    git init -b main && git add . && git commit -m "Phase 0: teardown tooling, runbook and ADRs"
    git remote add origin https://github.com/velasqueziturrate/serverless-incident-hub.git
    git -c credential.helper= push -u origin main

Result: the first push failed (incident 1) and the first commit carried the wrong author (incident 2).
Both were fixed before anything was published. Final push:

    To https://github.com/velasqueziturrate/serverless-incident-hub.git
     * [new branch]      main -> main
    branch 'main' set up to track 'origin/main'.

Verification:

    git log -1 --format='autor: %an <%ae>%ncommitter: %cn <%ce>'
    autor: Daniel Velásquez Iturrate <velasqueziturrate@gmail.com>
    committer: Daniel Velásquez Iturrate <velasqueziturrate@gmail.com>

    git status -sb
    ## main...origin/main

**Incident 1: `Repository not found` on the first push**

- Symptom: `remote: Repository not found.` / `fatal: repository '.../serverless-incident-hub.git/' not found`.
- Root cause: the remote repository did not exist yet under the personal account when the push ran. GitHub
  answers 404 both for repositories that do not exist and for private ones when no credentials are sent,
  and the push used `-c credential.helper=` (no stored credentials), so the message cannot tell them apart.
- Fix: created the empty repository (no README, `.gitignore` or license) and pushed again.

**Incident 2: first commit signed with the work identity**

- Symptom: `git log -1` showed the work email as author and committer.
- Root cause: the commit was made before a repo-local identity ested, so git fell back to the global
  `~/.gitconfig`, which holds the work identity (confirmed with `git config --list --show-origin --show-scope`).
- Fix: set repo-local `user.name`, `user.email` and `credential.https://github.com.username`, rewrote the
  commit with `git commit --amend --reset-author --no-edit` before the first push (nothing was public yet),
  and checked that no file in the repository mentioned the employer.
- Lesson: on this machine, set the repo-local identity **before the first commit** of every new project.

#### 0.2 Confirm the AWS identity and permissions - 2026-09-20

Commands:

    aws configure list-profiles
    aws sts get-caller-identity
    aws iam get-user --user-name <iam-user> --query 'User.PermissionsBoundary'
    aws iam list-attached-user-policies --user-name <iam-user> --query 'AttachedPolicies[].PolicyName'
    aws iam list-groups-for-user --user-name <iam-user> --query 'Groups[].GroupName'

Result (account ID and user name masked):

- Single CLI profile (`default`), so there is no risk of pointing at another account by mistake.
- Identity is an IAM user (`arn:aws:iam::<account-id>:user/<iam-user>`), i.e. long-lived access keys.
- No permissions boundary (`null`), so `ROLE_PERMISSIONS_BOUNDARY` is not needed for now.
- No policies attached directly to the user; permissions come from the `Administrators` group.
- Being administrator in IAM does not override Organizations SCPs, which is why the preflight (0.4) is still needed.

#### 0.3 Dry-run the teardown script - 2026-09-20

Commands:

    export AWS_REGION=us-east-1
    ./scripts/teardown.sh list

Output (account ID masked):

    AWS account : <account-id>
    Region      : us-east-1
    Stack prefix: sih-   (delete order below)

    No stacks found. Nothing to delete.

Result: OK. First read-only run against the real account: the script authenticates, lists stacks
and finds no project stacks. `destroy` and `verify` have not been run against a real account yet.

#### 0.4 Preflight: which services does the account allow? - 2026-09-20

Commands:

    export AWS_REGION=us-east-1
    ./scripts/preflight.sh
    ./scripts/teardown.sh list
    grep -nE '[0-9]{12}' docs/PREFLIGHT.md

Output (account ID masked):

    Preflight in region us-east-1 (stack prefix sih-preflight-*)

      ...  s3               OK
      ...  dynamodb         OK
      ...  sqs              OK
      ...  sns              OK
      ...  eventbridge      OK
      ...  ssm              OK
      ...  logs             OK
      ...  iam-role         OK
      ...  lambda           OK
      ...  step-functions   OK
      ...  apigw-http       OK
      ...  cognito          OK

    Summary: 12 OK, 0 denied/failed. Written to docs/PREFLIGHT.md

    AWS account : <account-id>
    Region      : us-east-1
    Stack prefix: sih-   (delete order below)

    No stacks found. Nothing to delete.

The `grep` found no 12-digit numbers, so the generated report contains no account ID.

Result: all 12 probed services can be created and deleted in this account in `us-east-1`.

- No SCP or missing permission blocked any of them, and an IAM role could be created without a
  permissions boundary. In the previous project the ECR restriction (ADR 003) was only discovered
  when trying to use it; this check moves that discovery to before any design work.
- Every probe stack was also deleted successfully, so deletion is proven for these 12 resource
  types, and `teardown.sh list` confirms no stack was left behind.
- First run of the templates against a real account (before, only against a local emulator).
- Not probed yet, to be checked in the phase that needs them (ADR 002, rule 9): CloudFront,
  EventBridge Scheduler, IAM OIDC provider (GitHub Actions), AWS Budgets, CloudWatch alarms and
  dashboards, X-Ray, and the AI services (Translate, Comprehend, Bedrock).
- Scope: creation permissions in `us-east-1` only; service quotas and runtime behaviour are untested.

## 0.5 Confirm nothing is left behind - 2026-09-20

Commands:

    ./scripts/teardown.sh list
    ./scripts/teardown.sh verify
    aws cognito-idp list-user-pools --max-results 60 --query 'UserPools[].[Id,Name]' --output text
    aws cognito-idp describe-user-pool --user-pool-id <pool-id>
    ./scripts/whats-running.sh

**Incident 3: `verify` reported a Cognito user pool that did not exist (false positive)**

- Symptom (first `verify` after the preflight, account ID masked):

      [!!] Resources tagged Project=serverless-incident-hub
             arn:aws:cognito-idp:us-east-1:<account-id>:userpool/us-east-1_f5utCh8Gl

  Everything else was clean: no stacks, buckets, log groups or roles.
- Investigation: `describe-user-pool` on that ID returned `ResourceNotFoundException ... does not exist`, and
  `list-user-pools` did not list it (only pools that belong to other people). The API history also shows one
  `CreateUserPool` and one `DeleteUserPool` in the window.
- Root cause: `verify` treated the Resource Groups Tagging API as the source of truth. That index is eventually
  consistent: it still listed the pool at least 14 minutes after the deletion, and again in a later audit run.
- Fix: `verify` now asks the owning service about every tagged ARN and reports `alive`, `gone` (stale index
  entry, informational) or `unknown` (counted as a leftover). New mode `check-arn <arn>` for manual checks.
  Documented in the runbook (`docs/TEARDOWN.md`, failure table). The SQS branch could not be exercised
  against the emulator, so it is only proven on a real account when an SQS queue is involved.
- Lesson: never trust a single index; confirm with the service that owns the resource.

Verification after the fix (account ID masked):

    gone   arn:aws:cognito-idp:us-east-1:<account-id>:userpool/us-east-1_f5utCh8Gl

    AWS account : <account-id>
    Region      : us-east-1
    Looking for leftovers (things CloudFormation does not always remove)...
    
      [ok] CloudFormation stacks: none
      [ok] Resources tagged Project=serverless-incident-hub that still exist: none
      [ok] Tagged resources this script cannot check (confirm by hand: ./scripts/teardown.sh check-arn <arn>): none
      [ok] Stale entries in the tag index (already deleted; the tagging API lags behind):
             arn:aws:cognito-idp:us-east-1:<account-id>:userpool/us-east-1_f5utCh8Gl
      [ok] S3 buckets named sih-*: none
      [ok] CloudWatch log groups /aws/lambda/sih-*: none
      [ok] CloudWatch log groups /sih/*: none
      [ok] CloudWatch log groups /aws/vendedlogs/sih*: none
      [ok] IAM roles named sih-*: none
    
    Not covered by this script (check by hand, see docs/TEARDOWN.md): KMS keys or Secrets Manager
    secrets in 'pending deletion', CloudFront distributions in other accounts/regions, and cost data
    (Cost Explorer lags by up to ~24h, so look again tomorrow).
    
    Clean: no project resources found.

**Whole-account audit: new script `scripts/whats-running.sh`**

Written because "is anything of mine still running, in any region?" needs a wider answer than the
project-only `teardown.sh verify`. It is read-only and checks stacks, tagged resources (each confirmed
with its own service), EC2 instances that use the project key pair, and the balance of Create vs Delete
API calls found in CloudTrail. First run against the real account (account ID and user name masked):

    Identity : arn:aws:iam::<account-id>:user/<iam-user>
    Window   : last 3 day(s), since 2026-09-17T20:15:33Z
    Regions  : 17 enabled regions scanned
    Read-only: nothing is created, changed or deleted
    
    == us-east-1
       [stale tag] deleted already, the tag index lags: arn:aws:cognito-idp:us-east-1:<account-id>:userpool/us-east-1_f5utCh8Gl
    == API activity by <iam-user> (created vs deleted, heuristic)
       [free] us-east-1: CreateKeyPair x1 vs DeleteKeyPair x0 (this kind of resource costs nothing)
       [free] us-east-1: CreateServiceLinkedRole x1 vs DeleteServiceLinkedRole x0 (this kind of resource costs nothing)
    
    RESULT: nothing to review. No project stacks, no live tagged resources, no project EC2, and
            every billable Create in the last 3 day(s) has a matching Delete.

Result: exit code 0. Every billable create in the window has a matching delete. The only creates without
a delete are a key pair and a service-linked role, both free (marked `[free]`).

Lesson: a second-hand summary of the CloudTrail history (from a chat assistant) claimed that no resources
had been created at all, which contradicted the 12 probe stacks created that same day. Reading CloudTrail
directly showed the real picture. Verify against the primary source, not against someone's summary.

#### 0.6 Accept ADR 001 and ADR 002 - 2026-09-20

Decision: ADR 001 (CloudFormation as the IaC tool) and ADR 002 (layered stacks, naming, teardown order)
move from *Proposed* to *Accepted*.

Evidence:

- Preflight: 12 of 12 services created and deleted in the real account (step 0.4).
- Teardown tooling: `list`, `verify` and `whats-running.sh` ran against the real account and found nothing left behind (steps 0.3 and 0.5).
- Conventions: the `sih-preflight-*` probe stacks were found and removed by prefix.

Known gaps carried into Phase 1 (also recorded in each ADR's follow-up):

- `destroy` has only been exercised by the emulator, not yet on real project stacks.
- Not probed yet: CloudFront, EventBridge Scheduler, IAM OIDC provider, AWS Budgets, CloudWatch alarms and dashboards, X-Ray, AI services.

Phase 0 is closed. `docs/RESUME.md` was added as the single cold-start guide. Next: Phase 1 (foundation).
