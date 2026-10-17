#!/bin/bash
set -euo pipefail

if (( EUID != 0 )); then
  exec sudo bash "$0" "$@"
fi

unit=/etc/systemd/system/headless-power.service
cp -a "$unit" "$unit.backup-$(date +%Y%m%d-%H%M%S)"
# A service ordered before WoWLAN cannot also wait for multi-user.target:
# the target itself waits for WoWLAN. The power script handles GPU readiness.
sed -i '/^After=multi-user\.target$/d' "$unit"
systemctl daemon-reload
systemctl start headless-power.service
systemctl --no-pager -l status headless-power.service
printf '\nBacklight brightness (expected 0):\n'
cat /sys/class/backlight/gmux_backlight/brightness
cat /sys/class/backlight/gmux_backlight/actual_brightness
