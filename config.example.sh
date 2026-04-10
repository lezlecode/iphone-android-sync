# iphone-android-sync configuration
# Copy this file to config.sh and fill in your values.
# Run ./setup.sh to have this done automatically.

# Where files from iPhone are staged before pushing to Android
EXPORT_DIR="$HOME/Pictures/photos-export"

# Path to the pymobiledevice3 virtual environment (setup.sh creates this)
PMD3_VENV="$HOME/.local/pmd3-venv"

# Telegram bot notifications — leave both empty to disable
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Android SSH settings (Termux / OpenSSH)
ANDROID_SSH_USER="u0_a32"   # find yours: run `id` in Termux
ANDROID_SSH_PORT="8022"
ANDROID_TAILSCALE_IP=""     # 100.x.x.x from Tailscale admin panel

# Your home WiFi network name (SSID).
# When connected to this network, Tailscale is left alone.
# On any other network, Tailscale is auto-started before syncing.
HOME_WIFI_SSID=""            # e.g. "MyHomeNetwork"

# Minimum free space to keep on Android before old DCIM files are deleted
ANDROID_MIN_FREE_KB=$((15 * 1024 * 1024))   # 15 GB
