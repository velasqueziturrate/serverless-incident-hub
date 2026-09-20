# Setup log

Chronological record of how this project was built: what was run, what happened, what failed and how
it was fixed. Entries are added **after** each step is executed for real (command, real output, result),
never before. Decisions that come out of a step become ADRs in `docs/decisions/`.

Conventions: region `us-east-1`; stacks named `sih-<NN>-<name>`; docs in English.

---

## Phase 0 - Guardrails (teardown first)

Goal: before creating a single real resource, know how to remove everything, and know which services
the account allows.

Status: **scaffold delivered, not yet executed.**

### Steps

- [ ] 0.1 Create the GitHub repository `serverless-incident-hub` under the personal account and push this scaffold.
- [ ] 0.2 Confirm the AWS identity and account: `aws sts get-caller-identity` (do not commit the account ID).
- [ ] 0.3 Dry-run the teardown script: `./scripts/teardown.sh list` (expected: "No stacks found").
- [ ] 0.4 Run the preflight: `./scripts/preflight.sh`, then review and commit `docs/PREFLIGHT.md`.
- [ ] 0.5 Confirm nothing is left behind: `./scripts/teardown.sh list` and `./scripts/teardown.sh verify`.
- [ ] 0.6 Mark ADR 001 and ADR 002 as *Accepted* (or adjust them) based on the preflight results.

### Log

_No entries yet. Each executed step is recorded here in this format:_

```
#### 0.X <step title> - <date>
Command:   ...
Output:    ... (real, trimmed)
Result:    OK | problem found
Fix/notes: ...
```
