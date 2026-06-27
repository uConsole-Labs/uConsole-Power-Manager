#!/bin/bash

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
if ! command -v evtest >/dev/null 2>&1 || ! command -v i2cset >/dev/null 2>&1
then
  echo "Missing dependencies: evtest and/or i2c-tools."
  read -p "Do you want to install them via apt-get now? [Y/n] " do_apt
  if [[ ! "$do_apt" =~ ^[Nn]$ ]]; then
    apt-get update
    apt-get install evtest i2c-tools
  else
    echo "Skipping apt-get installation."
  fi

  if ! command -v evtest >/dev/null 2>&1 || ! command -v i2cset >/dev/null 2>&1
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
    echo "$(date '+%Y-%m-%d %H:%M:%S') [UCS] [ERROR] $err_msg"
    exit 1
  fi
fi

echo "Installing files..."
mkdir -p /etc
cp conf/ucs.conf /etc/ucs.conf
cp VERSION /etc/ucs.version

mkdir -p /etc/ucs/hooks
cp src/hooks/ucs_hook_*.sh /etc/ucs/hooks/
chmod +x /etc/ucs/hooks/*.sh

cp src/ucs-cli.sh /usr/local/bin/ucs
chmod +x /usr/local/bin/ucs

echo "Installing systemd service..."
cp systemd/ucs.service /etc/systemd/system/
systemctl daemon-reload
/usr/local/bin/ucs enable

echo "Generating uninstaller..."
cat > /usr/local/bin/ucs-uninstall << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ucs-uninstall)"
  exit 1
fi
echo "Stopping and disabling service..."
/usr/local/bin/ucs disable
rm -f /etc/systemd/system/ucs.service
systemctl daemon-reload
echo "Removing files..."
rm -rf /etc/ucs
rm -f /usr/local/bin/ucs
rm -f /etc/ucs.conf
rm -f /etc/ucs.version
rm -f /usr/local/bin/ucs-uninstall
echo "Uninstall complete."
EOF
chmod +x /usr/local/bin/ucs-uninstall

echo ""
echo "Installation complete!"
echo "The service is enabled to auto-start on boot."
read -p "Do you want to START the service right now? [y/N] " do_start
if [[ "$do_start" =~ ^[Yy]$ ]]; then
  echo "Starting background service..."
  /usr/local/bin/ucs start
else
  echo "Service start skipped. (Start later by running 'ucs start')"
fi
