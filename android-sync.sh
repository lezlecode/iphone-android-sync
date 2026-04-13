#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "Error: config.sh not found. Run ./setup.sh first." >&2
  exit 1
fi
source "$CONFIG"

TAILSCALE="/usr/local/bin/tailscale"
ANDROID_LOCAL_IP_FILE="$EXPORT_DIR/.android-local-ip"
MANIFEST="$EXPORT_DIR/.android-synced-manifest"
MIN_FREE_KB="${ANDROID_MIN_FREE_KB:-$((15 * 1024 * 1024))}"

# ===== SPINNER =====
_SPINNER_PID=""
_spinner() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while true; do
    printf "\r  %s  %s " "${frames[$((i % 10))]}" "$msg"
    sleep 0.1
    ((i++))
  done
}
start_spinner() {
  [ -t 1 ] || return
  _spinner "$1" &
  _SPINNER_PID=$!
}
stop_spinner() {
  [ -z "$_SPINNER_PID" ] && return
  kill "$_SPINNER_PID" 2>/dev/null
  wait "$_SPINNER_PID" 2>/dev/null
  printf "\r\033[K"
  _SPINNER_PID=""
}
trap 'stop_spinner' EXIT

send_telegram() {
  [ -z "$TELEGRAM_BOT_TOKEN" ] && return
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="$1" \
    -d parse_mode="Markdown" >/dev/null 2>&1
}

# ===== TAILSCALE AUTO-CONNECT =====
# Ensure Tailscale is running. On same-network, Tailscale uses a direct P2P
# WireGuard path (no relay), so speed is equivalent to raw local transfer.
ensure_tailscale() {
  [ -z "$ANDROID_TAILSCALE_IP" ] && return

  if ! "$TAILSCALE" status >/dev/null 2>&1; then
    echo "$(date): [android-sync] starting Tailscale..."
    "$TAILSCALE" up >/dev/null 2>&1 &
    open -a Tailscale 2>/dev/null
    start_spinner "Starting Tailscale..."
    for i in $(seq 1 30); do
      sleep 1
      if "$TAILSCALE" status >/dev/null 2>&1; then
        stop_spinner
        echo "$(date): [android-sync] Tailscale connected"
        return
      fi
    done
    stop_spinner
    echo "$(date): [android-sync] Tailscale did not connect in time"
  else
    echo "$(date): [android-sync] Tailscale already running"
  fi
}

ensure_tailscale

# ===== FIND ANDROID VIA TAILSCALE =====
# Android blocks incoming TCP (sshd port 8022) on the WiFi interface — this is
# normal Android kernel firewall behaviour. Tailscale uses WireGuard (UDP) which
# is allowed, AND when both devices are on the same network Tailscale establishes
# a direct peer-to-peer path (no relay) so speeds are equivalent to raw local.
SYNC_METHOD=""
ANDROID_IP=""

try_ssh() {
  local ip="$1"
  if ! nc -z -G 2 "$ip" "$ANDROID_SSH_PORT" 2>/dev/null; then
    return 1
  fi
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=3 \
      -o ServerAliveCountMax=1 -o BatchMode=yes \
      -p "$ANDROID_SSH_PORT" "$ANDROID_SSH_USER@$ip" "echo ok" >/dev/null 2>&1
}

find_android() {
  echo "$(date): [android-sync] find_android starting"

  if [ -z "$ANDROID_TAILSCALE_IP" ]; then
    echo "$(date): [android-sync] no Tailscale IP configured"
    return 1
  fi

  start_spinner "Connecting to Android via Tailscale..."
  if try_ssh "$ANDROID_TAILSCALE_IP"; then
    stop_spinner
    ANDROID_IP="$ANDROID_TAILSCALE_IP"
    SYNC_METHOD="tailscale"
    echo "$(date): [android-sync] connected via Tailscale SSH"
    return 0
  fi
  stop_spinner
  echo "$(date): [android-sync] Tailscale SSH failed — is Tailscale running on Android?"
  return 1
}

if ! find_android; then
  echo "$(date): [android-sync] exiting - no device found"
  exit 0
fi

echo "$(date): [android-sync] SYNC_METHOD=$SYNC_METHOD"

# ===== SYNC FILES TO ANDROID =====
shopt -s nullglob
touch "$MANIFEST"
synced=0
failed=0
total_bytes=0

push_file() {
  local src="$1" dest_name="$2"
  if [ -t 1 ]; then
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=1 -o BatchMode=yes \
        -P "$ANDROID_SSH_PORT" "$src" \
        "${ANDROID_SSH_USER}@${ANDROID_IP}:/sdcard/DCIM/${dest_name}"
  else
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=3 \
        -o ServerAliveCountMax=1 -o BatchMode=yes \
        -P "$ANDROID_SSH_PORT" "$src" \
        "${ANDROID_SSH_USER}@${ANDROID_IP}:/sdcard/DCIM/${dest_name}" >/dev/null 2>&1
  fi
}

get_free_space() {
  ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
      -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
      "$ANDROID_SSH_USER@$ANDROID_IP" \
      "df /data 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null
}

echo "$(date): [android-sync] scanning for files in $EXPORT_DIR"
file_count=$(ls "$EXPORT_DIR"/*.HEIC "$EXPORT_DIR"/*.heic \
               "$EXPORT_DIR"/*.JPG "$EXPORT_DIR"/*.jpg \
               "$EXPORT_DIR"/*.PNG "$EXPORT_DIR"/*.png \
               "$EXPORT_DIR"/*.MOV "$EXPORT_DIR"/*.mov \
               "$EXPORT_DIR"/*.MP4 "$EXPORT_DIR"/*.mp4 \
               "$EXPORT_DIR"/*.TIFF "$EXPORT_DIR"/*.tiff 2>/dev/null | wc -l)
echo "$(date): [android-sync] found $file_count media files"

for f in "$EXPORT_DIR"/*.HEIC "$EXPORT_DIR"/*.heic \
         "$EXPORT_DIR"/*.JPG  "$EXPORT_DIR"/*.jpg  \
         "$EXPORT_DIR"/*.PNG  "$EXPORT_DIR"/*.png  \
         "$EXPORT_DIR"/*.MOV  "$EXPORT_DIR"/*.mov  \
         "$EXPORT_DIR"/*.MP4  "$EXPORT_DIR"/*.mp4  \
         "$EXPORT_DIR"/*.TIFF "$EXPORT_DIR"/*.tiff; do

  filename=$(basename "$f")

  if grep -qxF "$filename" "$MANIFEST" 2>/dev/null; then
    rm -f "$f"
    continue
  fi

  file_bytes=$(stat -f%z "$f" 2>/dev/null || echo 0)
  echo "$(date): [android-sync] pushing $filename ($file_bytes bytes) via $SYNC_METHOD"
  if push_file "$f" "$filename"; then
    echo "$filename" >> "$MANIFEST"
    total_bytes=$((total_bytes + file_bytes))
    rm -f "$f"
    ((synced++))
    echo "$(date): [android-sync] ✅ $filename pushed"
  else
    echo "$(date): [android-sync] retrying $filename..."
    sleep 1
    if push_file "$f" "$filename"; then
      echo "$filename" >> "$MANIFEST"
      total_bytes=$((total_bytes + file_bytes))
      rm -f "$f"
      ((synced++))
      echo "$(date): [android-sync] ✅ $filename pushed (retry)"
    else
      ((failed++))
      echo "$(date): [android-sync] ❌ $filename FAILED"
    fi
  fi
done

if [ "$synced" -gt 0 ]; then
  ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
      -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
      "$ANDROID_SSH_USER@$ANDROID_IP" \
      "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/DCIM/'" >/dev/null 2>&1

  size_mb=$(echo "scale=1; $total_bytes / 1048576" | bc)
  if [ "$(echo "$size_mb >= 1024" | bc)" -eq 1 ]; then
    size_display="$(echo "scale=2; $size_mb / 1024" | bc) GB"
  else
    size_display="${size_mb} MB"
  fi

  free_kb=$(get_free_space)
  free_gb=$(echo "scale=1; ${free_kb:-0} / 1048576" | bc)

  via=$( [ "$SYNC_METHOD" = "local" ] && echo "via WiFi" || echo "via Tailscale 🌐" )

  msg="📸 *Sync complete*
${synced} files synced to Android (${size_display}) ${via}
📱 Free space: ${free_gb} GB"
  [ "$failed" -gt 0 ] && msg="${msg}
⚠️ ${failed} failed"
  send_telegram "$msg"
fi

# ===== CLEANUP OLD FILES IF LOW ON SPACE =====
free_kb=$(get_free_space)

if [ -n "$free_kb" ] && [ "$free_kb" -lt "$MIN_FREE_KB" ] 2>/dev/null; then
  ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
      -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
      "$ANDROID_SSH_USER@$ANDROID_IP" \
      "ls -tr /sdcard/DCIM/ 2>/dev/null" | while read -r oldest; do
    [ -z "$oldest" ] && continue
    current_free=$(get_free_space)
    [ "$current_free" -ge "$MIN_FREE_KB" ] 2>/dev/null && break
    ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
        -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
        "$ANDROID_SSH_USER@$ANDROID_IP" \
        "rm /sdcard/DCIM/$oldest" 2>/dev/null
  done

  final_free_kb=$(get_free_space)
  final_free_gb=$(echo "scale=1; ${final_free_kb:-0} / 1048576" | bc)
  send_telegram "⚠️ *Storage cleanup*
Deleted old files to free space
📱 Free space now: ${final_free_gb} GB"
fi
