# Setup log

Chronological record of how this project was built: what was run, what happened, what failed and how
it was fixed. Entries are added **after** each step is executed for real (command, real output, result),
never before. Decisions that come out of a step become ADRs in `docs/decisions/`.

Conventions: region `us-east-1`; stacks named `sih-<NN>-<name>`; docs in English.

---

## Phase 0 - Guardrails (teardown first)

Goal: before creating a single real resource, know how to remove everything, and know which services
the account allows.

Status: **in progress (0.1 done).**

### Steps

- [x] 0.1 Create the GitHub repository `serverless-incident-hub` under the personal account and push this scaffold.
- [ ] 0.2 Confirm the AWS identity and account: `aws sts get-caller-identity` (do not commit the account ID).
- [ ] 0.3 Dry-run the teardown script: `./scripts/teardown.sh list` (expected: "No stacks found").
- [ ] 0.4 Run the preflight: `./scripts/preflight.sh`, then review and commit `docs/PREFLIGHT.md`.
- [ ] 0.5 Confirm nothing is left behind: `./scripts/teardown.sh list` and `./scripts/teardown.sh verify`.
- [ ] 0.6 Mark ADR 001 and ADR 002 as *Accepted* (or adjust them) based on the preflight results.

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
