#!/bin/bash

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo bash install.sh)"
    exit 1
fi

echo "Installing dependencies..."
apt-get update
apt-get install -y evtest i2c-tools

echo "Installing files..."
mkdir -p /etc
cp conf/ucs.conf /etc/ucs.conf
cp VERSION /etc/ucs.version

cp src/ucs-cli.sh /usr/local/bin/ucs
chmod +x /usr/local/bin/ucs

echo "Installing systemd service..."
cp systemd/ucs.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ucs.service

echo "Generating uninstaller..."
cat > /usr/local/bin/ucs-uninstall << 'EOF'
#!/bin/bash
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ucs-uninstall)"
    exit 1
fi

echo "Stopping and disabling service..."
systemctl disable --now ucs.service
rm -f /etc/systemd/system/ucs.service
systemctl daemon-reload

echo "Removing files..."
rm -f /usr/local/bin/ucs
rm -f /etc/ucs.conf
rm -f /etc/ucs.version
rm -f /usr/local/bin/ucs-uninstall

echo "Uninstall complete."
EOF
chmod +x /usr/local/bin/ucs-uninstall

echo "Installation complete! Try running 'ucs status'."
