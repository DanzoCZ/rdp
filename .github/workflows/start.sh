#!/usr/bin/env bash
# start.sh
# Automate: install zrok CLI (no Homebrew), configure macOS Remote Management for a runner user,
# start a zrok tcp tunnel for Screen Sharing (5900) and keep it alive while tmate is running.
#
# Usage: run inside the GitHub Actions macOS job. Provide ZROK_TOKEN (required) and REMOTE_PASS (recommended).
# Optional env vars:
#  - ZROK_TOKEN (required)         : zrok auth token (store as a secret)
#  - REMOTE_USER (default: remote) : local macOS user to allow screen sharing
#  - REMOTE_PASS                   : password for REMOTE_USER (if omitted a random password is generated)
#  - VNC_PASSWORD                  : optional legacy VNC password (less secure)
#  - ZROK_DOWNLOAD_URL             : optional full URL to zrok binary release asset (bypass auto-discovery)
#  - ZROK_PORT (default: 5900)
set -euo pipefail

# --- Configuration / defaults ---
REMOTE_USER="${REMOTE_USER:-remote}"
ZROK_PORT="${ZROK_PORT:-5900}"
ZROK_BIN="/usr/local/bin/zrok"
ZROK_REPO="zrok-io/zrok"   # used to discover releases if ZROK_DOWNLOAD_URL not provided

# Validate required env
if [ -z "${ZROK_TOKEN:-}" ]; then
  echo "ERROR: ZROK_TOKEN not set. Set it as an environment variable or GitHub secret."
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
  # sysadminctl is preferred on modern macOS to create users
  # create non-admin user with specified password
  sudo sysadminctl -addUser "$REMOTE_USER" -fullName "Remote Access"****** >/dev/null

  # ensure the user's home folder exists (sysadminctl normally does it)
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

  # Activate Remote Management, enable access, grant privileges to the specific user, restart the agent
  # Using -privs -all here for simplicity in CI. For stricter security, limit privileges.
  sudo "$KICKSTART" -activate -configure -access -on -users "$REMOTE_USER" -privs -all -restart -agent
  ts "Remote Management enabled for $REMOTE_USER."

  # Optionally enable legacy VNC password (less secure, 8-char limit historically). Only set if VNC_PASSWORD provided
  if [ -n "${VNC_PASSWORD:-}" ]; then
    ts "Configuring legacy VNC password (less secure) ..."
    # setvnclegacy and setvncpw apply the VNC-compatible password (if supported)
    sudo "$KICKSTART" -configure -clientopts -setvnclegacy -vnclegacy yes \
      -setvncpw -vncpw "$VNC_PASSWORD"
    ts "Legacy VNC password configured."
  fi
}

# --- 3) Install zrok CLI without Homebrew ---
install_zrok() {
  if [ -x "$ZROK_BIN" ]; then
    ts "zrok already installed at $ZROK_BIN"
    return
  fi

  TS_ARCH="$(uname -m)"
  TS_OS="$(uname -s)"
  ts "Runner OS: $TS_OS, arch: $TS_ARCH"

  DOWNLOAD_URL="${ZROK_DOWNLOAD_URL:-}"

  if [ -z "$DOWNLOAD_URL" ]; then
    ts "Discovering latest zrok release for this platform from GitHub releases..."
    # Map uname -m to expected asset strings
    case "$TS_ARCH" in
      x86_64|i386) arch_token="amd64" ;; 
      arm64|aarch64) arch_token="arm64" ;; 
      *) arch_token="$TS_ARCH" ;; 
    esac

    case "$TS_OS" in
      Darwin) os_token="darwin" ;; 
      Linux) os_token="linux" ;; 
      *) os_token="$(echo "$TS_OS" | tr '[:upper:]' '[:lower:]')" ;; 
    esac

    # Use GitHub API and python to pick a suitable asset (robust even without jq)
    api_url="https://api.github.com/repos/${ZROK_REPO}/releases/latest"
    ts "Querying $api_url ..."
    release_json="$(curl -sSfL "$api_url")" || { ts "Failed to fetch release metadata"; exit 4; }

    DOWNLOAD_URL="$(printf '%s' "$release_json" | OS_TOKEN="$os_token" ARCH_TOKEN="$arch_token" python3 - <<'PYTHON'
import json,sys
import os
data=json.load(sys.stdin)
assets=data.get("assets",[])
candidates=[]
os_token = os.environ["OS_TOKEN"]
arch_token = os.environ["ARCH_TOKEN"]
for a in assets:
    name=a.get("name","").lower()
    url=a.get("browser_download_url","")
    if os_token in name and arch_token in name:
        candidates.append((name,url))
if candidates:
    # prefer tar.gz or zip
    candidates.sort()
    print(candidates[-1][1])
    sys.exit(0)
# fallback: try any asset containing os_token
for a in assets:
    name=a.get("name","").lower()
    url=a.get("browser_download_url","")
    if os_token in name:
        print(url); sys.exit(0)
# give up
sys.exit(1)
PYTHON
)"
    if [ -z "$DOWNLOAD_URL" ]; then
      ts "Could not auto-discover a zrok asset for ${os_token}/${arch_token}. Provide ZROK_DOWNLOAD_URL manually."
      exit 5
    fi
  fi

  ts "Downloading zrok from: $DOWNLOAD_URL"
  tmp="/tmp/zrok_download.$$"
  mkdir -p "$tmp"
  curl -sSfL "$DOWNLOAD_URL" -o "$tmp/asset" || { ts "Download failed"; exit 6; }

  # Try to extract a single binary from archive or treat as raw binary
  file "$tmp/asset" | grep -q 'Zip archive' && {
    ts "Extracting zip ..."
    unzip -q "$tmp/asset" -d "$tmp"
  } || true
  file "$tmp/asset" | grep -q 'gzip compressed' && {
    ts "Extracting tar.gz ..."
    tar -xzf "$tmp/asset" -C "$tmp" || true
  } || true

  # Find a zrok binary inside tmp dir or treat asset as binary
  found=""
  if [ -f "$tmp/asset" ]; then
    # check if it's executable single binary
    if head -c 4 "$tmp/asset" | grep -q "ELF\|MZ\|xar!" || file "$tmp/asset" | grep -q 'Mach-O'; then
      found="$tmp/asset"
    fi
  fi
  # search extracted
  if [ -z "$found" ]; then
    found="$(find "$tmp" -type f -name 'zrok*' -perm -111 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$found" ]; then
    # try any executable file
    found="$(find "$tmp" -type f -perm -111 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$found" ]; then
    ts "Failed to locate a zrok binary in the downloaded asset."
    ls -la "$tmp" || true
    exit 7
  fi

  ts "Installing zrok binary from $found to $ZROK_BIN"
  sudo mv "$found" "$ZROK_BIN"
  sudo chmod 755 "$ZROK_BIN"
  ts "zrok installed at $ZROK_BIN"
  rm -rf "$tmp"
}

# --- 4) start zrok (background) and output connection info ---
start_zrok() {
  # We export the token in the env for the zrok process. If the zrok CLI supports a different env var name,
  # set it before running. We preserve the token in memory only for the launched process.
  ts "Starting zrok tcp tunnel on local port ${ZROK_PORT} ..."
  export ZROK_TOKEN="$ZROK_TOKEN"
  # Start with nohup so it survives the shell exiting inside GH Actions step if needed; capture PID.
  nohup "$ZROK_BIN" tcp "$ZROK_PORT" &> /tmp/zrok.log &
  ZROK_PID=$!
  echo "$ZROK_PID" > /tmp/zrok.pid
  ts "zrok started (pid: $ZROK_PID). Logs at /tmp/zrok.log"
  # Wait briefly and try to show the connection endpoint (zrok usually prints it to stdout -> /tmp/zrok.log)
  sleep 2
  if grep -Eo '([a-z0-9\-]+\.tcp\.zrok\.io:[0-9]+)' /tmp/zrok.log | head -n1 >/dev/null 2>&1; then
    endpoint="$(grep -Eo '([a-z0-9\-]+\.tcp\.zrok\.io:[0-9]+)' /tmp/zrok.log | head -n1)"
    ts "Remote endpoint: $endpoint  (use vnc://$endpoint to connect with a VNC client)"
  else
    ts "Could not parse endpoint from zrok logs yet. Inspect /tmp/zrok.log for details."
    tail -n 50 /tmp/zrok.log || true
  fi
}

# --- 5) Monitor loop: keep zrok alive while tmate is running ---
monitor_while_tmate() {
  ts "Entering monitor loop: will keep zrok running while a tmate process exists."
  # Wait until a tmate process appears (if none are running yet) OR exit when none ever appear?
  # In typical GH Actions flow, tmate might be started by another step after this script.
  # We'll wait up to 120 seconds for tmate to appear; if it doesn't, we still run zrok for immediate use.
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

  # If tmate never started, we keep zrok running until this job ends; but also still supervise.
  while true; do
    # If tmate is gone -> stop zrok and exit
    if ! pgrep -x tmate >/dev/null 2>&1; then
      ts "No tmate process found. Terminating zrok and exiting."
      if [ -f /tmp/zrok.pid ]; then
        kill "$(cat /tmp/zrok.pid)" >/dev/null 2>&1 || true
        rm -f /tmp/zrok.pid || true
      else
        pkill -x zrok >/dev/null 2>&1 || true
      fi
      break
    fi

    # If zrok died, restart it
    if ! pgrep -x zrok >/dev/null 2>&1; then
      ts "zrok process not found - restarting..."
      start_zrok
    fi
    sleep 5
  done
}

# --- Run steps ---
ts "Starting automation..."

create_remote_user
enable_remote_management
install_zrok
start_zrok
monitor_while_tmate

ts "Script finished."
