#!/bin/bash
# Install UPM helper script

USER="$(id -un)"
if [ "$USER" = "root" ] && [ -n "$SUDO_USER" ]; then
  USER="$SUDO_USER"
fi
USER_HOME=$(getent passwd "$USER" | cut -d: -f6)
USM_BIN="${USER_HOME}/.local/bin/usm-cli.sh"
HAS_USM="false"
[ -x "$USM_BIN" ] && HAS_USM="true"

if [ "$HAS_USM" != "true" ]; then
  if [ -d "uConsole-Screen-Manager" ]; then
    cd uConsole-Screen-Manager && git pull
  else
    git clone https://github.com/uConsole-Labs/uConsole-Screen-Manager.git
    cd uConsole-Screen-Manager
  fi
  ./install.sh
fi
