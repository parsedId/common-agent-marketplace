#!/usr/bin/env bash
# test-review.sh - chief-review.sh (rounds, gates, links), the reviewer brief
# and lifecycle, the teardown cascade and the link in crew-state/watch,
# against the mock backend.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
BIN="$REPO_ROOT/plugins/chief/bin"
TEMPLATES="$REPO_ROOT/plugins/chief/templates"
. "$TEST_DIR/lib/harness.sh"

echo "test-review:"

WORK=$(mktemp -d)
harness_trap 'rm -rf "$WORK"'
mkdir -p "$WORK/project" && cd "$WORK/project" && git init -q -b main
git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
export CHIEF_HOME="$WORK/.chief"
export CHIEF_BACKEND=mock
. "$BIN/lib/paths.sh"
. "$BIN/lib/meta.sh"
RV="$BIN/task/chief-review.sh"
CS="$BIN/task/chief-crew-state.sh"

commit() {  # <id> <file>: commit a file in the builder's worktree, print the sha
  ( cd "$CHIEF_HOME/worktrees/$1" && echo "$2" > "$2" && git add "$2" \
    && git -c user.email=t@t -c user.name=t commit -q -m "add $2" && git rev-parse HEAD )
}

"$BIN/chief-backlog.sh" add b-1 "Add hello" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" b-1 "$WORK/project" --mode builder --branch feat/b-1 --intent "Add hello" >/dev/null

# --- gates ---
assert_failure "gate: unknown task" -- "$RV" nope
assert_contains "$("$RV" b-1 2>&1)" "is not done" "gate: the builder must be done"
echo "done: x" >> "$TASKS/b-1/status"
assert_contains "$("$RV" b-1 2>&1)" "no commit ahead of main" "gate: needs a commit ahead of base"
SHA1=$(commit b-1 hello.txt)
assert_contains "$("$RV" b-1 2>&1)" "does not start with HEAD's SHA" "gate: a done line with no SHA is refused"
echo "done: ${SHA1:0:7} added hello.txt" >> "$TASKS/b-1/status"
SHAX=$(commit b-1 late.txt)
assert_contains "$("$RV" b-1 2>&1)" "does not start with HEAD's SHA ${SHAX:0:7}" "gate: a commit after the done line is refused"
git -C "$CHIEF_HOME/worktrees/b-1" reset -q --hard "$SHA1"
echo dirt > "$CHIEF_HOME/worktrees/b-1/dirt.txt"
assert_contains "$("$RV" b-1 2>&1)" "not clean" "gate: the worktree must be clean"
rm "$CHIEF_HOME/worktrees/b-1/dirt.txt"
assert_file_missing "$TASKS/b-1-rv/meta" "gates: nothing was spawned"

# --- round 1 ---
out=$(timeout 15 "$RV" b-1 2>&1)
assert_contains "$out" "review: b-1-rv round 1 of b-1 @${SHA1:0:7}" "round 1: prints the round"
assert_eq "$(chief_meta_get b-1-rv mode)" "reviewer" "round 1: spawns a reviewer"
assert_eq "$(chief_meta_get b-1-rv branch)" "chore/b-1-rv" "round 1: on chore/<reviewer-id>"
assert_eq "$(chief_meta_get b-1-rv for)" "b-1" "round 1: reviewer for=builder"
assert_eq "$(chief_meta_get b-1 reviewer)" "b-1-rv" "round 1: builder reviewer=reviewer"
assert_eq "$(chief_meta_get b-1 review_round)" "1" "round 1: builder review_round=1"
assert_contains "$("$BIN/chief-backlog.sh" show b-1-rv)" "[in-flight] review of b-1: Add hello" "round 1: backlog item filed and in flight"
BRIEF=$(cat "$TASKS/b-1-rv/brief.md")
assert_contains "$BRIEF" "Pinned SHA: $SHA1" "round 1: spec pins the SHA"
assert_contains "$BRIEF" "Base: main" "round 1: spec names the base"
assert_contains "$BRIEF" "Branch: feat/b-1" "round 1: spec names the branch"
assert_contains "$BRIEF" "$TASKS/b-1/brief.md" "round 1: spec points at the builder's brief"
assert_contains "$BRIEF" "Builder done line: ${SHA1:0:7} added hello.txt" "round 1: spec carries the done line"
assert_contains "$BRIEF" "Review round 1" "round 1: spec carries the round"
assert_contains "$("$CS" b-1-rv)" "[for: b-1]" "crew-state: the reviewer shows its builder"
assert_contains "$("$CS" b-1)" "[reviewer: b-1-rv]" "crew-state: the builder shows its reviewer"

digest=$(python3 -c "import json,sys; print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])" < <("$REPO_ROOT/plugins/chief/hooks/session-start.sh"))
assert_contains "$digest" "[mode: reviewer] [agent: claude] [for: b-1]" "digest: the reviewer shows its builder"

# --- same SHA while the reviewer works ---
assert_contains "$("$RV" b-1 2>&1)" "already reviewing ${SHA1:0:7}" "same SHA while the reviewer is working: refused"

# --- reviewer reports; the watcher wakes on it ---
mkdir -p "$TASKS/b-1-rv"
printf 'Verdict: FAIL\n' > "$TASKS/b-1-rv/report.md"
echo "done: round 1 FAIL (1 blocking) @${SHA1:0:7}" >> "$TASKS/b-1-rv/status"
"$BIN/chief-backlog.sh" hold b-1-rv "round 1 FAIL, idle" >/dev/null
"$BIN/chief-backlog.sh" hold b-1 "reported" >/dev/null

# --- round 2 ---
SHA2=$(commit b-1 more.txt)
echo "working: resuming" >> "$TASKS/b-1/status"
assert_contains "$("$RV" b-1 2>&1)" "is not done" "gate: a builder resumed to working is not reviewable"
"$BIN/chief-backlog.sh" status b-1 in-flight >/dev/null
echo "done: ${SHA2:0:7} fixed" >> "$TASKS/b-1/status"
out=$(timeout 15 "$RV" b-1 2>&1)
assert_contains "$out" "review: b-1-rv round 2 of b-1 @${SHA2:0:7}" "round 2: prints the round"
assert_eq "$(cat "$TASKS/b-1-rv/report.round-1.md")" "Verdict: FAIL" "round 2: the previous report is archived"
assert_file_missing "$TASKS/b-1-rv/report.md" "round 2: report.md is cleared for the new round"
MSG=$(cat "$TASKS/b-1-rv/inbox/001.msg")
assert_contains "$MSG" "Review round 2" "round 2: the round message is delivered"
assert_contains "$MSG" "Pinned SHA: $SHA2" "round 2: the message pins the new SHA"
assert_contains "$MSG" "$TASKS/b-1-rv/report.round-1.md" "round 2: the message lists the prior report"
assert_eq "$(tail -n 1 "$TASKS/b-1-rv/status")" "working: round 2 requested" "round 2: a working line follows the old done"
assert_contains "$("$CS" b-1-rv)" "state: working" "round 2: the reviewer reads as working"
assert_contains "$("$BIN/chief-backlog.sh" show b-1-rv)" "[in-flight]" "round 2: backlog item back in flight"
assert_eq "$(chief_meta_get b-1-rv status)" "working" "round 2: meta back to working"
assert_eq "$(chief_meta_get b-1 review_round)" "2" "round 2: builder review_round=2"
assert_contains "$("$RV" b-1 2>&1)" "already reviewing ${SHA2:0:7}" "round 2: a repeat call for the same SHA is refused"
assert_eq "$(ls "$TASKS/b-1-rv/inbox" | grep -c msg)" "1" "round 2: the refused call sent nothing"

# --- watch: a differing reviewer done wakes; one identical to the baseline is suppressed ---
kill "$(cat "$TASKS/b-1-rv/term.pid")" 2>/dev/null; sleep 1
"$BIN/chief-backlog.sh" hold b-1 "reported" >/dev/null
watch_out() { CHIEF_POLL=1 timeout 3 "$BIN/chief-watch.sh"; }
silent=$(watch_out); rc=$?
assert_eq "$rc:$silent" "124:" "watch: the re-armed reviewer's working line does not wake Chief"
echo "done: round 2 PASS @${SHA2:0:7}" >> "$TASKS/b-1-rv/status"
assert_contains "$(watch_out)" "b-1-rv: state: done · round 2 PASS @${SHA2:0:7}" "watch: the reviewer's new done wakes Chief"
"$BIN/chief-backlog.sh" hold b-1-rv "round 2 PASS, idle" >/dev/null
"$BIN/chief-backlog.sh" status b-1-rv in-flight >/dev/null
silent=$(watch_out); rc=$?
assert_eq "$rc:$silent" "124:" "watch: a done identical to the baseline is suppressed"
"$BIN/chief-backlog.sh" hold b-1-rv "idle" >/dev/null

# --- teardown: the cascade ---
assert_failure "teardown: an unlanded builder is refused" -- "$BIN/chief-teardown.sh" b-1
assert_file_exists "$CHIEF_HOME/worktrees/b-1-rv" "teardown refused: the reviewer is left alone"
git -C "$WORK/project" merge --ff-only feat/b-1 >/dev/null
out=$("$BIN/chief-teardown.sh" b-1 2>&1)
assert_contains "$out" "torn down: b-1 " "teardown: the landed builder is discarded"
assert_contains "$out" "torn down: b-1-rv " "teardown: its reviewer is discarded with it"
assert_file_missing "$CHIEF_HOME/worktrees/b-1-rv" "teardown: the reviewer worktree is gone"
assert_file_exists "$ARCHIVE/b-1-rv/report.round-1.md" "teardown: the reviewer's reports survive, archived"
assert_contains "$("$BIN/chief-backlog.sh" show b-1-rv)" "[done]" "teardown: the reviewer's backlog item is done"
assert_failure "review after teardown: refused" -- "$RV" b-1

# --- a reviewer torn down alone; --abandon cascades too ---
"$BIN/chief-backlog.sh" add b-2 "Add two" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" b-2 "$WORK/project" --mode builder --branch feat/b-2 --intent "Add two" >/dev/null
commit b-2 two.txt >/dev/null
echo "done: $(git -C "$CHIEF_HOME/worktrees/b-2" rev-parse --short HEAD) ok" >> "$TASKS/b-2/status"
timeout 15 "$RV" b-2 >/dev/null 2>&1
out=$("$BIN/chief-teardown.sh" b-2-rv 2>&1)
assert_contains "$out" "torn down: b-2-rv " "teardown: a reviewer tears down alone"
assert_eq "$(git -C "$WORK/project" worktree list | grep -c 'worktrees/b-2 ')" "1" "teardown alone: the builder is untouched"
assert_contains "$("$RV" b-2 2>&1)" "reviewer b-2-rv was torn down" "review: a torn-down reviewer is reported"
out=$("$BIN/chief-teardown.sh" b-2 --abandon 2>&1)
assert_eq "$(grep -c '^torn down' <<< "$out")" "1" "abandon: an already-discarded reviewer is not torn down twice"

# --- a reviewer whose worktree was removed by hand is still discarded with its builder ---
"$BIN/chief-backlog.sh" add b-3 "Add three" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" b-3 "$WORK/project" --mode builder --branch feat/b-3 --intent "Add three" >/dev/null
commit b-3 three.txt >/dev/null
echo "done: $(git -C "$CHIEF_HOME/worktrees/b-3" rev-parse --short HEAD) ok" >> "$TASKS/b-3/status"
timeout 15 "$RV" b-3 >/dev/null 2>&1
git -C "$WORK/project" worktree remove --force "$CHIEF_HOME/worktrees/b-3-rv"
out=$("$BIN/chief-teardown.sh" b-3 --abandon 2>&1)
assert_contains "$out" "torn down: b-3-rv " "teardown: a hand-removed reviewer worktree is still cleaned up"
assert_eq "$(chief_meta_get b-3-rv status)" "torn-down" "teardown: the reviewer is marked torn down"
assert_contains "$("$BIN/chief-backlog.sh" show b-3-rv)" "[done]" "teardown: its backlog item is done"
assert_eq "$(git -C "$WORK/project" branch --list chore/b-3-rv)" "" "teardown: its branch is deleted"

# --- a long builder id: the reviewer id is fitted, found again in round 2, and reused after a failed spawn ---
LB=build-keycloak-name-extra-words
"$BIN/chief-backlog.sh" add $LB "Long" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" $LB "$WORK/project" --mode builder --branch feat/long --intent "Long" >/dev/null
commit $LB long.txt >/dev/null
echo "done: $(git -C "$CHIEF_HOME/worktrees/$LB" rev-parse --short HEAD) ok" >> "$TASKS/$LB/status"
assert_failure "long id: a failed round-1 spawn" -- env CHIEF_MOCK_SPAWN_FAIL=1 "$RV" $LB
assert_file_missing "$TASKS/build-keycloak-name-extra-rv/meta" "long id: a failed spawn leaves no meta"
timeout 15 "$RV" $LB >/dev/null 2>&1
assert_eq "$(chief_meta_get $LB reviewer)" "build-keycloak-name-extra-rv" "long id: the retry reuses the fitted reviewer id"
commit $LB long2.txt >/dev/null
echo "done: $(git -C "$CHIEF_HOME/worktrees/$LB" rev-parse --short HEAD) ok" >> "$TASKS/$LB/status"
assert_contains "$("$RV" $LB 2>&1)" "review: build-keycloak-name-extra-rv round 2 of $LB" "long id: round 2 reads reviewer= from meta"

# --- strategy all: one reviewer per [reviewer] entry ---
mkdir -p "$CHIEF_HOME/config"
printf '[reviewer]\nstrategy = all\nclaude:sonnet\ncodex\nclaude:sonnet\n' > "$CHIEF_HOME/config/agents"
"$BIN/chief-backlog.sh" add b-4 "Add four" >/dev/null
timeout 10 "$BIN/chief-spawn.sh" b-4 "$WORK/project" --mode builder --branch feat/b-4 --intent "Add four" >/dev/null
commit b-4 four.txt >/dev/null
echo "done: $(git -C "$CHIEF_HOME/worktrees/b-4" rev-parse --short HEAD) ok" >> "$TASKS/b-4/status"
out=$(timeout 30 "$RV" b-4 2>&1)
assert_contains "$out" "review: b-4-rv-claude-sonnet, b-4-rv-codex, b-4-rv-claude-sonnet-2 round 1 of b-4" "all: one reviewer per entry, ids distinct"
assert_eq "$(chief_meta_get b-4 reviewer)" "b-4-rv-claude-sonnet b-4-rv-codex b-4-rv-claude-sonnet-2" "all: the builder links every reviewer"
assert_eq "$(chief_meta_get b-4-rv-codex agent)" "codex" "all: each reviewer runs its own entry"
assert_eq "$(chief_meta_get b-4-rv-codex for)" "b-4" "all: each reviewer is for the builder"
assert_eq "$(chief_meta_get b-4-rv-codex branch)" "chore/b-4-rv-codex" "all: distinct branches"
assert_contains "$("$CS" b-4)" "[reviewer: b-4-rv-claude-sonnet b-4-rv-codex b-4-rv-claude-sonnet-2]" "all: crew-state lists the reviewers"
assert_contains "$("$RV" b-4 2>&1)" "already reviewing" "all: a working reviewer refuses the same SHA"
for r in $(chief_meta_get b-4 reviewer); do
  printf 'Verdict: PASS\n' > "$TASKS/$r/report.md"
  echo "done: round 1 PASS @x" >> "$TASKS/$r/status"
done
SHA4=$(commit b-4 four-b.txt)
echo "done: ${SHA4:0:7} fixed" >> "$TASKS/b-4/status"
out=$(timeout 30 "$RV" b-4 2>&1)
assert_contains "$out" "round 2 of b-4" "all: round 2 re-arms them all"
for r in $(chief_meta_get b-4 reviewer); do
  assert_file_exists "$TASKS/$r/report.round-1.md" "all: $r report archived"
  assert_contains "$(cat "$TASKS/$r/inbox/001.msg")" "Pinned SHA: $SHA4" "all: $r got the round message"
done
out=$("$BIN/chief-teardown.sh" b-4 --abandon 2>&1)
assert_eq "$(grep -c '^torn down' <<< "$out")" "4" "all: teardown discards the builder and every reviewer"
rm "$CHIEF_HOME/config/agents"

# --- manual use on an arbitrary branch ---
git -C "$WORK/project" branch feat/other main
assert_success "manual: chief-spawn --mode reviewer --spec" -- \
  timeout 10 "$BIN/chief-spawn.sh" rv-1 "$WORK/project" --mode reviewer --branch chore/rv-1 --intent "Review feat/other" --spec "Branch: feat/other"
assert_contains "$(cat "$TASKS/rv-1/brief.md")" "Branch: feat/other" "manual: the spec reaches the brief"
assert_contains "$("$CS" rv-1)" "[mode: reviewer]" "manual: crew-state reports the reviewer role"
assert_not_contains "$("$CS" rv-1)" "[for:" "manual: no builder link"

# --- brief and lifecycle content ---
RB=$(cat "$TEMPLATES/brief-reviewer.md")
for item in "Matches intent" "Code and comment quality" "Checks run clean" "No debris" "Scope discipline" "Project docs addressed" "Doc quality" "Commit conventions"; do
  assert_contains "$RB" "**$item.**" "reviewer brief: checklist item $item"
done
assert_contains "$RB" "Run the project's own check command" "reviewer brief: item 3 runs the project's checks"
assert_contains "$RB" "git reset --hard && git clean -fd" "reviewer brief: resets the scratch worktree"
assert_contains "$RB" "git switch --detach <sha>" "reviewer brief: detaches at the pinned SHA"
assert_contains "$RB" "full diff \`git diff <base>...<sha>\`" "reviewer brief: reviews the full diff every round"
assert_contains "$RB" "never conclusions to repeat or a PASS to carry forward" "reviewer brief: prior findings are a to-verify list"
assert_contains "$RB" "Verdict: PASS | FAIL" "reviewer brief: report format"
assert_contains "$RB" "Prior findings:" "reviewer brief: report has the prior-findings line"
assert_contains "$RB" "done: round N PASS @<sha7>" "reviewer brief: PASS status line"
assert_contains "$RB" "done: round N FAIL (<n> blocking) @<sha7>" "reviewer brief: FAIL status line"
assert_contains "$RB" "working: round N" "reviewer brief: working status line"
assert_contains "$RB" "A FAIL verdict is still \`done\`" "reviewer brief: FAIL is done, failed means incomplete"
assert_contains "$RB" "never push, post, comment, merge or edit project files" "reviewer brief: read-only toward everything else"
assert_contains "$RB" "AI-attribution trailer is a FAIL" "reviewer brief: attribution is a FAIL"
assert_contains "$RB" "Check the skills available to you" "reviewer brief: checks available skills"
assert_contains "$RB" "is a standard to judge the diff and its commits against" "reviewer brief: a skill is a standard to judge against"
assert_contains "$RB" "never carry out its steps" "reviewer brief: never runs a skill's procedure"
assert_contains "$RB" "A skill the diff adds or changes is under review, not a standard" "reviewer brief: the reviewed branch can't supply its own standard"
assert_not_contains "$(tr A-Z a-z <<< "$RB")" "superpowers" "reviewer brief: no dependency on a named skill pack"
assert_not_contains "$RB" "conventional-" "reviewer brief: names no skill"
assert_not_contains "$(sed 's/CLAUDE\.md//g' <<< "$RB" | tr A-Z a-z)" "claude" "reviewer brief: agent-neutral wording"
for ph in TASK SPEC BRANCH REPORT_FILE STATUS_FILE TURN_FILE INBOX_DIR; do
  assert_not_contains "$(cat "$TASKS/rv-1/brief.md")" "{$ph}" "reviewer brief: no unfilled {$ph}"
done
assert_contains "$(cat "$TASKS/rv-1/lifecycle")" "(reviewer)" "reviewer lifecycle: rendered for the reviewer"
assert_not_contains "$(cat "$TASKS/rv-1/lifecycle")" "{TASK_ID}" "reviewer lifecycle: no unfilled placeholder"

# builder lifecycle and the dispatch skill carry the loop
BL=$(cat "$TEMPLATES/lifecycle-builder.md")
assert_contains "$BL" "chief-review.sh <id>" "builder lifecycle: names the review helper"
assert_contains "$BL" "every time (never automatic)" "builder lifecycle: the review question is always asked"
assert_contains "$BL" "review everything this session" "builder lifecycle: the standing preference"
assert_contains "$BL" "also discards its reviewers" "builder lifecycle: the teardown cascade"
DS=$(cat "$REPO_ROOT/plugins/chief/skills/dispatch/SKILL.md")
assert_contains "$DS" "## The review loop" "dispatch: has the review loop"
assert_contains "$DS" "chief-review.sh <builder-id>" "dispatch: runs the helper"
assert_contains "$DS" "There is no round cap" "dispatch: no round cap"
assert_file_missing "$REPO_ROOT/plugins/chief/skills/reviewer" "the reviewer skill is gone"

harness_summary
