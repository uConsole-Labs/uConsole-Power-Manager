#!/bin/bash
# UPM Hook: upm_hook_hold_2s
# Add your custom scripts below.
echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] 2s hold triggered." \
  >> /var/log/upm.log

POWER_DEV="/dev/input/by-path/platform-pwr_button-event"

if pgrep -x "pishutdown" > /dev/null; then
  echo \
    "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] pishutdown is already running. Ignoring." \
    >> /var/log/upm.log
else
    DESKTOP_USER=$(who | awk '$2 ~ /tty|:[0-9]/ {print $1}' | grep -v 'root' | head -n 1)
    if [ -n "$DESKTOP_USER" ]; then
      if ! USER_UID=$(id -u "$DESKTOP_USER" 2>/dev/null); then
        echo \
          "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] Error: Failed to get UID." \
          >> /var/log/upm.log
        return 1 2>/dev/null || exit 0
      fi
      USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
      WAYLAND_DISPLAY_SOCKET=$(ls /run/user/$USER_UID/wayland-* 2>/dev/null \
        | head -n 1 | xargs -r basename)
      sudo -u "$DESKTOP_USER" env PATH="$USER_HOME/.local/fakebin:$PATH" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY_SOCKET:-wayland-0}" \
        XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        pishutdown &
    else
      echo \
        "$(date '+%Y-%m-%d %H:%M:%S') [UPM-HOOK] Error: Desktop user not found." \
        >> /var/log/upm.log
    fi
fi
