#!/usr/bin/env bash
NAME="claude-$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
IMAGE="claude-box"
BOX_DIR="$HOME/.claude-box"
NET="claude-net"
PROXY="claude-proxy"
SUBNET="10.89.77.0/24"
PROXY_IP="10.89.77.2"  # fixed address, since claude-net has no DNS to look up "claude-proxy"
FIREWALL=true

for arg in "$@"; do  # Sets FIREWALL variable accordingly
  [[ "$arg" == "-nof" || "$arg" == "--no-firewall" ]] && FIREWALL=false
done

# Folders that should never be mounted into the box (too much access, or the box's own config)
BLOCKED_DIRS=(
  "/"
  "/Users"
  "$HOME"
  "$HOME/Desktop"
  "$HOME/Documents"
  "$HOME/Downloads"
  "$HOME/.claude"
  "$BOX_DIR"
)
for dir in "${BLOCKED_DIRS[@]}"; do
  if [[ "$PWD" == "$dir" ]]; then
    echo "Run claude-box from a project folder, not $PWD." >&2
    exit 1
  fi
done

mkdir -p "$BOX_DIR/projects/$NAME"  # creates .claude-box directory if it doesnt exist, one per project

# Settings shared by every box, read-only inside them (highest priority, can't be overridden)
[[ -f "$BOX_DIR/managed-settings.json" ]] || echo '{}' > "$BOX_DIR/managed-settings.json"  # creates if doesnt exist
# Instructions shared by every box, read-only inside them (empty file is fine for markdown)
[[ -f "$BOX_DIR/CLAUDE.md" ]] || touch "$BOX_DIR/CLAUDE.md"  # creates if doesnt exist

# Proxy config: only hosts matching the allowlist get through
cat > "$BOX_DIR/tinyproxy.conf" <<'EOF'
User nobody
Group nobody
Port 3128
Listen 0.0.0.0
Timeout 600
ConnectPort 443
FilterDefaultDeny Yes
FilterType ere
Filter "/etc/tinyproxy/allowlist"
EOF
# Port 3128 is the port that listens to the rest of the containers in the net
# Internet cant reach the proxy unless the proxy sends out the request
# ConnectPort 443 is the port that the PROXY can reach inside other servers (not too important)

# Allowlist is only written once so you can edit it (^, \., $ are regex chars)
if [[ ! -f "$BOX_DIR/allowlist" ]]; then
  cat > "$BOX_DIR/allowlist" <<'EOF'
^api\.anthropic\.com$
^claude\.ai$
^platform\.claude\.com$
EOF
fi
# api is for requests to the model
# claude.ai is to log in
# platform is for refreshing login token

# Slimmed-down version of Anthropic's reference devcontainer (no sudo, no iptables)
# Rebuild to update Claude: podman rmi claude-box
if ! podman image exists "$IMAGE"; then
  podman build -t "$IMAGE" -f - "$BOX_DIR" <<'EOF'
# Start from the official Node.js image (Debian Linux + Node, which Claude Code runs on)
FROM docker.io/library/node:22
# Install basic tools Claude uses: git, a pager, ps, fast search, JSON parsing, HTTP requests
# (then delete the package index to keep the image small)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git less procps ripgrep jq curl \
    && rm -rf /var/lib/apt/lists/*
# Install Claude Code as root, so its files are read-only to Claude
RUN npm install -g @anthropic-ai/claude-code
# Switch to the built-in non-root "node" user (no sudo, so it can't become root)
USER node
# Start in /workspace, where your project folder gets mounted
WORKDIR /workspace
EOF
fi

# Internal network: no route to the internet, and no DNS
# (its DNS would also become the proxy's and refuse outside names, breaking the proxy)
podman network exists "$NET" || podman network create --internal --disable-dns --subnet "$SUBNET" "$NET" >/dev/null

# Proxy sits on both networks, so it's the only way out. Always running (tinyproxy is the main process).
if ! podman container exists "$PROXY"; then
  podman create --name "$PROXY" --network podman --network "$NET:ip=$PROXY_IP" \
    -v "$BOX_DIR/tinyproxy.conf":/etc/tinyproxy/tinyproxy.conf:ro \
    -v "$BOX_DIR/allowlist":/etc/tinyproxy/allowlist:ro \
    docker.io/library/alpine:3 \
    sh -c 'command -v tinyproxy >/dev/null || apk add --no-cache tinyproxy; exec tinyproxy -d' >/dev/null
fi
podman start "$PROXY" >/dev/null
# podman create makes a container without starting it (like what podman run does)

# Creating Claude's container: Claude's container just idles; each session is a `podman exec` so the proxy env can change per run
if ! podman container exists "$NAME"; then
  MOUNTS=(
    -v "$PWD":/workspace:U
    -v "$BOX_DIR/projects/$NAME":/home/node/.claude:U
    -v "$BOX_DIR/managed-settings.json":/etc/claude-code/managed-settings.json:ro
    -v "$BOX_DIR/CLAUDE.md":/etc/claude-code/CLAUDE.md:ro
  )
  [[ -d "$HOME/.claude/skills" ]] && MOUNTS+=(-v "$HOME/.claude/skills":/home/node/.claude/skills:ro) # if skills exist, mount

  # CLAUDE_CONFIG_DIR: keep everything including .claude.json in that dir, its user info.
  # DISABLE_AUTOUPDATER: doesnt update itself (it will fail anyways)
  # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: would break with firewall
  # "${MOUNTS[@]}": mounts the previous commands (-e was necessary)
  # sleep infinity: keeps container on so we can run claude command (this is the main process before claude is run)
  podman create --name "$NAME" --network "$NET" -w /workspace \
    -e CLAUDE_CONFIG_DIR=/home/node/.claude \
    -e DISABLE_AUTOUPDATER=1 \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    "${MOUNTS[@]}" \
    --entrypoint sleep "$IMAGE" infinity >/dev/null
fi

# If another session is already open in this box, don't switch its network out from under it
# pgrep: is a claude already running? (fails quietly if the box is stopped, so the check is skipped)
# inspect: is the box on claude-net? -> that open session has the firewall on
if podman exec "$NAME" pgrep -f claude >/dev/null 2>&1; then
  podman inspect -f '{{json .NetworkSettings.Networks}}' "$NAME" | grep -q "\"$NET\"" && OPEN_FW=true || OPEN_FW=false
  if [[ "$OPEN_FW" != "$FIREWALL" ]]; then
    echo "Another session in this project is running with the firewall $($OPEN_FW && echo on || echo off). Exit it first." >&2
    exit 1
  fi
fi

# Switch networks before starting so it's never on both
if $FIREWALL; then  # Claude's container is only part of claude-net, so it must go through proxy
  podman network disconnect podman "$NAME" 2>/dev/null
  podman network connect "$NET" "$NAME" 2>/dev/null
  PROXY_ENV=(-e HTTPS_PROXY="http://$PROXY_IP:3128" -e HTTP_PROXY="http://$PROXY_IP:3128")
else
  podman network disconnect "$NET" "$NAME" 2>/dev/null
  podman network connect podman "$NAME" 2>/dev/null
  PROXY_ENV=()
fi

# Pass your Mac's git name/email into the box so commits work there (not credentials, can't push)
GIT_NAME="$(git config user.name)"
GIT_EMAIL="$(git config user.email)"
GIT_ENV=(
  -e GIT_AUTHOR_NAME="$GIT_NAME" -e GIT_COMMITTER_NAME="$GIT_NAME"
  -e GIT_AUTHOR_EMAIL="$GIT_EMAIL" -e GIT_COMMITTER_EMAIL="$GIT_EMAIL"
)

podman start "$NAME" >/dev/null
podman exec -it "${PROXY_ENV[@]}" "${GIT_ENV[@]}" "$NAME" claude  # PROXY_ENV is either empty or holds the port
# After claude exits, stop the container, but only if no other Claude session is still running in it
# pgrep -f claude: checks for any running "claude" process inside the box (|| = only stop if none found)
podman exec "$NAME" pgrep -f claude >/dev/null || podman stop -t 0 "$NAME" >/dev/null
