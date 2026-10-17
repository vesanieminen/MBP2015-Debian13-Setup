# MacBook Pro 2015: headless power findings

Getting a MacBook Pro 11,5 running Debian 13 down to minimum power as a headless
box for running agents over SSH. Done on 2026-09-24.

## Result

| State | Power | How measured |
|---|---|---|
| Fresh install (dGPU on, backlight 75 %) | **18 W** | wall (Home Assistant plug) |
| dGPU off, display off, tunables | **10 W** | wall |
| same, on battery | 9.6 W | battery V × I |
| + SD card reader disabled, watchdog off | **9.0 W** | battery V × I, 20 s average |
| On AC at charge limit | 10 W | wall; battery current 0 A |

**About 45–50 % less power**: roughly 158 kWh/year down to about 85 kWh/year when idling
around the clock.

Wall and battery readings differ by about 0.5–1 W, which is the power adapter's
conversion loss. Battery V × I (`/sys/class/power_supply/BAT0`) is the more precise
of the two, to about 0.1 W. Use it when comparing small changes.

## Hardware

| Component | Device | Driver |
|---|---|---|
| CPU / iGPU | Core i7 Crystal Well, Iris Pro 5200 | `i915` |
| dGPU | AMD Radeon R9 M370X (Venus XT) | `radeon` |
| GPU mux | Apple gmux | `apple-gmux` (vgaswitcheroo) |
| SSD | Apple SM0512G, AHCI | `ahci` |
| Wi-Fi | Broadcom BCM43602 | `brcmfmac` |
| Thunderbolt | Intel Falcon Ridge 4C (TB2) | `thunderbolt` |
| Camera | FaceTime HD (PCIe) | none |
| Battery | bq20z451, 8.75 Ah design / 8.05 Ah now, 92 cycles | `sbs` / ACPI |

## What was done and what it gained

| Change | Gain | Notes |
|---|---|---|
| **dGPU powered off** (`vgaswitcheroo` `IGD` then `OFF`) | most of the **~8 W** | Firmware boots with the display on the dGPU, which sits in D0 with no runtime PM. After the switch the dGPU is off and its HDMI audio is in D3cold. |
| **Backlight 0, keyboard light 0, console blank** | part of the ~8 W | gmux backlight was 767/1023. `consoleblank=60` and `setterm` power the console down; fbcon cursor blink off. |
| **SD card reader deauthorized** (udev, `05ac:8406`) | **~0.6 W** | Its media polling kept the only active USB device awake, which kept the USB3 root hub and xHCI in D0. Now xHCI is in D3hot. |
| **Soft-lockup + NMI watchdog off** | small | Removes about 8 timer wakeups per second. |
| `powertop --auto-tune` | small | Runtime PM, USB autosuspend, audio power save. |
| PCIe ASPM `powersupersave` | small | |
| `vm.dirty_writeback_centisecs=1500` | small | Fewer disk wakeups. |
| Bluetooth off | small | Service disabled, `btusb`/`bluetooth` blacklisted. |
| **Battery charge limit 60 %** (SMC `BCLM`) | battery life | See below. |
| Never suspend | reliability | logind ignores the lid, sleep targets masked. |

Everything that has to be re-applied at runtime is done at boot by `headless-power.service`.
The whole setup is in [`install.sh`](install.sh).

## Battery charge limit

- No kernel interface exists for this model (no `charge_control_end_threshold`).
- The SMC has the key **`BCLM`** (ui8, default `0x64` = 100). `BFCL` and `CHLC` also exist.
- `applesmc` can't write arbitrary keys, so `smc-bclm` writes it over raw port I/O
  (`/dev/port`, ports 0x300/0x304), using the same protocol as the kernel driver.
- **It works on this 2015 model:** right after writing, the battery went from *Charging*
  to *Full* with 0 A. On AC it holds its current level and doesn't discharge down to the
  limit, so you have to unplug it once to drain it.
- Why 60 %: Li-ion wears least at 40–60 %, and heat plus high charge is the worst
  combination. 60 % still leaves about 55 Wh, a few hours of backup at 9 W.
- The value survived a forced power-off. It's re-applied at every boot anyway.

## Pitfalls hit

1. **Boot-time vgaswitcheroo deadlock.** Writing to `/sys/kernel/debug/vgaswitcheroo/switch`
   while radeon and i915 were still probing hung the kernel. The service was SIGKILLed,
   but the switcheroo lock stayed held, so any later read of the file blocked in D state.
   The dGPU stayed on (18 W again), and even reboot hung, which needed a **forced power-off**.
   Fix: wait for `udevadm settle`, both DRM cards and the switch file, plus 20 s. The
   display now goes dark about 30 s after boot.
2. **EFI `gpu-power-prefs` doesn't work.** Writing
   `gpu-power-prefs-fa4ce28d-…` (07 00 00 00 01 00 00 00) left an empty variable
   ("Invalid argument" on read), both with `printf >` and with a single `dd` write. Not
   needed, since the runtime switch does the job.
3. **SATA ALPM isn't supported.** The Apple SSD controller returns "Operation not
   supported" for `med_power_with_dipm`. It stays at `max_performance`.
4. Debian minimal has no `rfkill` binary. Use `/sys/class/rfkill/*/soft` instead.
5. `/sbin` isn't in the normal user's PATH (`iw`, `modinfo`). Use full paths.

## Things checked and left alone

- **Wi-Fi:** power save is already on, the signal is strong (−38 dBm, 5 GHz). Most
  `brcmf` IRQ wakeups (~150/s) come from the active SSH session.
- **"Audio codec ATI 100 %" in powertop:** a stale reading. That PCI function is in D3cold.
- **FaceTime camera:** has no driver and sits idle.

## Wi-Fi vs. Ethernet (not done)

The MBP has no Ethernet port, so it would need an adapter:

| Option | Expected net change |
|---|---|
| USB 3 gigabit (RTL8153) + Wi-Fi off | about ±0.5 W: adapter ~0.5–1 W and USB3 stays awake, minus Wi-Fi ~0.5–1 W |
| Thunderbolt 2 Ethernet (BCM57762, `tg3`) | worse: wakes the TB controller and bridges, ASPM often lost over TB, may block deep package C-states |

Ethernet is only worth it for reliability and latency, not power. If you do switch,
use USB and disable Wi-Fi.

## Wake-on-WLAN + suspend (verified 2026-10-17)

Deep suspend and timer resume worked with 60-second and 120-second RTC alarms.
Wake from deep suspend using Home Assistant also worked after enabling
magic-packet wake on the current Wi-Fi radio. Verified HA settings:

| Setting | Value |
|---|---|
| Wi-Fi interface | `wlp4s0` |
| Wi-Fi MAC | `f4:5c:89:92:f2:b9` |
| Broadcast address | `192.168.0.255` |
| UDP port | `9` |

Permanent configuration installed on the Mac:

- `/usr/local/sbin/enable-wowlan` discovers the radio through
  `/sys/class/net/wlp4s0/phy80211`, writes `enabled` to the Wi-Fi device's
  `power/wakeup`, and enables magic-packet wake with `iw`.
- `wowlan.service` invokes that helper at boot, after `headless-power.service`.
- `/usr/lib/systemd/system-sleep/enable-wowlan` invokes the helper before each
  suspend, using the current radio rather than a fixed radio number.
- `sleep.target` and `suspend.target` are unmasked; lid closure remains ignored.
- `headless-power.service` no longer has `After=multi-user.target`, resolving its
  ordering cycle with WoWLAN. Its script retains the GPU readiness delay. The
  service completed successfully and both backlight readings were `0` with the
  lid open.

The installed fixes are reproducible with `fix-display-boot.sh` and
`fix-wowlan.sh`. The successful HA wake test used a manual enable on the current
radio. Repeated suspend cycles and reboot behavior with the installed hook have
not yet been verified.

## Open items

- **Thunderbolt controller is always awake.** NHI `08:00.0` and bridges `06:00.0`/`07:00.0`
  stay in D0 with nothing plugged in. This is probably part of the remaining 9 W.
  Linux's Apple TB power-off quirk only runs during system sleep, so a runtime
  power-off would need further investigation (for example the ACPI force-power methods).
- **Package C-state residency:** check powertop → *Idle stats* → Package column. If it
  rarely goes below C3, something is still blocking deep idle.
- **Automatic idle suspend:** `idle-suspend.service` is installed and enabled with
  a 15-minute quiet interval. Configuration and validation are recorded in
  [idle-suspend/README.md](idle-suspend/README.md); an actual automatic sleep/wake
  cycle remains untested.
- Optional: disable CPU turbo (lower peak power and heat, but slower builds).

## Useful commands

```sh
systemctl status headless-power
sudo journalctl -b -u headless-power
sudo cat /sys/kernel/debug/vgaswitcheroo/switch        # DIS should be "Off"
cat /sys/class/power_supply/BAT0/{capacity,status}
sudo smc-bclm                                          # show charge limit
sudo smc-bclm 80                                       # change until next boot
# battery power draw (µV × µA → W), only meaningful when unplugged
echo "$(( $(cat /sys/class/power_supply/BAT0/voltage_now)/1000 * $(cat /sys/class/power_supply/BAT0/current_now)/1000 / 1000 )) mW"
```
