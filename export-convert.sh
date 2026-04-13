#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.sh"
if [ ! -f "$CONFIG" ]; then
  echo "Error: config.sh not found. Run ./setup.sh first." >&2
  exit 1
fi
source "$CONFIG"

PMD3="$PMD3_VENV/bin/pymobiledevice3"
MANIFEST="$EXPORT_DIR/.synced-manifest"
LOG="/tmp/photos-sync.log"
START_TIME=$SECONDS

# ===== UI =====
if [ -t 1 ]; then
  _B=$'\033[1m' _D=$'\033[2m' _G=$'\033[0;32m' _Y=$'\033[1;33m'
  _R=$'\033[0;31m' _C=$'\033[0;36m' _N=$'\033[0m'
else
  _B='' _D='' _G='' _Y='' _R='' _C='' _N=''
fi

_log()  { echo "$(date): [export] $*" >> "$LOG"; }
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

# ===== LOG CLEANUP (keep last 7 days) =====
python3 - <<'PYEOF' 2>/dev/null
import re, time, os
log = '/tmp/photos-sync.log'
if not os.path.exists(log): exit()
cutoff = time.time() - 7 * 86400
kept = []
for line in open(log):
    m = re.match(r'^(\w{3} \w{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \S+ \d{4}):', line)
    if m:
        try:
            parts = m.group(1).split()
            date_no_tz = f"{parts[0]} {parts[1]} {parts[2]} {parts[3]} {parts[5]}"
            ts = time.mktime(time.strptime(date_no_tz, '%a %b %d %H:%M:%S %Y'))
            if ts >= cutoff: kept.append(line)
        except: kept.append(line)
    else: kept.append(line)
with open(log, 'w') as f: f.writelines(kept)
PYEOF

mkdir -p "$EXPORT_DIR"
touch "$MANIFEST"

# ===== COUNTERS =====
sony_count=0 sony_failed=0 sony_bytes=0
count=0 failed=0 total_bytes=0 live_count=0 live_failed=0

# ===== SONY SD CARD =====
for vol in /Volumes/*/; do
  clip_dir="${vol}PRIVATE/M4ROOT/CLIP"
  [ -d "$clip_dir" ] || continue

  vol_name=$(basename "$vol")
  _log "Sony SD card found at $vol"
  _sec "🎥" "Sony FX30  ·  $vol_name"

  shopt -s nullglob
  all_mp4s=("$clip_dir"/*.MP4 "$clip_dir"/*.mp4)
  shopt -u nullglob

  new_mp4s=()
  for f in "${all_mp4s[@]}"; do
    fname=$(basename "$f")
    grep -qxF "$fname" "$MANIFEST" 2>/dev/null || new_mp4s+=("$f")
  done

  total_mp4=${#new_mp4s[@]}
  if [ "$total_mp4" -eq 0 ]; then
    _ok "No new clips"
    _log "no new clips on $vol_name"
    continue
  fi

  _info "$total_mp4 new clip(s) to copy"
  _log "$total_mp4 new clips to copy from $vol_name"
  i=0
  for f in "${new_mp4s[@]}"; do
    fname=$(basename "$f")
    ((i++))
    _bar "$i" "$total_mp4" "Copying" "$fname"
    if cp "$f" "$EXPORT_DIR/$fname"; then
      echo "$fname" >> "$MANIFEST"
      fsize=$(stat -f%z "$EXPORT_DIR/$fname" 2>/dev/null || echo 0)
      sony_bytes=$((sony_bytes + fsize))
      ((sony_count++))
      _log "copied $fname"
    else
      ((sony_failed++))
      _log "FAILED to copy $fname"
    fi
  done

  _ok "$sony_count clip(s) copied  ·  $(fmt_size "$sony_bytes")"
  [ "$sony_failed" -gt 0 ] && _warn "$sony_failed failed"
  _log "Sony SD: $sony_count copied, $sony_failed failed"
done

# ===== IPHONE =====
_sec "📱" "iPhone"
start_spinner "Looking for iPhone..."
usb_list=$("$PMD3" usbmux list 2>/dev/null)
stop_spinner

if ! echo "$usb_list" | grep -q '"ConnectionType": "USB"'; then
  _info "No iPhone connected via USB"
  _log "no iPhone found via USB"
else
  UDID=$(echo "$usb_list" | python3 -c "
import json, sys
devs = json.load(sys.stdin)
for d in devs:
    if d.get('ConnectionType') == 'USB' and d.get('DeviceClass') == 'iPhone':
        print(d['UniqueDeviceID'])
        break
")

  if [ -z "$UDID" ]; then
    _info "No iPhone UDID found"
    _log "no iPhone UDID"
  else
    _ok "Found  (${UDID:0:8}...)"
    _log "iPhone UDID=${UDID:0:8}"

    start_spinner "Reading DCIM..."
    iphone_files=$("$PMD3" afc ls --udid "$UDID" -r /DCIM 2>/dev/null | grep -E '/[0-9]+APPLE/' | sed 's|^/DCIM/||')
    stop_spinner

    new_files=()
    while IFS= read -r fpath; do
      [ -z "$fpath" ] && continue
      filename=$(basename "$fpath")
      grep -qxF "$filename" "$MANIFEST" 2>/dev/null || new_files+=("$fpath")
    done <<< "$iphone_files"

    total=${#new_files[@]}
    if [ "$total" -eq 0 ]; then
      _ok "Already up to date"
      _log "no new files on iPhone"
    else
      _info "$total new file(s) to pull"
      _log "$total new files to pull"

      for fpath in "${new_files[@]}"; do
        filename=$(basename "$fpath")
        _bar $((count + failed + 1)) "$total" "Pulling" "$filename"
        if "$PMD3" afc pull --udid "$UDID" -i "/DCIM/$fpath" "$EXPORT_DIR/$filename" >/dev/null 2>&1; then
          echo "$filename" >> "$MANIFEST"
          fsize=$(stat -f%z "$EXPORT_DIR/$filename" 2>/dev/null || echo 0)
          total_bytes=$((total_bytes + fsize))
          ((count++))
          _log "pulled $filename"
        else
          ((failed++))
          _log "FAILED $filename"
        fi
      done

      _ok "$count pulled  ·  $(fmt_size "$total_bytes")"
      [ "$failed" -gt 0 ] && _warn "$failed failed"

      # ===== MERGE LIVE PHOTOS =====
      shopt -s nullglob
      live_pairs=()
      for heic in "$EXPORT_DIR"/*.HEIC "$EXPORT_DIR"/*.heic; do
        [ -f "$heic" ] || continue
        base="${heic%.*}"
        { [ -f "${base}.MOV" ] || [ -f "${base}.mov" ]; } && live_pairs+=("$heic")
      done
      shopt -u nullglob

      live_total=${#live_pairs[@]}
      if [ "$live_total" -gt 0 ]; then
        _info "$live_total Live Photo pair(s) to merge"
        _log "merging $live_total live photo pairs"
        live_idx=0

        for heic in "${live_pairs[@]}"; do
          base="${heic%.*}"
          name=$(basename "$base")
          mov=""
          [ -f "${base}.MOV" ] && mov="${base}.MOV"
          [ -f "${base}.mov" ] && mov="${base}.mov"
          ((live_idx++))
          _bar "$live_idx" "$live_total" "Merging" "${name}.jpg"

          output="${EXPORT_DIR}/${name}.jpg"
          tmp_jpg="/tmp/${name}_lp.jpg"
          tmp_mp4="/tmp/${name}_lp.mp4"

          # Detect HDR: TransferCharacteristics 16=PQ (HDR10), 18=HLG
          transfer=$(exiftool -TransferCharacteristics -s3 "$heic" 2>/dev/null | tr -d ' ')
          profile_desc=$(exiftool -ProfileDescription -s3 "$heic" 2>/dev/null)
          is_hdr=false
          { [ "$transfer" = "16" ] || [ "$transfer" = "18" ]; } && is_hdr=true
          echo "$profile_desc" | grep -qiE "hlg|pq|bt\.?2020|dolby" && is_hdr=true

          if $is_hdr; then
            _log "$name: HDR — keeping HEIC+MOV separate"
            continue
          fi

          if ! sips -s format jpeg "$heic" --out "$tmp_jpg" >/dev/null 2>&1; then
            ((live_failed++)); rm -f "$tmp_jpg"
            _log "HEIC→JPEG failed: $name"; continue
          fi
          if ! ffmpeg -i "$mov" -vcodec libx264 -acodec aac \
              -movflags +faststart -y "$tmp_mp4" >/dev/null 2>&1; then
            ((live_failed++)); rm -f "$tmp_jpg" "$tmp_mp4"
            _log "MOV→MP4 failed: $name"; continue
          fi

          cat "$tmp_jpg" "$tmp_mp4" > "$output"
          mp4_bytes=$(wc -c < "$tmp_mp4" | tr -d ' ')
          exiftool -overwrite_original \
            -XMP-GCamera:MotionPhoto=1 \
            -XMP-GCamera:MotionPhotoVersion=1 \
            -XMP-GCamera:MotionPhotoPresentationTimestampUs=-1 \
            "-XMP-GCamera:MicroVideoOffset=${mp4_bytes}" \
            "$output" >/dev/null 2>&1
          rm -f "$heic" "$mov" "$tmp_jpg" "$tmp_mp4"
          ((live_count++))
          _log "merged $name"
        done

        _ok "$live_count motion photo(s) merged"
        [ "$live_failed" -gt 0 ] && _warn "$live_failed merge(s) failed"
        _log "live photos: $live_count merged, $live_failed failed"
      fi
    fi
  fi
fi

# ===== SUMMARY =====
total_imported=$((count + sony_count))
total_imported_bytes=$((total_bytes + sony_bytes))
elapsed=$(fmt_dur $((SECONDS - START_TIME)))

if [ "$total_imported" -gt 0 ]; then
  _sep
  _ok "${total_imported} files  ·  $(fmt_size "$total_imported_bytes")  ·  ${elapsed}"
  _log "done: $total_imported files, $(fmt_size "$total_imported_bytes"), ${elapsed}"

  msg=""
  if [ "$count" -gt 0 ]; then
    msg="📱 *iPhone import*
${count} new files ($(fmt_size "$total_bytes"))"
    [ "$live_count" -gt 0 ] && msg="${msg}
✨ ${live_count} live photo(s) merged"
    [ "$failed" -gt 0 ]     && msg="${msg}
⚠️ ${failed} failed"
    [ "$live_failed" -gt 0 ] && msg="${msg}
⚠️ ${live_failed} live merge(s) failed"
  fi
  if [ "$sony_count" -gt 0 ]; then
    [ -n "$msg" ] && msg="${msg}
"
    msg="${msg}🎥 *Sony FX30 import*
${sony_count} clip(s) ($(fmt_size "$sony_bytes"))"
    [ "$sony_failed" -gt 0 ] && msg="${msg}
⚠️ ${sony_failed} failed"
  fi
  send_telegram "$msg"
fi
