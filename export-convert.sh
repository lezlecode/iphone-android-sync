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

# ===== LOG CLEANUP (keep last 7 days) =====
python3 - <<'EOF' 2>/dev/null
import re, time, os

log = '/tmp/photos-sync.log'
if not os.path.exists(log):
    exit()

cutoff = time.time() - 7 * 86400
kept = []
for line in open(log):
    m = re.match(r'^(\w{3} \w{3}\s+\d{1,2} \d{2}:\d{2}:\d{2} \S+ \d{4}):', line)
    if m:
        try:
            parts = m.group(1).split()
            date_no_tz = f"{parts[0]} {parts[1]} {parts[2]} {parts[3]} {parts[5]}"
            ts = time.mktime(time.strptime(date_no_tz, '%a %b %d %H:%M:%S %Y'))
            if ts >= cutoff:
                kept.append(line)
        except:
            kept.append(line)
    else:
        kept.append(line)

with open(log, 'w') as f:
    f.writelines(kept)
EOF

mkdir -p "$EXPORT_DIR"
touch "$MANIFEST"

# ===== CHECK FOR SONY SD CARD =====
sony_count=0
sony_failed=0
sony_bytes=0

for vol in /Volumes/*/; do
  clip_dir="${vol}PRIVATE/M4ROOT/CLIP"
  [ -d "$clip_dir" ] || continue

  vol_name=$(basename "$vol")
  [ -t 1 ] && echo "Sony SD card found: $vol_name"
  echo "$(date): [export] Sony SD card found at $vol ($clip_dir)"

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
    [ -t 1 ] && echo "  No new clips on $vol_name."
    echo "$(date): [export] no new clips on $vol_name"
    continue
  fi

  [ -t 1 ] && echo "Copying $total_mp4 new clip(s) from $vol_name..."
  i=0
  for f in "${new_mp4s[@]}"; do
    fname=$(basename "$f")
    ((i++))
    [ -t 1 ] && echo -ne "  [$i/$total_mp4] $fname...\r"
    if cp "$f" "$EXPORT_DIR/$fname"; then
      echo "$fname" >> "$MANIFEST"
      fsize=$(stat -f%z "$EXPORT_DIR/$fname" 2>/dev/null || echo 0)
      sony_bytes=$((sony_bytes + fsize))
      ((sony_count++))
      [ -t 1 ] && printf "  [%d/%d] %-50s ✓\n" "$i" "$total_mp4" "$fname"
    else
      ((sony_failed++))
      [ -t 1 ] && printf "  [!/%d] %-50s ✗\n" "$total_mp4" "$fname"
      echo "$(date): [export] ✗ failed to copy $fname"
    fi
  done
  [ -t 1 ] && echo "Done. $sony_count copied, $sony_failed failed."
  echo "$(date): [export] Sony SD: $sony_count copied, $sony_failed failed"
done

# ===== CHECK FOR IPHONE VIA USB =====
start_spinner "Looking for iPhone..."
usb_list=$("$PMD3" usbmux list 2>/dev/null)
stop_spinner
if ! echo "$usb_list" | grep -q '"ConnectionType": "USB"'; then
  exit 0
fi

UDID=$(echo "$usb_list" | python3 -c "
import json, sys
devs = json.load(sys.stdin)
for d in devs:
    if d.get('ConnectionType') == 'USB' and d.get('DeviceClass') == 'iPhone':
        print(d['UniqueDeviceID'])
        break
")

if [ -z "$UDID" ]; then
  exit 0
fi

[ -t 1 ] && echo "  iPhone found (UDID: ${UDID:0:8}...)"

# ===== LIST FILES ON IPHONE =====
start_spinner "Reading iPhone DCIM..."
iphone_files=$("$PMD3" afc ls --udid "$UDID" -r /DCIM 2>/dev/null | grep -E '/[0-9]+APPLE/' | sed 's|^/DCIM/||')
stop_spinner

if [ -z "$iphone_files" ]; then
  exit 0
fi

# Filter out files already pulled
new_files=()
while IFS= read -r fpath; do
  filename=$(basename "$fpath")
  if ! grep -qxF "$filename" "$MANIFEST" 2>/dev/null; then
    new_files+=("$fpath")
  fi
done <<< "$iphone_files"

if [ ${#new_files[@]} -eq 0 ]; then
  exit 0
fi

# ===== PULL ONLY NEW FILES =====
count=0
failed=0
total_bytes=0
total=${#new_files[@]}
[ -t 1 ] && echo "Pulling $total new file(s) from iPhone..."
for fpath in "${new_files[@]}"; do
  filename=$(basename "$fpath")
  [ -t 1 ] && echo -ne "  [$((count + 1))/$total] $filename...\r"
  if "$PMD3" afc pull --udid "$UDID" -i "/DCIM/$fpath" "$EXPORT_DIR/$filename" >/dev/null 2>&1; then
    echo "$filename" >> "$MANIFEST"
    if [ -f "$EXPORT_DIR/$filename" ]; then
      file_bytes=$(stat -f%z "$EXPORT_DIR/$filename" 2>/dev/null || echo 0)
      total_bytes=$((total_bytes + file_bytes))
    fi
    ((count++))
    [ -t 1 ] && printf "  [%d/%d] %-50s ✓\n" "$count" "$total" "$filename"
  else
    ((failed++))
    [ -t 1 ] && printf "  [!/%d] %-50s ✗\n" "$total" "$filename"
  fi
done
[ -t 1 ] && [ "$count" -gt 0 ] && echo "Done. $count pulled, $failed failed."

# ===== MERGE LIVE PHOTO PAIRS INTO GOOGLE MOTION PHOTOS =====
# iPhone Live Photos = HEIC + MOV with matching base name.
# SDR pairs (P3/sRGB) → single JPEG with MP4 appended (Google Motion Photo format).
# HDR pairs (HLG/PQ) → kept as separate HEIC + MOV (JPEG can't hold HDR).
# Regular HEIC stills and videos are left as-is.
live_count=0
live_failed=0
shopt -s nullglob
for heic in "$EXPORT_DIR"/*.HEIC "$EXPORT_DIR"/*.heic; do
  [ -f "$heic" ] || continue
  base="${heic%.*}"
  name=$(basename "$base")

  # Only process if there's a matching MOV (= Live Photo, not a still)
  mov=""
  [ -f "${base}.MOV" ] && mov="${base}.MOV"
  [ -f "${base}.mov" ] && mov="${base}.mov"
  [ -z "$mov" ] && continue

  [ -t 1 ] && echo "  Merging live photo: $name..."

  output="${EXPORT_DIR}/${name}.jpg"
  tmp_jpg="/tmp/${name}_lp.jpg"
  tmp_mp4="/tmp/${name}_lp.mp4"

  # Detect HDR: TransferCharacteristics 16=PQ (HDR10), 18=HLG
  transfer=$(exiftool -TransferCharacteristics -s3 "$heic" 2>/dev/null | tr -d ' ')
  profile_desc=$(exiftool -ProfileDescription -s3 "$heic" 2>/dev/null)
  is_hdr=false
  if [ "$transfer" = "16" ] || [ "$transfer" = "18" ]; then
    is_hdr=true
  elif echo "$profile_desc" | grep -qiE "hlg|pq|bt\.?2020|dolby"; then
    is_hdr=true
  fi

  # HDR live photos: skip merge — HEIC+MOV pushed to Android separately
  if $is_hdr; then
    [ -t 1 ] && echo "  ~ $name: HDR — keeping HEIC + MOV separate"
    continue
  fi

  # SDR: convert HEIC → JPEG, preserving embedded colour profile (P3 or sRGB)
  if ! sips -s format jpeg "$heic" --out "$tmp_jpg" >/dev/null 2>&1; then
    [ -t 1 ] && echo "  ✗ $name: HEIC→JPEG failed"
    rm -f "$tmp_jpg"
    ((live_failed++))
    continue
  fi

  # Convert MOV → MP4 (H.264/AAC, fast-start for streaming)
  if ! ffmpeg -i "$mov" -vcodec libx264 -acodec aac \
      -movflags +faststart -y "$tmp_mp4" >/dev/null 2>&1; then
    [ -t 1 ] && echo "  ✗ $name: MOV→MP4 failed"
    rm -f "$tmp_jpg" "$tmp_mp4"
    ((live_failed++))
    continue
  fi

  # Append MP4 to JPEG — Google Motion Photo container format
  cat "$tmp_jpg" "$tmp_mp4" > "$output"
  mp4_bytes=$(wc -c < "$tmp_mp4" | tr -d ' ')

  # XMP-GCamera tags so Google Photos recognises it as a Motion Photo
  exiftool -overwrite_original \
    -XMP-GCamera:MotionPhoto=1 \
    -XMP-GCamera:MotionPhotoVersion=1 \
    -XMP-GCamera:MotionPhotoPresentationTimestampUs=-1 \
    "-XMP-GCamera:MicroVideoOffset=${mp4_bytes}" \
    "$output" >/dev/null 2>&1

  rm -f "$heic" "$mov" "$tmp_jpg" "$tmp_mp4"
  ((live_count++))
  [ -t 1 ] && echo "  ✓ ${name}.jpg (motion photo)"
done
[ -t 1 ] && [ "$live_count" -gt 0 ] && echo "Merged $live_count live photo(s) into motion photos."

# ===== TELEGRAM NOTIFICATION =====
total_imported=$((count + sony_count))
total_imported_bytes=$((total_bytes + sony_bytes))

if [ "$total_imported" -gt 0 ]; then
  size_mb=$(echo "scale=1; $total_imported_bytes / 1048576" | bc)
  if [ "$(echo "$size_mb >= 1024" | bc)" -eq 1 ]; then
    size_display="$(echo "scale=2; $size_mb / 1024" | bc) GB"
  else
    size_display="${size_mb} MB"
  fi

  msg=""
  if [ "$count" -gt 0 ]; then
    iphone_mb=$(echo "scale=1; $total_bytes / 1048576" | bc)
    [ "$(echo "$iphone_mb >= 1024" | bc)" -eq 1 ] && \
      iphone_size="$(echo "scale=2; $iphone_mb / 1024" | bc) GB" || \
      iphone_size="${iphone_mb} MB"
    msg="📱 *iPhone import*
${count} new files pulled (${iphone_size})"
    [ "$live_count" -gt 0 ] && msg="${msg}
✨ ${live_count} live photo(s) merged"
    [ "$failed" -gt 0 ] && msg="${msg}
⚠️ ${failed} failed"
    [ "$live_failed" -gt 0 ] && msg="${msg}
⚠️ ${live_failed} live photo merge(s) failed"
  fi

  if [ "$sony_count" -gt 0 ]; then
    sony_mb=$(echo "scale=1; $sony_bytes / 1048576" | bc)
    [ "$(echo "$sony_mb >= 1024" | bc)" -eq 1 ] && \
      sony_size="$(echo "scale=2; $sony_mb / 1024" | bc) GB" || \
      sony_size="${sony_mb} MB"
    [ -n "$msg" ] && msg="${msg}
"
    msg="${msg}🎥 *Sony FX30 import*
${sony_count} clip(s) copied (${sony_size})"
    [ "$sony_failed" -gt 0 ] && msg="${msg}
⚠️ ${sony_failed} failed"
  fi

  send_telegram "$msg"
fi
