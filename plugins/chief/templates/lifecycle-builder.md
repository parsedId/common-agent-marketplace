# Lifecycle checklist: {TASK_ID} (builder)

- [ ] filed (chief-backlog.sh add)
- [ ] spawned (chief-spawn.sh)
- [ ] watching until a terminal state (done/failed/blocked/needs-decision); a builder's done line starts with its short commit SHA
- [ ] reported to operator with the diffstat and a one-line review recommendation, and held (chief-backlog.sh hold <id> "reported: awaiting review decision")
- [ ] operator asked whether to review, every time (never automatic). Yes -> chief-review.sh <id>; no -> landing. A standing "review everything this session" skips the question until revoked
- [ ] reviewer's verdict presented and the reviewer held; next step proposed: FAIL -> send the findings to the builder (operator may edit them), PASS -> land or keep going. After the builder's next done, ask again
- [ ] landing path chosen - PR opened (chief-pr-open.sh)
- [ ] PR approved (chief-pr-approve.sh)
- [ ] merged (chief-pr-merge.sh)
- [ ] torn down (chief-teardown.sh); this also discards its reviewers, so the go-ahead names them all

## Conditional (mark N/A if it never applied)
- [ ] review findings posted to the PR, only when the operator asked (chief-pr-review.sh)
- [ ] steered mid-task (chief-send.sh)
- [ ] escalated (chief-control.sh interrupt/relaunch)
- [ ] held for an operator decision (blocked/needs-decision, chief-backlog.sh hold, moved back to in-flight once unblocked)
