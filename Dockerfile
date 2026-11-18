FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# System packages. Chromium's shared libraries come from `playwright install-deps`
# in the next step; the browser itself is downloaded into the home volume at
# first start (entrypoint.sh). gosu lets the entrypoint drop root->agent after
# remapping the uid/gid to PUID/PGID.
# End users add their own apt packages via Dockerfile.user, not here.
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      ca-certificates curl git tmux ripgrep fd-find jq btop build-essential \
      python3-venv unzip vim less openssh-client openssh-server tzdata gosu rsync \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Pinned and checksum-verified: a compromised download host cannot swap the
# binary that installs everything else. Tools themselves are still updated
# inside with `mise up`. To bump: take the version and the two linux sums
# from SHASUMS256.txt of https://github.com/jdx/mise/releases.
# TARGETARCH is set by buildx (amd64 / arm64); mise names them x64 / arm64.
ARG TARGETARCH
ARG MISE_VERSION=2026.11.9
ARG MISE_SHA256_X64=f13f3e5ec88807e0161669b3aa07a91d84478cdf1e95b5b92b63f85a25d42395
ARG MISE_SHA256_ARM64=b8dd05af6447cee933928664982a8cb2fa646e6951cfc8539db23ce2554a7b04
RUN if [ "$TARGETARCH" = arm64 ]; then arch=arm64 sum="$MISE_SHA256_ARM64"; \
    else arch=x64 sum="$MISE_SHA256_X64"; fi \
    && curl -fsSL "https://github.com/jdx/mise/releases/download/v$MISE_VERSION/mise-v$MISE_VERSION-linux-$arch" \
         -o /usr/local/bin/mise \
    && echo "$sum  /usr/local/bin/mise" | sha256sum -c - \
    && chmod +x /usr/local/bin/mise

# Throwaway node (Ubuntu's is too old for playwright) just for the system libs.
RUN MISE_DATA_DIR=/tmp/mise mise exec node@lts -- npx -y playwright install-deps chromium \
    && rm -rf /tmp/mise /root/.npm /var/lib/apt/lists/*

# Placeholder ids that entrypoint.sh remaps to PUID/PGID at start. No sudo on
# purpose: the container is the containment boundary.
# ubuntu:24.04 ships a default `ubuntu` user at 1000:1000; drop it first.
RUN (userdel -r ubuntu 2>/dev/null; groupdel ubuntu 2>/dev/null; true) \
    && groupadd -g 1000 agent \
    && useradd -u 1000 -g agent -m -s /bin/bash -p '*' agent

COPY agent-instructions.md /etc/roost/AGENTS.md
COPY skills /etc/roost/skills
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY roost-trust roost-pair roost-busy /usr/local/bin/
COPY sshd_config /etc/roost/sshd_config

# PATH for login shells (docker exec bash -l) + aliases for interactive ones.
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/roost-trust /usr/local/bin/roost-pair /usr/local/bin/roost-busy \
    && echo 'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"' > /etc/profile.d/roost.sh \
    && printf '%s\n' \
      "eval \"\$(/usr/local/bin/mise activate bash)\"" \
      "alias a='claude'" \
      "alias c='opencode'" \
      "alias cx='claude --dangerously-skip-permissions'" \
      "alias cy='codex --approve-for-me'" \
      "alias cz='opencode --dangerously-skip-permissions'" >> /etc/bash.bashrc

# Watchtower (with WATCHTOWER_LIFECYCLE_HOOKS=true) asks roost-busy before
# updating: while an agent runs it exits 75 and the update waits for the next
# check. Watchtower without hooks enabled ignores this label.
LABEL com.centurylinklabs.watchtower.lifecycle.pre-update="/usr/local/bin/roost-busy"

# Main process starts as root so entrypoint.sh can remap uid/gid, then drops.
WORKDIR /home/agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
