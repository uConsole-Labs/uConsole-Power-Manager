#!/bin/bash
# Triggered when the power button is held for exactly 2 seconds.

echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS-HOOK] 2s hold triggered." >> /var/log/ucs.log
