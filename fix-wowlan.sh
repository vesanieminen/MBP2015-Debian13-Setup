#!/bin/bash
set -euo pipefail

if (( EUID != 0 )); then
  exec sudo bash "$0" "$@"
fi

backup_dir=$(mktemp -d /etc/systemd/wowlan-backup.XXXXXX)
for path in /etc/systemd/system/wowlan.service /usr/local/sbin/enable-wowlan /usr/lib/systemd/system-sleep/enable-wowlan; do
  if [[ -e "$path" ]]; then
    cp -a --parents "$path" "$backup_dir/"
  fi
done

install -d /usr/local/sbin /usr/lib/systemd/system-sleep
cat > /usr/local/sbin/enable-wowlan <<'SCRIPT'
#!/bin/sh
set -eu
device=/sys/class/net/wlp4s0
phy_path=$(readlink -f "$device/phy80211")
phy=${phy_path##*/}
test -n "$phy"
echo enabled > "$device/device/power/wakeup"
/usr/sbin/iw phy "$phy" wowlan enable magic-packet
SCRIPT
chmod 755 /usr/local/sbin/enable-wowlan

cat > /usr/lib/systemd/system-sleep/enable-wowlan <<'SCRIPT'
#!/bin/sh
if [ "$1" = pre ]; then
  exec /usr/local/sbin/enable-wowlan
fi
SCRIPT
chmod 755 /usr/lib/systemd/system-sleep/enable-wowlan

cat > /etc/systemd/system/wowlan.service <<'UNIT'
[Unit]
Description=Enable Wi-Fi wake by magic packet on the current radio
Requires=sys-subsystem-net-devices-wlp4s0.device
After=sys-subsystem-net-devices-wlp4s0.device network.target headless-power.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/enable-wowlan
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable wowlan.service
systemctl restart wowlan.service
phy_path=$(readlink -f /sys/class/net/wlp4s0/phy80211)
/usr/sbin/iw phy "${phy_path##*/}" wowlan show
printf '\nPrevious files backed up in %s\n' "$backup_dir"
