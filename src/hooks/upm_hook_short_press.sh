#!/bin/bash
# UPM Hook: upm_hook_short_press
# Add your custom scripts below.

USER=$(who | awk '{print $1}' | head -n 1)
USM_BIN="/home/$USER/.local/bin/usm-cli.sh"
HAS_USM="false"
[ -x "$USM_BIN" ] && HAS_USM="true"

USER_UID=$(id -u "$USER")
XDG_DIR="/run/user/$USER_UID"
WD=$(sudo -u "$USER" find "$XDG_DIR" -maxdepth 1 -name "wayland-*" \
  ! -name "*.lock" -exec basename {} \; 2>/dev/null | head -n 1)

if [ "$HAS_USM" = "true" ]; then
  sudo -u "$USER" XDG_RUNTIME_DIR="$XDG_DIR" WAYLAND_DISPLAY="$WD" \
    "$USM_BIN" screen-switch
else
  sudo -u "$USER" XDG_RUNTIME_DIR="$XDG_DIR" WAYLAND_DISPLAY="$WD" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_DIR/bus" \
    notify-send "USM is not installed. Please run install_usm.sh."
fi
