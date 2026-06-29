#!/bin/sh
set -e
password=$1

# Determine the real user (works whether script is run as sudo or with password arg)
USER_NAME=$(logname 2>/dev/null || echo "$SUDO_USER" || echo "$USER")

# Remove any state from previous failed installs. Failures here will stop the script.
echo $password | sudo -S rm -rf \
    /usr/local/lib/python3.11/dist-packages/Adafruit_PureIO* \
    /usr/local/lib/python3.11/dist-packages/Adafruit_GPIO* \
    /usr/local/lib/python3.11/dist-packages/Adafruit_SSD1306* \
    /usr/local/lib/python3.11/dist-packages/adafruit* \
    /usr/local/lib/python3.11/dist-packages/pidisplay*
echo $password | sudo -S rm -rf /root/.cache/pip

# Remove any existing masked or broken service file before installing
echo $password | sudo -S systemctl unmask picard_display.service 2>/dev/null || true
echo $password | sudo -S rm -f /etc/systemd/system/picard_display.service

# Install system dependencies
echo $password | sudo -S apt-get update
echo $password | sudo -S apt install -y python3-pil python3-smbus python3-pip i2c-tools

# Pre-install Python deps with modern pip
echo $password | sudo -S pip install Adafruit_SSD1306 Adafruit-GPIO --break-system-packages

# Install pidisplay itself
echo $password | sudo -S pip install . --break-system-packages

# Enable I2C
CONFIG_PATH=/boot/firmware/config.txt
[ ! -f $CONFIG_PATH ] && CONFIG_PATH=/boot/config.txt

echo $password | sudo -S sed -i 's/^#\s*dtparam=i2c_arm=on/dtparam=i2c_arm=on/' $CONFIG_PATH
if ! grep -q '^dtparam=i2c_arm=on' $CONFIG_PATH; then
    echo $password | sudo -S sh -c "echo 'dtparam=i2c_arm=on' >> $CONFIG_PATH"
fi
echo $password | sudo -S sh -c "grep -q '^i2c-dev' /etc/modules || echo 'i2c-dev' >> /etc/modules"

if ! grep -q '^dtparam=i2c_arm=on' $CONFIG_PATH; then
    echo "ERROR: Failed to enable I2C in $CONFIG_PATH"
    exit 1
fi

# Write the service file DIRECTLY to /etc/systemd/system in a single atomic step.
# Using `tee` instead of `cat > tmp; mv tmp` eliminates the intermediate-file risk
# that was leaving 0-byte files (which systemd treats as masked).
echo $password | sudo -S tee /etc/systemd/system/picard_display.service > /dev/null <<EOF
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

# Verify the service file is non-empty and contains expected content
if [ ! -s /etc/systemd/system/picard_display.service ] || \
   ! grep -q "ExecStart" /etc/systemd/system/picard_display.service; then
    echo "ERROR: Service file failed to write correctly:"
    ls -la /etc/systemd/system/picard_display.service
    cat /etc/systemd/system/picard_display.service
    exit 1
fi

echo $password | sudo -S systemctl daemon-reload
echo $password | sudo -S systemctl enable picard_display
echo $password | sudo -S systemctl start picard_display

echo ""
echo "Install complete. Reboot for I2C changes to take effect:"
echo "  sudo reboot"