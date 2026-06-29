#!/bin/sh
# Remove any orphaned .dist-info from prior failed installs
echo $password | sudo -S rm -rf /usr/local/lib/python3.11/dist-packages/Adafruit_PureIO* \
                                /usr/local/lib/python3.11/dist-packages/Adafruit_GPIO* \
                                /usr/local/lib/python3.11/dist-packages/Adafruit_SSD1306* \
                                /usr/local/lib/python3.11/dist-packages/adafruit* \
                                /usr/local/lib/python3.11/dist-packages/pidisplay*
echo $password | sudo -S rm -rf /root/.cache/pip

set -e
password=$1

# Determine the real user (works whether script is run as sudo or with password arg)
USER_NAME=$(logname 2>/dev/null || echo "$SUDO_USER" || echo "$USER")

# Install system dependencies
echo $password | sudo -S apt-get update
echo $password | sudo -S apt install -y python3-pil python3-smbus python3-pip i2c-tools

# Pre-install Python deps with modern pip (bypasses the broken easy_install path
# that Adafruit_SSD1306's old setup.py uses on modern setuptools)
echo $password | sudo -S pip install Adafruit_SSD1306 Adafruit-GPIO --break-system-packages

# Install pidisplay itself with pip instead of the deprecated setup.py install
echo $password | sudo -S pip install . --break-system-packages

# Enable I2C (bypass raspi-config which fails silently on some Bookworm config.txt variants)
CONFIG_PATH=/boot/firmware/config.txt
[ ! -f $CONFIG_PATH ] && CONFIG_PATH=/boot/config.txt

# Uncomment dtparam=i2c_arm=on if it's commented
echo $password | sudo -S sed -i 's/^#\s*dtparam=i2c_arm=on/dtparam=i2c_arm=on/' $CONFIG_PATH

# If the line isn't present at all, append it under [all]
if ! grep -q '^dtparam=i2c_arm=on' $CONFIG_PATH; then
    echo $password | sudo -S sh -c "echo 'dtparam=i2c_arm=on' >> $CONFIG_PATH"
fi

# Load the module for the current session too (no reboot needed for immediate use)
echo $password | sudo -S modprobe i2c-dev

# Ensure i2c-dev is in /etc/modules so it loads on every boot
echo $password | sudo -S sh -c "grep -q '^i2c-dev' /etc/modules || echo 'i2c-dev' >> /etc/modules"

# Verify before continuing — fail loudly if the edit didn't work
if ! grep -q '^dtparam=i2c_arm=on' $CONFIG_PATH; then
    echo "ERROR: Failed to enable I2C in $CONFIG_PATH"
    echo "Current contents:"
    grep -i i2c $CONFIG_PATH || echo "  (no i2c lines found)"
    exit 1
fi


# Write systemd service file directly.
cat > picard_display.service <<EOF
[Unit]
Description=JetCard display service
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/bin/sh -c 'python3 -m pidisplay.display_server'
Restart=on-failure
RestartSec=3
User=${USER_NAME}
WorkingDirectory=/home/${USER_NAME}

[Install]
WantedBy=multi-user.target
EOF

# Defensive: unmask in case a previous failed install left a 0-byte masked unit
echo $password | sudo -S systemctl unmask picard_display.service 2>/dev/null || true

# Install and start the service
echo $password | sudo -S mv picard_display.service /etc/systemd/system/picard_display.service
echo $password | sudo -S systemctl daemon-reload
echo $password | sudo -S systemctl enable picard_display
echo $password | sudo -S systemctl start picard_display

echo ""
echo "Install complete. Reboot for I2C changes to take effect:"
echo "  sudo reboot"