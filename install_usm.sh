#!/bin/bash
# Install UPM helper script

if [ ! -x "$HOME/.local/bin/usm-cli.sh" ]; then
  git clone https://github.com/uConsole-Labs/uConsole-Screen-Manager.git
  cd uConsole-Screen-Manager && ./install.sh
fi
