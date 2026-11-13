#!/usr/bin/env bash
# start.sh
# Automate: install ngrok CLI, configure macOS Remote Management for a runner user,
# start an ngrok tcp tunnel for Screen Sharing (5900) and keep it alive while tmate is running.
#
# Usage: run inside the GitHub Actions macOS job. Provide NGROK_AUTHTOKEN (required) and REMOTE_PASS (recommended).
# Optional env vars:
#  - NGROK_AUTHTOKEN (required)      : ngrok auth token (store as a secret)
#  - REMOTE_USER (default: remote)   : local macOS user to allow screen sharing
#  - REMOTE_PASS                      : password for REMOTE_USER (if omitted a random password is generated)
#  - VNC_PASSWORD                     : optional legacy VNC password (less secure)
#  - NGROK_DOWNLOAD_URL               : optional full URL to ngrok zip asset
#  - NGROK_PORT (default: 5900)
set -euo pipefail

# --- Configuration / defaults ---
REMOTE_USER="${REMOTE_USER:-remote}"
NGROK_PORT="${NGROK_PORT:-5900}"
NGROK_BIN="/usr/local/bin/ngrok"

# Validate required env
if [ -z "${NGROK_AUTHTOKEN:-}" ]; then
  echo "ERROR: NGROK_AUTHTOKEN not set. Set it as an environment variable or GitHub secret."
  exit 2
fi

# Generate a random password if none provided
if [ -z "${REMOTE_PASS:-}" ]; then
  REMOTE_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%_-+=' </dev/urandom | head -c 20 || echo "runnershared")
  echo "REMOTE_PASS not provided; generated a password for user ${REMOTE_USER}."
fi

# Helper: echo+timestamp
ts() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# --- 1) Create a dedicated local user for remote access (non-admin) if it doesn't exist ---
create_remote_user() {
  if id -u "$REMOTE_USER" >/dev/null 2>&1; then
    ts "User $REMOTE_USER already exists."
    return
  fi

  ts "Creating user $REMOTE_USER ..."
  sudo sysadminctl -addUser "$REMOTE_USER" -fullName "Remote Access" >/dev/null
  sudo dscl . -passwd "/Users/$REMOTE_USER" "$REMOTE_PASS" >/dev/null

  if [ ! -d "/Users/$REMOTE_USER" ]; then
    sudo createhomedir -c -u "$REMOTE_USER" >/dev/null || true
  fi

  ts "User $REMOTE_USER created."
}

# --- 2) Enable Remote Management and grant access for the remote user using kickstart ---
enable_remote_management() {
  ts "Enabling Remote Management (Apple Remote Desktop / Screen Sharing) for $REMOTE_USER ..."
  KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
  if [ ! -x "$KICKSTART" ]; then
    ts "kickstart tool missing at $KICKSTART; aborting"
    exit 3
  fi

  sudo "$KICKSTART" -activate -configure -access -on -users "$REMOTE_USER" -privs -all -restart -agent
  ts "Remote Management enabled for $REMOTE_USER."

  if [ -n "${VNC_PASSWORD:-}" ]; then
    ts "Configuring legacy VNC password (less secure) ..."
    sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes \
      -setvncpw -vncpw "$VNC_PASSWORD"
    ts "Legacy VNC password configured."
  fi
}

# --- 3) Install ngrok CLI without Homebrew ---
install_ngrok() {
  if [ -x "$NGROK_BIN" ]; then
    ts "ngrok already installed at $NGROK_BIN"
    return
  fi

  TS_ARCH="$(uname -m)"
  TS_OS="$(uname -s)"
  ts "Runner OS: $TS_OS, arch: $TS_ARCH"

  DOWNLOAD_URL="${NGROK_DOWNLOAD_URL:-}"
  if [ -z "$DOWNLOAD_URL" ]; then
    case "$TS_OS" in
      Darwin) os_token="darwin" ;;
      Linux) os_token="linux" ;;
      *) ts "Unsupported OS: $TS_OS"; exit 4 ;;
    esac

    case "$TS_ARCH" in
      x86_64|i386) arch_token="amd64" ;;
      arm64|aarch64) arch_token="arm64" ;;
      *) ts "Unsupported arch: $TS_ARCH"; exit 4 ;;
    esac

    DOWNLOAD_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-${os_token}-${arch_token}.zip"
  fi

  ts "Downloading ngrok from: $DOWNLOAD_URL"
  tmp="/tmp/ngrok_download.$$"
  mkdir -p "$tmp"
  curl -sSfL "$DOWNLOAD_URL" -o "$tmp/ngrok.zip" || { ts "Download failed"; exit 5; }

  unzip -q "$tmp/ngrok.zip" -d "$tmp" || { ts "Failed to extract ngrok"; exit 6; }

  if [ ! -f "$tmp/ngrok" ]; then
    ts "Failed to locate ngrok binary in archive."
    ls -la "$tmp" || true
    exit 7
  fi

  ts "Installing ngrok binary to $NGROK_BIN"
  sudo mv "$tmp/ngrok" "$NGROK_BIN"
  sudo chmod 755 "$NGROK_BIN"
  ts "ngrok installed at $NGROK_BIN"
  rm -rf "$tmp"
}

print_ngrok_endpoint() {
  if endpoint="$(python3 - <<'PYTHON'
import json,sys,urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:4040/api/tunnels', timeout=2) as r:
        data = json.load(r)
    for t in data.get('tunnels', []):
        u = t.get('public_url', '')
        if u.startswith('tcp://'):
            print(u)
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PYTHON
)"; then
    ts "Remote endpoint: ${endpoint#tcp://}  (use vnc://${endpoint#tcp://} to connect with a VNC client)"
    return 0
  fi

  if grep -Eo 'tcp://[^[:space:]]+' /tmp/ngrok.log | head -n1 >/dev/null 2>&1; then
    endpoint="$(grep -Eo 'tcp://[^[:space:]]+' /tmp/ngrok.log | head -n1)"
    ts "Remote endpoint: ${endpoint#tcp://}  (use vnc://${endpoint#tcp://} to connect with a VNC client)"
    return 0
  fi

  return 1
}

# --- 4) start ngrok (background) and output connection info ---
start_ngrok() {
  ts "Configuring ngrok authtoken ..."
  "$NGROK_BIN" config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null

  ts "Starting ngrok tcp tunnel on local port ${NGROK_PORT} ..."
  nohup "$NGROK_BIN" tcp "$NGROK_PORT" --log stdout &> /tmp/ngrok.log &
  NGROK_PID=$!
  echo "$NGROK_PID" > /tmp/ngrok.pid
  ts "ngrok started (pid: $NGROK_PID). Logs at /tmp/ngrok.log"

  for _ in $(seq 1 20); do
    if print_ngrok_endpoint; then
      return 0
    fi
    sleep 1
  done

  ts "Could not parse endpoint from ngrok yet. Inspect /tmp/ngrok.log for details."
  tail -n 50 /tmp/ngrok.log || true
}

# --- 5) Monitor loop: keep ngrok alive while tmate is running ---
monitor_while_tmate() {
  ts "Entering monitor loop: will keep ngrok running while a tmate process exists."
  wait_seconds=0
  max_wait=120
  while [ $wait_seconds -lt $max_wait ]; do
    if pgrep -x tmate >/dev/null 2>&1; then
      ts "Detected tmate process."
      break
    fi
    sleep 1
    wait_seconds=$((wait_seconds + 1))
  done

  while true; do
    if ! pgrep -x tmate >/dev/null 2>&1; then
      ts "No tmate process found. Terminating ngrok and exiting."
      if [ -f /tmp/ngrok.pid ]; then
        kill "$(cat /tmp/ngrok.pid)" >/dev/null 2>&1 || true
        rm -f /tmp/ngrok.pid || true
      else
        pkill -x ngrok >/dev/null 2>&1 || true
      fi
      break
    fi

    if ! pgrep -x ngrok >/dev/null 2>&1; then
      ts "ngrok process not found - restarting..."
      start_ngrok
    fi
    sleep 5
  done
}

# --- Run steps ---
ts "Starting automation..."

create_remote_user
enable_remote_management
install_ngrok
start_ngrok
monitor_while_tmate

ts "Script finished."
