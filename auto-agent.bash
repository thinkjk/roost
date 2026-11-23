# roost auto-agent: sourced from /etc/bash.bashrc. Starts AUTO_AGENT (the
# entrypoint writes it to /run/roost/auto-agent; empty = off) in a herdr
# terminal that is in a git repo under ~/projects, at most once per shell. It
# runs from PROMPT_COMMAND so ~/.bashrc has loaded first, and leaves a normal
# shell behind when the agent exits.
#
# - A new terminal that opens in a repo counts down 3s first; press any key
#   for a plain shell (e.g. to cd elsewhere: new herdr spaces open in the
#   folder of the current one).
# - cd into another repo starts it there right away.
# - A terminal that herdr-core brings back after a restart (same terminal id,
#   same folder, agent still running when the box went down) continues its
#   last conversation at once: Claude gets --continue added to the command.
#
# Skip one repo: touch .no-auto-agent at its top level.

__roost_auto_agent() {
  [[ -n ${__roost_auto_agent_done:-} ]] && return
  local first=${__roost_auto_agent_seen:-1}
  __roost_auto_agent_seen=0

  local cmd top dir marker resume=
  cmd=$(cat /run/roost/auto-agent 2>/dev/null) && [[ -n $cmd ]] || { __roost_auto_agent_done=1; return; }
  case "$PWD/" in "$HOME"/projects/?*/) ;; *) __roost_auto_agent_skip=; return ;; esac
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { __roost_auto_agent_skip=; return; }
  # Declined (or skipped) this repo already: wait until we leave it.
  [[ $top == "${__roost_auto_agent_skip:-}" ]] && return
  [[ -e $top/.no-auto-agent ]] && { __roost_auto_agent_skip=$top; return; }

  dir="$HOME/.local/state/roost/auto-agent"
  marker="$dir/$HC_TERMINAL_ID"
  # Claude keeps conversations in ~/.claude/projects/<cwd, non-alnum as ->.
  if [[ $first == 1 && $cmd == claude* && $(cat "$marker" 2>/dev/null) == "$PWD" ]] \
     && compgen -G "$HOME/.claude/projects/${PWD//[^a-zA-Z0-9]/-}/*.jsonl" >/dev/null; then
    cmd="$cmd --continue"; resume=1
  fi

  if [[ $first == 1 && -z $resume ]]; then
    printf 'roost: starting %s in 3s; press any key for a plain shell ' "${cmd%% *}"
    if read -rsn1 -t 3; then
      echo; echo "roost: plain shell (cd into another repo to start it there)"
      __roost_auto_agent_skip=$top
      return
    fi
    echo
  fi

  __roost_auto_agent_done=1
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
