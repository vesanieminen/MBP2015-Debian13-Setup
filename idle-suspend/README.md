# Headless Debian MacBook: automatic suspend

The MacBook Pro running Debian 13 suspends after 15 consecutive quiet minutes.
This configuration belongs to the Debian MacBook headless setup.
The helper and unit were recorded byte-for-byte from the installed configuration
on 2026-10-17. The tracked installer additionally unmasks `sleep.target` and
`suspend.target` so it can also follow the original headless setup, which masked
sleep. Lid handling and hibernation policy are left as configured by that setup.

## Install or update

On the Debian host, with this repository cloned as `~/mbp2015-headless`:

```bash
cd ~/mbp2015-headless
sudo sh idle-suspend/install.sh
```

Requires Python 3, systemd/logind, and `ss` from `iproute2` (present on this host).
The installer checks activity without sleeping, copies root-owned files into
`/usr/local/lib/idle-suspend/` and `/etc/systemd/system/`, unmasks normal suspend,
and enables/restarts `idle-suspend.service`. Each restart begins a fresh timer.
It does not install or configure Wake-on-LAN. The machine's existing Wake-on-WLAN
configuration is maintained by this repository's `fix-wowlan.sh`.

## Activity policy

Checks run every 15 seconds. Any of these resets the idle timer:

- An established inbound TCP connection to a listening port, excluding loopback.
  SSH and other hosted services keep the machine awake even if the connection
  is idle. Merely listening for connections does not keep it awake.
- A remote login session, or a local user session that logind does not mark idle.
  Sessions in the closing state and the user manager session are ignored.
- A logind sleep or idle inhibitor, including delay inhibitors.
- An ALSA playback or capture stream in the `RUNNING` state.
- CPU work averaging at least 10% of one core over the sampling interval.
- Network traffic averaging at least 16 KiB/s on non-loopback interfaces.
- Physical disk traffic averaging at least 128 KiB/s.
- A detected resume from sleep, which starts another full quiet interval.

Activity-check failures keep the computer awake. Immediately before suspend,
connections, sessions, inhibitors, and audio are checked again. Suspend uses
`systemctl suspend` without forcing or bypassing inhibitors.

Idle outbound sockets alone do not block sleep. Quiet background jobs below the
CPU and I/O thresholds can be suspended; protect jobs that must keep running with
an explicit inhibitor:

```bash
systemd-inhibit --what=sleep:idle --mode=block --why="Background job" your-command
```

## Inspect or disable

```bash
systemctl status idle-suspend.service
journalctl -u idle-suspend.service -n 50 --no-pager
sudo python3 /usr/local/lib/idle-suspend/idle-suspend.py --check
sudo systemctl disable --now idle-suspend.service
```

Disabling the service stops automatic suspend and leaves manual suspend available.

## Validation

Python compilation, installer shell syntax, and systemd unit validation passed.
Activity detection identified the live SSH connections. Simulated checks covered
activity thresholds, inbound SSH, loopback exclusion, inhibitors, a suspend request
at 900 quiet seconds, and no suspend while a session remains busy. No actual
automatic suspend/resume cycle was performed as part of these checks.
