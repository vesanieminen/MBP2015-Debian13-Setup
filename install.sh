#!/bin/bash
# Headless, low-power setup for MacBook Pro 11,5 (15" mid-2015, Radeon R9 M370X) on Debian 13.
#
#   sudo ./install.sh [CHARGE_LIMIT]     (default charge limit: 60 %)
#
# Idempotent: safe to re-run, e.g. to change the charge limit.
# Measured result: idle power 18 W -> 10 W.
set -euo pipefail

CHARGE_LIMIT=${1:-60}
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
[[ $CHARGE_LIMIT =~ ^[0-9]+$ ]] && (( CHARGE_LIMIT >= 20 && CHARGE_LIMIT <= 100 )) \
  || { echo "Charge limit must be 20..100" >&2; exit 1; }
model=$(cat /sys/class/dmi/id/product_name)
[ "$model" = MacBookPro11,5 ] || echo "WARNING: written for MacBookPro11,5, this is $model"

step() { echo "== $*"; }

step "Packages"
apt-get install -y --no-install-recommends powertop python3 util-linux >/dev/null

step "Config: /etc/default/headless-power"
cat > /etc/default/headless-power <<EOF
# Battery charge limit in percent (Apple SMC key BCLM)
CHARGE_LIMIT=$CHARGE_LIMIT
EOF

step "SMC charge-limit tool: /usr/local/sbin/smc-bclm"
cat > /usr/local/sbin/smc-bclm <<'EOF'
#!/usr/bin/env python3
"""Read/write the Apple SMC battery charge limit key (BCLM) via raw port I/O,
using the same protocol as the kernel applesmc driver.
Usage: smc-bclm [PERCENT]"""
import sys, time

DATA, CMD = 0x300, 0x304
READ_CMD, WRITE_CMD = 0x10, 0x11
AWAITING_DATA, IB_CLOSED, BUSY = 0x01, 0x02, 0x04

port = open('/dev/port', 'r+b', buffering=0)

def inb(p):
    port.seek(p); return port.read(1)[0]

def outb(v, p):
    port.seek(p); port.write(bytes([v]))

def wait_status(val, mask):
    delay = 8e-6
    for _ in range(24):
        if inb(CMD) & mask == val:
            return
        time.sleep(delay)
        delay = min(delay * 2, 0.01)
    raise IOError(f'SMC timeout waiting for status {val:#x}/{mask:#x}')

def send_byte(b, p):
    wait_status(0, IB_CLOSED)
    wait_status(BUSY, BUSY)
    outb(b, p)

def send_command(c):
    wait_status(0, IB_CLOSED)
    outb(c, CMD)

def smc_sane():
    try:
        wait_status(0, BUSY); return
    except IOError:
        send_command(READ_CMD)
        wait_status(0, BUSY)

def send_key(key):
    for ch in key.encode():
        send_byte(ch, DATA)

def read_key(key, length):
    smc_sane()
    send_command(READ_CMD); send_key(key); send_byte(length, DATA)
    out = []
    for _ in range(length):
        wait_status(AWAITING_DATA | BUSY, AWAITING_DATA | BUSY)
        out.append(inb(DATA))
    for _ in range(16):  # drain leftovers
        if not inb(CMD) & AWAITING_DATA: break
        inb(DATA)
    wait_status(0, BUSY)
    return bytes(out)

def write_key(key, data):
    smc_sane()
    send_command(WRITE_CMD); send_key(key); send_byte(len(data), DATA)
    for b in data:
        send_byte(b, DATA)
    wait_status(0, BUSY)

if len(sys.argv) > 1:
    pct = int(sys.argv[1])
    if not 20 <= pct <= 100:
        sys.exit('percent must be 20..100')
    write_key('BCLM', bytes([pct]))
print('BCLM =', read_key('BCLM', 1)[0])
EOF
chmod 755 /usr/local/sbin/smc-bclm

step "Boot script: /usr/local/sbin/headless-power.sh"
cat > /usr/local/sbin/headless-power.sh <<'EOF'
#!/bin/bash
# Applied at every boot by headless-power.service
. /etc/default/headless-power
log() { echo "headless-power: $*"; }
SW=/sys/kernel/debug/vgaswitcheroo/switch

# Touching vgaswitcheroo while the GPU drivers are still probing deadlocks the
# kernel (process stuck in D state, forced power-off needed). Wait until both
# DRM drivers are up and the system has settled.
udevadm settle --timeout=60
for i in $(seq 60); do
  [ -e /sys/class/drm/card0 ] && [ -e /sys/class/drm/card1 ] && [ -e $SW ] && break
  sleep 1
done
sleep 20

# dGPU off: move display to the Intel iGPU if needed, then cut dGPU power via gmux
log "switch before: $(tr '\n' ' ' < $SW)"
if grep -q '^.:DIS: *+' $SW; then
  log "display on dGPU -> switching to IGD"; echo IGD > $SW; sleep 3
fi
echo OFF > $SW
log "switch after: $(tr '\n' ' ' < $SW)"

# Display and keyboard backlight off, console blanked
for b in /sys/class/backlight/*; do echo 0 > $b/brightness; done
echo 0 > /sys/class/leds/smc::kbd_backlight/brightness 2>/dev/null
setterm --blank force --powerdown 1 --term linux </dev/tty1 >/dev/tty1 2>/dev/null
echo 0 > /sys/class/graphics/fbcon/cursor_blink

# Runtime PM, USB autosuspend, audio power save, etc.
powertop --auto-tune >/dev/null 2>&1
echo powersupersave > /sys/module/pcie_aspm/parameters/policy

# Bluetooth radio off (in case the module gets loaded anyway)
for r in /sys/class/rfkill/rfkill*; do
  [ -e "$r" ] && [ "$(cat $r/type)" = bluetooth ] && echo 1 > $r/soft
done
log "display off, tunables applied"

# Battery charge limit
/usr/local/sbin/smc-bclm "$CHARGE_LIMIT"
exit 0
EOF
chmod 755 /usr/local/sbin/headless-power.sh

step "systemd unit: headless-power.service"
cat > /etc/systemd/system/headless-power.service <<'EOF'
[Unit]
Description=Headless power saving (dGPU off, display off, tunables, charge limit)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/headless-power.sh
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

step "Kernel cmdline: consoleblank=60"
if ! grep -q 'consoleblank=' /etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=60"/' /etc/default/grub
  update-grub
fi

step "Sysctls"
cat > /etc/sysctl.d/90-powersave.conf <<'EOF'
kernel.nmi_watchdog = 0
kernel.watchdog = 0
vm.dirty_writeback_centisecs = 1500
EOF
sysctl -q --system

step "Disable built-in SD card reader (its media polling keeps the USB3 bus awake)"
cat > /etc/udev/rules.d/90-no-sdcard-reader.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8406", ATTR{authorized}="0"
EOF
udevadm control --reload
for d in /sys/bus/usb/devices/*; do
  [ "$(cat $d/idVendor 2>/dev/null):$(cat $d/idProduct 2>/dev/null)" = 05ac:8406 ] && echo 0 > $d/authorized
done

step "Bluetooth off"
systemctl disable --now bluetooth.service 2>/dev/null || true
printf 'blacklist btusb\nblacklist bluetooth\n' > /etc/modprobe.d/no-bluetooth.conf
update-initramfs -u

step "Never suspend: ignore lid, mask sleep targets"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/headless.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

step "Enable service"
systemctl daemon-reload
systemctl enable headless-power.service

cat <<EOF

Done. Reboot to apply everything:  sudo reboot
The display goes dark ~30 s after boot, when headless-power.service runs.
Check afterwards:  systemctl status headless-power; sudo journalctl -b -u headless-power
Charge limit now: sudo smc-bclm $CHARGE_LIMIT   (persistent value: /etc/default/headless-power)
EOF
