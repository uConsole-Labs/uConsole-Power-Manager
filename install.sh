#!/bin/bash

# UPM Installer.

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash install.sh)"
    exit 1
  fi
}

check_hardware() {
  if [ -f "/proc/device-tree/model" ]; then
    local model_name
    model_name=$(tr -d '\0' < /proc/device-tree/model)
    if [[ "$model_name" != *"Compute Module 5"* ]]; then
      echo "ERROR: This tool is exclusively designed for the Compute Module 5."
      echo "Detected hardware: $model_name"
      echo "Installation aborted."
      exit 1
    fi
  else
    echo "ERROR: Cannot read /proc/device-tree/model. Installation aborted."
    exit 1
  fi
}

check_dependencies() {
  echo "Checking dependencies..."
  if ! command -v evtest >/dev/null 2>&1 || \
     ! command -v i2cset >/dev/null 2>&1 || \
     ! command -v inotifywait >/dev/null 2>&1 || \
     ! command -v notify-send >/dev/null 2>&1 || \
     ! command -v mako >/dev/null 2>&1
  then
    echo "Missing dependencies: evtest, i2c-tools, inotify-tools,"
    echo "mako-notifier, and/or libnotify-bin."
    read -p "Do you want to install them via apt-get now? [Y/n] " do_apt
    if [[ ! "$do_apt" =~ ^[Nn]$ ]]; then
      apt-get update
      apt-get install evtest i2c-tools inotify-tools mako-notifier libnotify-bin
    else
      echo "Skipping apt-get installation."
    fi

    if ! command -v evtest >/dev/null 2>&1 || \
       ! command -v i2cset >/dev/null 2>&1 || \
       ! command -v inotifywait >/dev/null 2>&1 || \
       ! command -v notify-send >/dev/null 2>&1 || \
       ! command -v mako >/dev/null 2>&1
    then
      echo "ERROR: Required dependencies are still missing."
      echo "Installation aborted."
      exit 1
    fi
  else
    echo "Dependencies are already installed. Skipping apt-get."
  fi
}

# ==============================================================================
# check_device_locks
#
# Checks if the axp221-pek input device is locked by an existing process.
# If locked by our known service, prompts the user to stop the service.
# If locked by an unknown program, aborts the installation.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes status, warnings, or error messages to stdout.
# Returns:
#   0 on success.
#   1 on failure (e.g. unknown lock, user abort).
# ==============================================================================
check_device_locks() {
  echo "Checking for input device locks..."
  local ev_dev=""
  for dev in /dev/input/by-path/*; do
    if [[ "$dev" == *"axp221-pek"* ]]; then
      ev_dev="$dev"
      break
    fi
  done

  if [ -z "$ev_dev" ]; then
    return 0
  fi

  local out
  out=$(timeout 0.1 evtest --grab "$ev_dev" 2>&1)

  if [[ "$out" != *"grabbed by another process"* ]]; then
    return 0
  fi

  if ! systemctl is-active --quiet upm_power_key_monitor.service; then
    local err_msg="$(date '+%Y-%m-%d %H:%M:%S') [UPM] [ERROR] "
    err_msg+="Input device is locked by an unknown program (EVIOCGRAB)."
    echo "$err_msg"
    echo "Installation aborted."
    exit 1
  fi

  echo \
    "[UPM] [WARNING] Input device is locked by upm_power_key_monitor.service."

  read -p \
    "Do you want to stop the service to continue installation? [Y/n]" do_stop

  if [[ "$do_stop" =~ ^[Nn]$ ]]; then
    echo "Installation aborted."
    exit 1
  fi

  echo "Stopping upm_power_key_monitor.service..."
  systemctl stop upm_power_key_monitor.service

  out=$(timeout 0.1 evtest --grab "$ev_dev" 2>&1)
  if [[ "$out" == *"grabbed by another process"* ]]; then
    echo "ERROR: Input device is still locked. Installation aborted."
    exit 1
  fi

  echo "Service stopped and lock released. Continuing installation."
}

install_files() {
  echo "Installing files..."
  mkdir -p /etc/upm
  cp conf/upm.conf /etc/upm/upm.conf

  mkdir -p /opt/upm/hooks
  cp VERSION /opt/upm/upm.version
  cp src/hooks/upm_hook_*.sh /opt/upm/hooks/
  chmod +x /opt/upm/hooks/*.sh

  cp src/upm-cli.sh /usr/local/bin/upm
  chmod +x /usr/local/bin/upm

  if [ -n "$SUDO_USER" ]; then
    local user_home
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$user_home/.local/fakebin"
    cp src/fakebin/grep "$user_home/.local/fakebin/grep"
    chmod +x "$user_home/.local/fakebin/grep"
    chown -R "$SUDO_USER:$SUDO_USER" "$user_home/.local/fakebin"
  fi
}

install_services() {
  echo "Installing systemd services..."
  cp systemd/upm_*.service /etc/systemd/system/
  systemctl daemon-reload
  /usr/local/bin/upm enable
}

generate_uninstaller() {
  echo "Generating uninstaller..."
  cat > /usr/local/bin/upm-uninstall << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo upm-uninstall)"
  exit 1
fi
echo "Stopping and disabling service..."
/usr/local/bin/upm disable
rm -f /etc/systemd/system/upm_power_key_monitor.service
rm -f /etc/systemd/system/upm_batt_monitor.service
systemctl daemon-reload
echo "Removing files..."
rm -rf /etc/upm
rm -rf /opt/upm
rm -f /usr/local/bin/upm
if [ -n "$SUDO_USER" ]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  rm -f "$USER_HOME/.local/fakebin/grep"
fi
rm -f /usr/local/bin/upm-uninstall
echo "Uninstall complete."
EOF
  chmod +x /usr/local/bin/upm-uninstall
}

prompt_start() {
  echo ""
  echo "Installation complete!"
  echo "The service is enabled to auto-start on boot."
  read -p "Do you want to START the service right now? [y/N] " do_start
  if [[ "$do_start" =~ ^[Yy]$ ]]; then
    echo "Starting background service..."
    /usr/local/bin/upm start
  else
    echo "Service start skipped. (Start later by running 'upm start')"
  fi
}

# Execute installation
check_root
check_hardware
check_dependencies
check_device_locks
install_files
install_services
generate_uninstaller
prompt_start
