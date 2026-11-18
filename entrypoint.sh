#!/usr/bin/env bash
# Runs as root. Remaps the agent uid/gid to PUID/PGID to match the host volume,
# seeds the persistent home, bootstraps tools, starts sshd, then idles as the
# agent user.
# Idempotent: safe to run on every container start.
set -uo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
HARNESSES="${HARNESSES:-claude codex opencode}"
TOOLS="${TOOLS:-herdr uv gh glab npm:ccusage npm:playwright npm:@playwright/mcp}"
CURSOR="${CURSOR:-0}"
# The box is the security boundary, so Claude's per-folder trust dialog is
# pre-accepted for ~/projects/*. Set TRUST_PROJECTS=0 to keep the dialog.
TRUST_PROJECTS="${TRUST_PROJECTS:-1}"
GH_TOKEN="${GH_TOKEN:-}"
# AUTO_UPDATE=1: `mise up` every installed tool (Claude Code, Codex, herdr,
# ...) on each start and then daily, and leave updates to mise alone (Claude
# Code's own auto-updater is switched off). By hand, any time: `mise up`.
AUTO_UPDATE="${AUTO_UPDATE:-0}"
# Heeler QR pairing (roost-pair). Off by default: it lets ~/.ssh/authorized_keys
# grant logins, which every agent in the box can write.
HEELER_PAIRING="${HEELER_PAIRING:-0}"
# Agent started in every herdr terminal that opens in a git repo under
# ~/projects (see /etc/roost/auto-agent.bash). Unset: Claude without
# permission prompts, if Claude is installed. Set but empty: off.
if [ -z "${AUTO_AGENT+x}" ]; then
  case " $HARNESSES " in *" claude "*) AUTO_AGENT="claude --dangerously-skip-permissions";; *) AUTO_AGENT="";; esac
fi

AGENT_USER=agent
AGENT_HOME=/home/agent
# Absolute paths for everything root runs: root never searches a PATH that
# the agent can write to (a planted ~/.local/bin/gosu would otherwise run as
# root on the next start).
GOSU=/usr/sbin/gosu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---------------------------------------------------------------------------
# 1. Remap uid/gid and (re)own the home volume. Edits /etc/passwd directly:
#    usermod -u would walk the whole home on every new container, and a
#    grown home (tools, repos) makes that minutes. chown -R runs only when
#    the home's owner is off, e.g. a fresh, root-created directory.
# ---------------------------------------------------------------------------
if [ "$(id -g "$AGENT_USER")" != "$PGID" ]; then
  groupmod -o -g "$PGID" "$AGENT_USER"
fi
if [ "$(id -u "$AGENT_USER")" != "$PUID" ] || [ "$(id -g "$AGENT_USER")" != "$PGID" ]; then
  sed -i "s/^$AGENT_USER:\([^:]*\):[0-9]*:[0-9]*:/$AGENT_USER:\1:$PUID:$PGID:/" /etc/passwd
fi
if [ "$(stat -c %u:%g "$AGENT_HOME")" != "$PUID:$PGID" ]; then
  echo "roost: owning $AGENT_HOME as $PUID:$PGID (one-time, may take a while)"
  chown -R "$PUID:$PGID" "$AGENT_HOME" 2>/dev/null || true
fi
as_agent() { "$GOSU" "$AGENT_USER" env HOME="$AGENT_HOME" "$@"; }

# ---------------------------------------------------------------------------
# 2. Seed an empty home from /etc/skel once, and make the standard dirs.
# ---------------------------------------------------------------------------
if [ ! -f "$AGENT_HOME/.bashrc" ]; then
  as_agent cp -r --update=none /etc/skel/. "$AGENT_HOME"/
fi
as_agent mkdir -p "$AGENT_HOME/projects" "$AGENT_HOME/.claude" "$AGENT_HOME/.codex" \
         "$AGENT_HOME/.config/opencode" "$AGENT_HOME/.local/bin"

# Global agent instructions and roost's skills (guided setup), managed by the
# image: overwritten on every start. ~/.agents/skills is Codex's (and
# opencode's) user skill folder, ~/.claude/skills Claude Code's.
for f in .claude/CLAUDE.md .codex/AGENTS.md .config/opencode/AGENTS.md; do
  as_agent mkdir -p "$AGENT_HOME/$(dirname "$f")"
  as_agent cp /etc/roost/AGENTS.md "$AGENT_HOME/$f"
done
for d in .claude/skills .agents/skills; do
  as_agent mkdir -p "$AGENT_HOME/$d"
  as_agent cp -r /etc/roost/skills/. "$AGENT_HOME/$d"/
done

# ---------------------------------------------------------------------------
# 3. Git identity (as the agent user).
# ---------------------------------------------------------------------------
git_cfg() { "$GOSU" "$AGENT_USER" git config --global "$@"; }
if [ -n "${GIT_USER_NAME:-}" ]; then  git_cfg user.name "$GIT_USER_NAME"; fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then git_cfg user.email "$GIT_USER_EMAIL"; fi
git_cfg init.defaultBranch main
git_cfg pull.rebase true

# ---------------------------------------------------------------------------
# 4. Bootstrap tools into the persistent home, in the background, then idle.
#    Logins (claude / codex / opencode / gh / glab) stay manual.
# ---------------------------------------------------------------------------
bootstrap() {
  # The agent-first PATH exists only inside the agent's processes, never in
  # this root shell.
  local agent_path="$AGENT_HOME/.local/share/mise/shims:$AGENT_HOME/.local/bin:$PATH"
  MISE=/usr/local/bin/mise
  run() { "$GOSU" "$AGENT_USER" env HOME="$AGENT_HOME" PATH="$agent_path" "$@"; }

  # node first: the npm: / npx tools need it.
  extra=""
  [ "$CURSOR" = "1" ] && extra="cursor-agent"
  for t in node@lts $TOOLS $HARNESSES $extra; do
    name="${t%@*}"
    case "$name" in
      npm:*) bare="${name#npm:}";;
      *)     bare="$name";;
    esac
    run "$MISE" where "$bare" >/dev/null 2>&1 \
      || run "$MISE" use -g "$t" 2>/dev/null \
      || run "$MISE" use -g "$name@latest" 2>/dev/null \
      || echo "WARN: could not install $t"
  done

  if [ "$AUTO_UPDATE" = "1" ]; then
    run "$MISE" up && echo "roost: tools updated (AUTO_UPDATE)" \
      || echo "WARN: mise up failed"
    # mise up keeps old versions (running sessions may still use them); at
    # start nothing runs yet, so drop the ones no config wants.
    run "$MISE" prune -y >/dev/null 2>&1 || true
    # Two updaters for one binary fight; mise owns it here.
    run bash -c 's="$HOME/.claude/settings.json"; [ -s "$s" ] || echo "{}" > "$s"
      jq ".env.DISABLE_AUTOUPDATER = \"1\"" "$s" > "$s.tmp" && mv "$s.tmp" "$s"' \
      || echo "WARN: could not switch off Claude Code's auto-updater"
  fi

  run bash -c 'ls "$HOME"/.cache/ms-playwright/chromium-* >/dev/null 2>&1 || playwright install chromium' \
    || echo "WARN: chromium download failed"

  # GH_TOKEN: log gh in with it and let git use gh for HTTPS. ssh sessions do
  # not see the container env, so the token goes into gh's own config.
  # (gh refuses --with-token while GH_TOKEN is set, hence env -u.)
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s\n' "$GH_TOKEN" | run env -u GH_TOKEN gh auth login --with-token \
      && run env -u GH_TOKEN gh auth setup-git \
      && echo "roost: gh logged in from GH_TOKEN" \
      || echo "WARN: gh login from GH_TOKEN failed"
  fi

  # No claude CLI here: `claude mcp add` hangs before the first login.
  # --no-sandbox because the container has no user namespaces for Chromium's sandbox.
  f="$AGENT_HOME/.claude.json"
  [ -f "$f" ] || { [ "$PUID" = "0" ] && echo '{}' > "$f" || run bash -c 'echo "{}" > "$HOME/.claude.json"'; }
  run bash -c "jq -S '.mcpServers.playwright = {\"type\":\"stdio\",\"command\":\"playwright-mcp\",\"args\":[\"--headless\",\"--browser\",\"chromium\",\"--no-sandbox\"],\"env\":{}}' '$f' > '$f.tmp' && mv '$f.tmp' '$f'" \
    || echo "WARN: playwright MCP config failed"

  # Claude via a gateway (LiteLLM, ...): ssh/herdr sessions do not see the
  # container env, so the values go into Claude's own settings. Only the
  # variables that are set are written; clearing one in the template does
  # not remove it from ~/.claude/settings.json.
  gw="$(jq -n '$ENV | {ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_DEFAULT_OPUS_MODEL,
                       ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_DEFAULT_HAIKU_MODEL}
                | with_entries(select(.value != null and .value != ""))')"
  if [ "$gw" != "{}" ]; then
    run env GW="$gw" bash -c 's="$HOME/.claude/settings.json"; [ -s "$s" ] || echo "{}" > "$s"
      jq --argjson gw "$GW" ".env += \$gw" "$s" > "$s.tmp" && mv "$s.tmp" "$s" && chmod 600 "$s"' \
      && echo "roost: Claude gateway set ($(jq -r '.ANTHROPIC_BASE_URL // "model names only"' <<<"$gw"))" \
      || echo "WARN: could not write the Claude gateway settings"
  fi

  # Pre-accept Claude's trust dialog for ~/projects/*; later clones: roost-trust.
  if [ "$TRUST_PROJECTS" = "1" ]; then
    run roost-trust || echo "WARN: trust pre-accept failed"
  fi

  echo "roost bootstrap done"

  # AUTO_UPDATE also checks daily while the box runs, so tools stay current
  # without a restart. Open sessions keep their version; new ones get the new.
  if [ "$AUTO_UPDATE" = "1" ]; then
    while sleep 86400; do
      run "$MISE" up >/dev/null 2>&1 && echo "roost: tools updated (daily AUTO_UPDATE)" \
        || echo "WARN: daily mise up failed"
    done
  fi
}

bootstrap &

# ---------------------------------------------------------------------------
# 5. SSH, the only way in. Host key: generated once into the identity volume,
#    so the fingerprint survives updates. Logins: PUBLIC_KEYS (rebuilt on every
#    start, so removing a key there revokes it) plus the volume's
#    authorized_keys file. Both are root-owned and outside the
#    agent's home, so agents cannot add logins. sshd stays root to drop
#    privileges per login; only `agent` may log in.
# ---------------------------------------------------------------------------
SSH_DIR=/etc/roost/ssh
key="$SSH_DIR/ssh_host_ed25519_key"
if [ ! -s "$key" ]; then
  install -d -o root -g root -m 0755 "$SSH_DIR" 2>/dev/null
  ssh-keygen -q -t ed25519 -N "" -C roost -f "$key" \
    && echo "roost: generated SSH host key $(ssh-keygen -lf "$key.pub" | cut -d' ' -f2)" \
    || echo "WARN: cannot write $SSH_DIR (read-only mount?) — no host key, sshd not started"
fi
install -d -o root -g root -m 0755 /run/roost
# Root-owned so agents in the box cannot change what new terminals run.
printf '%s\n' "$AUTO_AGENT" > /run/roost/auto-agent
chmod 0644 /run/roost/auto-agent
# Separated by newlines or commas (single-line UIs such as Unraid templates).
printf '%s\n' "${PUBLIC_KEYS:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -E '^(ssh-|ecdsa-|sk-)' > /run/roost/authorized_keys
chmod 0644 /run/roost/authorized_keys
if [ ! -s /run/roost/authorized_keys ] && [ ! -s "$SSH_DIR/authorized_keys" ]; then
  echo "WARN: no public keys — set PUBLIC_KEYS (newline- or comma-separated) or add $SSH_DIR/authorized_keys; nobody can log in yet"
fi
# The Heeler plugin pins the host key it finds under /etc/ssh.
ln -sf "$key.pub" /etc/ssh/ssh_host_ed25519_key.pub

# Heeler pairing: the plugin enrolls the phone's key into ~/.ssh/authorized_keys,
# so sshd reads that file too (StrictModes wants the home not group/world
# writable). Address and port for the Pairing Code go to roost-pair via
# /run/roost/heeler-pair.json.
sshd_config=/etc/roost/sshd_config
rm -f /run/roost/heeler-pair.json
if [ "$HEELER_PAIRING" = "1" ]; then
  sshd_config=/run/roost/sshd_config
  sed 's|^AuthorizedKeysFile .*|& .ssh/authorized_keys|' /etc/roost/sshd_config > "$sshd_config"
  chmod go-w "$AGENT_HOME"
  printf '%s\n' "${HEELER_ADDRESSES:-}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | { grep -v '^$' || true; } \
    | jq -R . | jq -s --argjson port "${HEELER_PORT:-2222}" '{ssh_port: $port, addresses: .}' > /run/roost/heeler-pair.json \
    || echo "WARN: HEELER_PORT must be a number — roost-pair will not work"
  chmod 0644 /run/roost/heeler-pair.json
  echo "roost: Heeler pairing on — agents in the box can add logins via ~/.ssh/authorized_keys"
fi
[ -s "$key" ] && /usr/sbin/sshd -D -e -f "$sshd_config" &

exec "$GOSU" "$AGENT_USER" sleep infinity
