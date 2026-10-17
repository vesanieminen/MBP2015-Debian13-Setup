# mbp2015-headless

Turns a MacBook Pro 11,5 (15" mid-2015, Radeon R9 M370X) running Debian 13 into a
headless, low-power box. Idle power measured at the wall: **18 W → 10 W**.

```sh
sudo ./install.sh        # charge limit 60 %
sudo ./install.sh 80     # custom charge limit
sudo reboot
```

## What it does

| Change | How |
|---|---|
| AMD dGPU powered off | `vgaswitcheroo`: `IGD` then `OFF` (via `apple-gmux`) |
| Display off | gmux backlight 0, keyboard backlight 0, `consoleblank=60` + `setterm` |
| Battery charge limit | Apple SMC key `BCLM`, written by `smc-bclm` (raw port I/O) |
| Power tunables | `powertop --auto-tune`, PCIe ASPM `powersupersave`, NMI + soft-lockup watchdog off, fbcon cursor blink off, writeback 15 s |
| SD card reader off | udev deauthorizes `05ac:8406`; its media polling kept the USB3 bus awake |
| Bluetooth off | service disabled, `btusb`/`bluetooth` blacklisted, rfkill |
| Suspend policy | base install masks sleep; `idle-suspend/` enables suspend after 15 quiet minutes; lid stays ignored |

Everything runtime-related is applied at each boot by `headless-power.service`
(`/usr/local/sbin/headless-power.sh`, config in `/etc/default/headless-power`).

## Automatic idle suspend

The installed `idle-suspend.service` suspends after 15 quiet minutes, staying
awake for remote connections, active sessions, inhibitors, audio, and significant
CPU, disk, or network activity. Install it after the base headless setup:

```sh
sudo sh idle-suspend/install.sh
```

The installer unmasks normal suspend. Reapply it after rerunning the base
`install.sh`, which masks sleep targets. See [idle-suspend/README.md](idle-suspend/README.md)
for the activity thresholds, status commands, and how to disable it.

## Notes

- **Boot deadlock:** writing to `vgaswitcheroo` while radeon/i915 are still probing
  hangs the kernel (process in D state, forced power-off needed). The service waits
  for udev, both DRM cards and 20 s before switching. So the display stays on for
  ~30 s after boot.
- **Charge limit** stops charging at the limit but won't discharge on AC. Unplug
  once to drain down to it. Change it at runtime with `sudo smc-bclm <percent>`.
- **Not included (don't work on this model):** EFI `gpu-power-prefs` variable
  (firmware rejects the write), SATA ALPM (Apple SSD controller returns
  "Operation not supported").

## Installed fixes (2026-10-17)

- Display shutdown: removed `After=multi-user.target` from
  `headless-power.service`, resolving its ordering cycle with `wowlan.service`.
  The service completed successfully and both backlight readings were `0`,
  including with the lid open. The GPU readiness delay remains in place.
- Wake-on-WLAN: wake from deep suspend worked using Home Assistant with Wi-Fi MAC
  `f4:5c:89:92:f2:b9`, broadcast `192.168.0.255`, UDP port `9`.
  `/usr/local/sbin/enable-wowlan` finds the current radio through
  `/sys/class/net/wlp4s0/phy80211`, enables device wake, and enables magic-packet
  wake. `wowlan.service` invokes it at boot; the executable
  `/usr/lib/systemd/system-sleep/enable-wowlan` hook invokes it before suspend.

These permanent files are installed on the Mac. The successful HA wake test used
a manual enable on the current radio; repeated suspend cycles and reboot behavior
with the installed hook have not yet been verified.

To apply the same fixes to an existing setup:

```sh
bash ./fix-display-boot.sh
bash ./fix-wowlan.sh
```

Both scripts back up replaced files and require sudo. `install.sh` includes the
display ordering fix, but still masks suspend by default and does not install
WoWLAN. This Mac has `sleep.target` and `suspend.target` unmasked and the separate
idle-suspend service enabled; lid closure remains ignored. See
[FINDINGS.md](FINDINGS.md) for the record.
