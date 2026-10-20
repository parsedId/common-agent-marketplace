# Lifecycle checklist: {TASK_ID} (reviewer)

Started by chief-review.sh for a builder's commit, or by hand for any branch. Never automatic.

- [ ] filed and spawned (chief-review.sh <builder>; by hand: chief-backlog.sh add, chief-spawn.sh --mode reviewer --spec)
- [ ] watching until done (a verdict, PASS or FAIL) or failed (review incomplete)
- [ ] verdict presented to the operator, reviewer held (chief-backlog.sh hold <id> "round N <verdict>, idle")
- [ ] next step proposed, operator's call: FAIL -> send findings to the builder (chief-send.sh, builder back to in-flight); PASS -> land or keep going
- [ ] next round after the builder's next done, if the operator wants one (chief-review.sh <builder>)
- [ ] torn down with its builder (chief-teardown.sh <builder>), or alone (chief-teardown.sh <id>)

## Conditional (mark N/A if it never applied)
- [ ] findings posted to the PR, only when the operator asked (host CLI)
- [ ] escalated (chief-control.sh interrupt/relaunch)
