#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "Error: config.sh not found. Run ./setup.sh first." >&2
  exit 1
fi
source "$CONFIG"

TAILSCALE="/usr/local/bin/tailscale"
MANIFEST="$EXPORT_DIR/.android-synced-manifest"
MIN_FREE_KB="${ANDROID_MIN_FREE_KB:-$((15 * 1024 * 1024))}"
LOG="/tmp/photos-sync.log"
START_TIME=$SECONDS

# ===== UI =====
if [ -t 1 ]; then
  _B=$'\033[1m' _D=$'\033[2m' _G=$'\033[0;32m' _Y=$'\033[1;33m'
  _R=$'\033[0;31m' _C=$'\033[0;36m' _N=$'\033[0m'
else
  _B='' _D='' _G='' _Y='' _R='' _C='' _N=''
fi

_log()  { echo "$(date): [android-sync] $*" >> "$LOG"; }
_sec()  { [ -t 1 ] && printf "\n${_B}  %s  %s${_N}\n  ──────────────────────────────────────────────────\n" "$1" "$2"; }
_ok()   { [ -t 1 ] && printf "\r\033[K  ${_G}✓${_N}  %s\n" "$*"; }
_warn() { [ -t 1 ] && printf "\r\033[K  ${_Y}!${_N}  %s\n" "$*"; }
_err()  { [ -t 1 ] && printf "\r\033[K  ${_R}✗${_N}  %s\n" "$*"; }
_info() { [ -t 1 ] && printf "     %s\n" "$*"; }
_sep()  { [ -t 1 ] && printf "\n  ──────────────────────────────────────────────────\n"; }

_bar() {   # _bar current total label detail
  [ -t 1 ] || return
  local n=$1 t=$2 lbl="$3" det="${4:-}"
  local w=22 filled=0 bar=''
  [ "$t" -gt 0 ] && filled=$(( n * w / t ))
  for ((i=0; i<w; i++)); do
    [ $i -lt $filled ] && bar+='█' || bar+='░'
  done
  local tw=${#t}
  printf "\r  %-10s  [${_C}%s${_N}]  %${tw}d/%${tw}d  %.36s\033[K" \
    "$lbl" "$bar" "$n" "$t" "$det"
}

fmt_size() {
  local mb
  mb=$(echo "scale=1; ${1:-0} / 1048576" | bc 2>/dev/null || echo "0")
  if [ "$(echo "$mb >= 1024" | bc 2>/dev/null)" = "1" ]; then
    echo "$(echo "scale=2; $mb / 1024" | bc) GB"
  else
    echo "${mb} MB"
  fi
}

fmt_dur() {
  local s=$1
  [ "$s" -ge 60 ] && echo "$((s/60))m $((s%60))s" || echo "${s}s"
}

# ===== SPINNER =====
_SPINNER_PID=""
_spinner_loop() {
  local msg="$1" i=0
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while true; do
    printf "\r  ${_D}%s${_N}  %s\033[K" "${frames[$((i % 10))]}" "$msg"
    sleep 0.08; ((i++))
  done
}
start_spinner() { [ -t 1 ] || return; _spinner_loop "$1" & _SPINNER_PID=$!; }
stop_spinner() {
  [ -z "$_SPINNER_PID" ] && return
  kill "$_SPINNER_PID" 2>/dev/null; wait "$_SPINNER_PID" 2>/dev/null
  printf "\r\033[K"; _SPINNER_PID=""
}
trap 'stop_spinner' EXIT

send_telegram() {
  [ -z "$TELEGRAM_BOT_TOKEN" ] && return
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" -d text="$1" \
    -d parse_mode="Markdown" >/dev/null 2>&1
}

# ===== TAILSCALE =====
_sec "📲" "Android Sync"

ensure_tailscale() {
  [ -z "$ANDROID_TAILSCALE_IP" ] && return
  if ! "$TAILSCALE" status >/dev/null 2>&1; then
    _log "starting Tailscale..."
    "$TAILSCALE" up >/dev/null 2>&1 &
    open -a Tailscale 2>/dev/null
    start_spinner "Starting Tailscale..."
    for i in $(seq 1 30); do
      sleep 1
      if "$TAILSCALE" status >/dev/null 2>&1; then
        stop_spinner
        _ok "Tailscale connected"
        _log "Tailscale connected"
        return
      fi
    done
    stop_spinner
    _warn "Tailscale did not connect in time"
    _log "Tailscale did not connect in time"
  else
    _ok "Tailscale running"
    _log "Tailscale already running"
  fi
}

ensure_tailscale

# ===== CONNECT TO ANDROID =====
# Android blocks incoming TCP on WiFi; Tailscale uses WireGuard (UDP) and
# establishes a direct P2P path on the same network — same speed as raw local.
ANDROID_IP=""
SYNC_METHOD=""

try_ssh() {
  nc -z -G 2 "$1" "$ANDROID_SSH_PORT" 2>/dev/null || return 1
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ServerAliveInterval=3 \
      -o ServerAliveCountMax=1 -o BatchMode=yes \
      -p "$ANDROID_SSH_PORT" "$ANDROID_SSH_USER@$1" "echo ok" >/dev/null 2>&1
}

find_android() {
  _log "connecting to Android..."
  [ -z "$ANDROID_TAILSCALE_IP" ] && { _err "No Tailscale IP configured"; return 1; }
  start_spinner "Connecting to Android..."
  if try_ssh "$ANDROID_TAILSCALE_IP"; then
    stop_spinner
    ANDROID_IP="$ANDROID_TAILSCALE_IP"
    SYNC_METHOD="tailscale"
    _ok "Connected  ·  $ANDROID_IP"
    _log "connected via Tailscale SSH at $ANDROID_IP"
    return 0
  fi
  stop_spinner
  _err "Could not reach Android — is Tailscale running on the phone?"
  _log "Tailscale SSH failed"
  return 1
}

if ! find_android; then
  _log "exiting — no device found"
  exit 0
fi

# ===== COLLECT FILES TO PUSH =====
shopt -s nullglob
push_files=()
for f in "$EXPORT_DIR"/*.HEIC "$EXPORT_DIR"/*.heic \
         "$EXPORT_DIR"/*.JPG  "$EXPORT_DIR"/*.jpg  \
         "$EXPORT_DIR"/*.PNG  "$EXPORT_DIR"/*.png  \
         "$EXPORT_DIR"/*.MOV  "$EXPORT_DIR"/*.mov  \
         "$EXPORT_DIR"/*.MP4  "$EXPORT_DIR"/*.mp4  \
         "$EXPORT_DIR"/*.TIFF "$EXPORT_DIR"/*.tiff; do
  filename=$(basename "$f")
  if grep -qxF "$filename" "$MANIFEST" 2>/dev/null; then
    rm -f "$f"
  else
    push_files+=("$f")
  fi
done
shopt -u nullglob
touch "$MANIFEST"

total_push=${#push_files[@]}
if [ "$total_push" -eq 0 ]; then
  _ok "Nothing to push — already up to date"
  _log "nothing to push"
  exit 0
fi

_info "$total_push file(s) to push"
_log "$total_push files to push"

# ===== PUSH FILES =====
synced=0
failed=0
total_bytes=0

push_file() {
  scp -q -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -o ServerAliveInterval=3 -o ServerAliveCountMax=1 -o BatchMode=yes \
      -P "$ANDROID_SSH_PORT" "$1" \
      "${ANDROID_SSH_USER}@${ANDROID_IP}:/sdcard/DCIM/$2" 2>/dev/null
}

get_free_space() {
  ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
      -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
      "$ANDROID_SSH_USER@$ANDROID_IP" \
      "df /data 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null
}

for f in "${push_files[@]}"; do
  filename=$(basename "$f")
  file_bytes=$(stat -f%z "$f" 2>/dev/null || echo 0)
  _bar $((synced + failed + 1)) "$total_push" "Pushing" "$filename"
  _log "pushing $filename ($file_bytes bytes)"

  if push_file "$f" "$filename"; then
    echo "$filename" >> "$MANIFEST"
    total_bytes=$((total_bytes + file_bytes))
    rm -f "$f"
    ((synced++))
    _log "✓ $filename"
  else
    _log "retrying $filename..."
    sleep 1
    if push_file "$f" "$filename"; then
      echo "$filename" >> "$MANIFEST"
      total_bytes=$((total_bytes + file_bytes))
      rm -f "$f"
      ((synced++))
      _log "✓ $filename (retry)"
    else
      ((failed++))
      _log "✗ $filename FAILED"
    fi
  fi
done

# ===== SUMMARY =====
if [ "$synced" -gt 0 ]; then
  ssh -o ConnectTimeout=5 -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
      -o BatchMode=yes -p "$ANDROID_SSH_PORT" \
      "$ANDROID_SSH_USER@$ANDROID_IP" \
      "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file:///sdcard/DCIM/'" >/dev/null 2>&1

  free_kb=$(get_free_space)
  free_gb=$(echo "scale=1; ${free_kb:-0} / 1048576" | bc)
  sz=$(fmt_size "$total_bytes")
  elapsed=$(fmt_dur $((SECONDS - START_TIME)))

  _ok "$synced pushed  ·  $sz  ·  ${free_gb} GB free on device"
  [ "$failed" -gt 0 ] && _warn "$failed failed"
  _sep
  _ok "Sync complete  ·  ${elapsed}"
  _log "done: $synced pushed, $failed failed, $sz, ${elapsed}"

  msg="📸 *Sync complete*
${synced} files synced to Android (${sz}) via Tailscale 🌐
📱 Free space: ${free_gb} GB"
  [ "$failed" -gt 0 ] && msg="${msg}
⚠️ ${failed} failed"
  send_telegram "$msg"
fi

# ===== CLEANUP IF LOW ON SPACE =====
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
    _log "deleted $oldest (low space cleanup)"
  done

  final_free_kb=$(get_free_space)
  final_free_gb=$(echo "scale=1; ${final_free_kb:-0} / 1048576" | bc)
  _warn "Storage cleanup ran  ·  ${final_free_gb} GB free now"
  _log "storage cleanup done, free: ${final_free_gb} GB"
  send_telegram "⚠️ *Storage cleanup*
Deleted old files to free space
📱 Free space now: ${final_free_gb} GB"
fi
