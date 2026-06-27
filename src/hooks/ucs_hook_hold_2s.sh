#!/bin/bash
echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS-HOOK] 2s hold triggered." \
  >> /var/log/ucs.log

U=$(who | awk '$2 ~ /tty[1-7]|:[0-9]/ {print $1}' | head -1)
if [ -n "$U" ]; then
  USER_ID=$(id -u "$U")
  su - "$U" -c "
    export WAYLAND_DISPLAY=wayland-0
    export XDG_RUNTIME_DIR=/run/user/$USER_ID
    export DISPLAY=:0
    /usr/bin/pishutdown &
  "
fi
