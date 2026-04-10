# iphone-android-sync

Automatically pull photos and videos from an iPhone over USB and push them to an Android phone — over local WiFi or the internet via Tailscale.

**What it does:**
- Detects iPhone connected via USB and pulls new photos/videos
- Merges iPhone Live Photos (HEIC + MOV) into Google Motion Photos (a single JPEG Google Photos on Android recognises as a live photo)
- HDR Live Photos are kept as separate HEIC + MOV (JPEG can't hold HDR)
- Pushes files to Android over SSH — local WiFi first, Tailscale as fallback
- Automatically starts Tailscale when you're away from your home network
- Sends Telegram notifications on import and sync completion
- Can run on a schedule in the background, or manually on demand

---

## Requirements

- **Mac** with Homebrew
- **iPhone** — connected via USB, trusted on the Mac
- **Android phone** — with [Termux](https://termux.dev) and OpenSSH installed
- **Tailscale** — free account, installed on both Mac and Android (for remote sync)
- **Telegram bot** — optional, for notifications

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/YOUR_USERNAME/iphone-android-sync.git
cd iphone-android-sync
```

### 2. Run setup

```bash
chmod +x setup.sh
./setup.sh
```

The wizard will:
- Install `ffmpeg` and `exiftool` via Homebrew if missing
- Install `pymobiledevice3` in a Python virtual environment
- Ask for your Telegram bot token, Android SSH details, and Tailscale IP
- Ask for your home WiFi name (so Tailscale is only auto-started away from home)
- Generate an SSH key for Android auth (no password prompts ever)
- Install the launchd agent (disabled by default)
- Add shell commands to your `.zshrc`

After setup, reload your shell:

```bash
source ~/.zshrc
```

### 3. Set up Android (Termux)

Install the required apps on your Android phone:

1. Install [Termux](https://f-droid.org/packages/com.termux/) from F-Droid
2. Install [Termux:Boot](https://f-droid.org/packages/com.termux.boot/) from F-Droid (so SSH starts on reboot)
3. In Termux:

```bash
pkg update && pkg install openssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# Paste the public key that setup.sh printed
echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Start the SSH server now
sshd
```

4. Set up auto-start on boot — create `~/.termux/boot/start-sshd.sh`:

```bash
mkdir -p ~/.termux/boot
echo '#!/data/data/com.termux/files/usr/bin/sh' > ~/.termux/boot/start-sshd.sh
echo 'sshd' >> ~/.termux/boot/start-sshd.sh
chmod +x ~/.termux/boot/start-sshd.sh
```

5. Find your Android SSH username:

```bash
id
# Look for: uid=10032(u0_a32) — "u0_a32" is your username
```

### 4. Set up Tailscale

1. Create a free account at [tailscale.com](https://tailscale.com)
2. Install Tailscale on your Mac (if not already): `brew install --cask tailscale`
3. Install [Tailscale on Android](https://play.google.com/store/apps/details?id=com.tailscale.ipn.android) from the Play Store
4. Sign in to the same account on both devices
5. Find your Android Tailscale IP in the Tailscale admin panel (`100.x.x.x`)
6. Re-run `./setup.sh` or edit `config.sh` to add the IP

### 5. Get a Telegram bot (optional)

1. Message [@BotFather](https://t.me/BotFather) on Telegram → `/newbot`
2. Copy the bot token it gives you
3. Message your new bot, then visit:
   `https://api.telegram.org/bot<TOKEN>/getUpdates`
   to find your chat ID
4. Add both to `config.sh` or re-run `./setup.sh`

---

## Shell commands

| Command | What it does |
|---|---|
| `sync-import` | Pull new photos/videos from iPhone only |
| `sync-now` | Pull from iPhone + push to Android |
| `sync-status` | Show auto-sync state and last 5 log lines |
| `sync-enable` | Start background auto-sync every 2 min (persists across reboots) |
| `sync-disable` | Stop background auto-sync (persists across reboots) |
| `sync-clear` | Reset manifests — re-syncs everything on next run |
| `sync-log` | Show last 30 lines of the log |

---

## Auto-sync (background mode)

To run automatically every 2 minutes in the background:

```bash
sync-enable
```

> **Note:** For auto-sync to work, `/bin/bash` needs Full Disk Access:
> System Settings → Privacy & Security → Full Disk Access → add `/bin/bash`

To turn it off:

```bash
sync-disable
```

---

## How it works

### iPhone import (`export-convert.sh`)

1. Checks for a USB-connected iPhone using `pymobiledevice3`
2. Lists all files in the iPhone's DCIM folder
3. Compares against a local manifest (`.synced-manifest`) — only pulls new files
4. For each HEIC + MOV pair (Live Photo):
   - If SDR (Display P3 / sRGB): merges them into a Google Motion Photo JPEG — a single file with the MP4 appended and `XMP-GCamera` metadata, which Google Photos on Android recognises as a live photo. The HEIC colour profile is preserved.
   - If HDR (HLG / Dolby Vision): keeps HEIC and MOV separate — JPEG doesn't support HDR
5. Sends a Telegram notification with file count and transfer size

### Android sync (`android-sync.sh`)

1. If away from the home network, auto-starts Tailscale
2. Finds the Android device — cached local IP first → subnet scan (IPs 1–30) → Tailscale
3. Pushes files via SCP (shows a progress bar when run interactively)
4. Retries each file once on failure
5. Triggers a media scan so files appear in Google Photos immediately
6. Sends a Telegram notification (WiFi vs Tailscale, file count, transfer size, free space)
7. If free space drops below 15 GB, deletes the oldest DCIM files

### Manifest files

Two plain-text files track what has already been synced to avoid re-transferring:

- `$EXPORT_DIR/.synced-manifest` — filenames pulled from iPhone
- `$EXPORT_DIR/.android-synced-manifest` — filenames pushed to Android

Clear both with `sync-clear` to force a full re-sync.

---

## Configuration

All settings live in `config.sh` (gitignored — never committed). See `config.example.sh` for all available options.

Key settings:

```bash
EXPORT_DIR             # Staging folder on your Mac
TELEGRAM_BOT_TOKEN     # Telegram bot token (leave empty to disable)
TELEGRAM_CHAT_ID       # Your Telegram chat ID
ANDROID_SSH_USER       # Termux username (run `id` in Termux)
ANDROID_SSH_PORT       # Termux SSH port (default 8022)
ANDROID_TAILSCALE_IP   # Android's Tailscale IP (100.x.x.x)
HOME_WIFI_SSID         # Your home network name
```

---

## Troubleshooting

**iPhone not detected**
- Make sure you've tapped "Trust" on your iPhone when connecting
- Try: `pymobiledevice3 usbmux list`

**Android not reachable on local network**
- Check Termux SSH is running: in Termux, run `sshd`
- Test: `ssh -p 8022 u0_a32@<android-ip> "echo ok"`

**Tailscale not connecting**
- Open the Tailscale app manually and check both devices are shown as online
- Test: `tailscale ping <android-tailscale-ip>`

**Files not showing in Google Photos**
- Google Photos may take a few minutes to scan. The sync triggers a media scan automatically — open Google Photos and pull to refresh.

**Log file**
```bash
sync-log           # last 30 lines
cat /tmp/photos-sync.log   # full log (kept for 7 days)
```
