#!/bin/sh
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer with sudo." >&2
    exit 1
fi
setup_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/usr/bin/python3 "$setup_dir/idle-suspend.py" --check
install -d -o root -g root -m 755 /usr/local/lib/idle-suspend
install -o root -g root -m 644 "$setup_dir/idle-suspend.py" /usr/local/lib/idle-suspend/idle-suspend.py
install -o root -g root -m 644 "$setup_dir/idle-suspend.service" /etc/systemd/system/idle-suspend.service
systemctl unmask sleep.target suspend.target
systemctl daemon-reload
systemctl enable idle-suspend.service
systemctl restart idle-suspend.service
systemctl --no-pager status idle-suspend.service
