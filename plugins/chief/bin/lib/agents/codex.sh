#!/usr/bin/env bash
# codex.sh - OpenAI Codex CLI agent adapter (contract in agent.sh).
# Folder trust is not handled: a trust prompt, if codex shows one, stalls the
# spawn as "not ready".

agent_name() { echo codex; }
# verified: --help
agent_command() { echo "codex --dangerously-bypass-approvals-and-sandbox${CHIEF_AGENT_MODEL:+ --model $CHIEF_AGENT_MODEL}${CHIEF_AGENT_ARGS:+ $CHIEF_AGENT_ARGS}"; }
agent_prepare() { :; }
agent_release() { :; }
# verified: codex-cli 0.164.0 status line ("← for agents"); 'context left' is the older one
agent_ready_text() { echo 'for agents|context left'; }
# verified: string in the codex binary
agent_paste_text() { echo '\[Pasted Content'; }
# assumed: not confirmed against a running codex
agent_trust_text() { echo 'trust the contents of this directory'; }
agent_trust_keys() { :; }
# assumed: the glyph is in the binary, its use as the input prompt is not confirmed
agent_input_marker() { echo '›'; }
