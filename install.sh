#!/bin/bash

# UPM Installer.

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo bash install.sh)"
  exit 1
fi

# CM5 Hardware Check
if [ -f "/proc/device-tree/model" ]; then
  MODEL_NAME=$(tr -d '\0' < /proc/device-tree/model)
  if [[ "$MODEL_NAME" != *"Compute Module 5"* ]]; then
    echo "ERROR: This tool is exclusively designed for the Compute Module 5."
    echo "Detected hardware: $MODEL_NAME"
    echo "Installation aborted."
    exit 1
  fi
else
  echo "ERROR: Cannot read /proc/device-tree/model. Installation aborted."
  exit 1
fi

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

echo "Checking for input device locks..."
ev_dev=""
for dev in /dev/input/by-path/*; do
  if [[ "$dev" == *"axp221-pek"* ]]; then
    ev_dev="$dev"
    break
  fi
done

if [ -n "$ev_dev" ]; then
  out=$(timeout 0.1 evtest --grab "$ev_dev" 2>&1)
  if [[ "$out" == *"grabbed by another process"* ]]; then
    err_msg="Input device is locked by another program (EVIOCGRAB)."
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UPM] [ERROR] $err_msg"
    exit 1
  fi
fi

echo "Installing files..."
mkdir -p /etc
cp conf/upm.conf /etc/upm.conf
cp VERSION /etc/upm.version

mkdir -p /etc/upm/hooks
cp src/hooks/upm_hook_*.sh /etc/upm/hooks/
chmod +x /etc/upm/hooks/*.sh

cp src/upm-cli.sh /usr/local/bin/upm
chmod +x /usr/local/bin/upm

echo "Installing systemd services..."
cp systemd/upm_*.service /etc/systemd/system/
systemctl daemon-reload
/usr/local/bin/upm enable

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
rm -f /usr/local/bin/upm
rm -f /etc/upm.conf
rm -f /etc/upm.version
rm -f /usr/local/bin/upm-uninstall
echo "Uninstall complete."
EOF
chmod +x /usr/local/bin/upm-uninstall

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
