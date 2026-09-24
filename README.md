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
| Never suspend | logind ignores the lid, sleep targets masked |

Everything runtime-related is applied at each boot by `headless-power.service`
(`/usr/local/sbin/headless-power.sh`, config in `/etc/default/headless-power`).

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
