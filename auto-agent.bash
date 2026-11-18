# roost auto-agent: sourced from /etc/bash.bashrc. When a herdr terminal opens
# in a git repo under ~/projects, start AUTO_AGENT there once (the entrypoint
# writes it to /run/roost/auto-agent; empty = off). It runs from
# PROMPT_COMMAND so ~/.bashrc has loaded first, and leaves a normal shell
# behind when the agent exits.
#
# A terminal that herdr-core brings back after a restart (same terminal id,
# same folder, agent still running when the box went down) continues its
# last conversation: Claude gets --continue added to the same command.
#
# Skip one repo: touch .no-auto-agent at its top level.

__roost_auto_agent() {
  [[ -n ${__roost_auto_agent_done:-} ]] && return
  __roost_auto_agent_done=1

  local cmd top dir marker
  cmd=$(cat /run/roost/auto-agent 2>/dev/null) && [[ -n $cmd ]] || return
  case "$PWD/" in "$HOME"/projects/?*/) ;; *) return ;; esac
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return
  [[ -e $top/.no-auto-agent ]] && return

  dir="$HOME/.local/state/roost/auto-agent"
  marker="$dir/$HC_TERMINAL_ID"
  # Claude keeps conversations in ~/.claude/projects/<cwd, non-alnum as ->.
  if [[ $cmd == claude* && $(cat "$marker" 2>/dev/null) == "$PWD" ]] \
     && compgen -G "$HOME/.claude/projects/${PWD//[^a-zA-Z0-9]/-}/*.jsonl" >/dev/null; then
    cmd="$cmd --continue"
  fi
  mkdir -p "$dir" && printf '%s\n' "$PWD" > "$marker"

  echo "roost: $cmd   (AUTO_AGENT; touch .no-auto-agent to skip this repo)"
  history -s "$cmd"
  eval "$cmd"
  # Exited on purpose: a later restart starts it fresh, not --continue.
  rm -f "$marker"
}

# Only the first interactive shell of a herdr terminal; nested shells inherit
# the export and stay plain.
if [[ $- == *i* && -n ${HC_TERMINAL_ID:-} && -z ${ROOST_AUTO_AGENT:-} ]]; then
  export ROOST_AUTO_AGENT=1
  # After mise's hook, so a repo's mise.toml tools and env are active.
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__roost_auto_agent"
fi
