#!/bin/bash
# UPM Hook: upm_hook_short_press
# Add your custom scripts below.

USER=$(who | awk '{print $1}' | head -n 1)
USM_BIN="/home/$USER/.local/bin/usm-cli.sh"
HAS_USM="false"
[ -x "$USM_BIN" ] && HAS_USM="true"

if [ "$HAS_USM" = "true" ]; then
  sudo -u "$USER" "$USM_BIN" screen-switch
else
  sudo -u "$USER" notify-send "USM is not installed. Please run install_usm.sh."
fi
