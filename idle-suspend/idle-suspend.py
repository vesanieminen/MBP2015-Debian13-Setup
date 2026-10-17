#!/usr/bin/python3
"""Suspend after 15 quiet minutes; fail awake if activity checks fail."""
import argparse
import glob
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import time

IDLE_SECONDS = 15 * 60
POLL_SECONDS = 15


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10).strip()


def connections():
    # Any established inbound TCP connection keeps hosted services/SSH awake.
    listeners = set()
    for row in command("ss", "-Hln", "-t").splitlines():
        listeners.add(row.split()[3].rsplit(":", 1)[1])
    reasons = []
    for row in command("ss", "-Hn", "-t", "state", "established").splitlines():
        fields = row.split()
        local, peer = fields[2:4]
        address = peer.rsplit(":", 1)[0].strip("[]").split("%", 1)[0]
        if not ipaddress.ip_address(address).is_loopback:
            if local.rsplit(":", 1)[1] in listeners:
                reasons.append("inbound connection on port " + local.rsplit(":", 1)[1])
    return reasons


def sessions():
    reasons = []
    for session in json.loads(command("loginctl", "list-sessions", "--json=short")):
        if session["class"] not in ("user", "user-early"):
            continue
        props = dict(line.split("=", 1) for line in command(
            "loginctl", "show-session", session["session"],
            "-p", "Remote", "-p", "State", "-p", "IdleHint").splitlines())
        if props.get("State") == "closing":
            continue
        if props.get("Remote") == "yes" or props.get("IdleHint") != "yes":
            reasons.append("active login session " + session["session"])
    return reasons


def inhibitors():
    result = json.loads(command("busctl", "--json=short", "call",
        "org.freedesktop.login1", "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager", "ListInhibitors"))
    return ["inhibitor: " + row[1] for row in result["data"][0]
            if set(row[0].split(":")) & {"sleep", "idle"}]


def snapshot():
    values = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    cpu = list(map(int, values[:8]))  # guest time is already included in user time
    network = 0
    for row in Path("/proc/net/dev").read_text().splitlines()[2:]:
        name, counters = row.split(":", 1)
        if name.strip() != "lo":
            counts = counters.split()
            network += int(counts[0]) + int(counts[8])
    # Whole physical block devices only, to avoid counting partitions twice.
    disk = 0
    for name in glob.glob("/sys/block/*"):
        if Path(name).name.startswith(("loop", "ram", "dm-", "md")):
            continue
        stats = list(map(int, (Path(name) / "stat").read_text().split()))
        disk += (stats[2] + stats[6]) * 512
    return time.monotonic(), sum(cpu) - cpu[3] - cpu[4], network, disk


def activity(previous, current):
    elapsed = current[0] - previous[0]
    if elapsed <= 0:
        return ["clock reset"]
    reasons = []
    if (current[1] - previous[1]) / os.sysconf("SC_CLK_TCK") / elapsed >= 0.10:
        reasons.append("CPU work (at least 10% of one core)")
    if (current[2] - previous[2]) / elapsed >= 16 * 1024:
        reasons.append("network transfer (at least 16 KiB/s)")
    if (current[3] - previous[3]) / elapsed >= 128 * 1024:
        reasons.append("disk transfer (at least 128 KiB/s)")
    return reasons


def blockers():
    reasons = connections() + sessions() + inhibitors()
    for name in glob.glob("/proc/asound/card*/pcm*/sub*/status"):
        if "RUNNING" in Path(name).read_text():
            reasons.append("audio playback or recording")
    return sorted(set(reasons))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report activity; never suspend")
    args = parser.parse_args()
    previous = snapshot()
    quiet_since = time.monotonic()
    last_report = None
    while True:
        try:
            reasons = blockers()
            current = snapshot()
            # Comparing boottime and monotonic detects a wake from suspend.
            boot_offset = time.clock_gettime(time.CLOCK_BOOTTIME) - current[0]
            if last_report is not None and abs(boot_offset - old_boot_offset) > 2:
                reasons.append("resumed from sleep")
            reasons += activity(previous, current)
            previous = current
            old_boot_offset = boot_offset
            if reasons:
                quiet_since = time.monotonic()
            report = "; ".join(reasons) if reasons else "idle; waiting for 15 quiet minutes"
            if report != last_report or args.check:
                print(report, flush=True)
                last_report = report
            if args.check:
                return
            if time.monotonic() - quiet_since >= IDLE_SECONDS:
                # Recheck immediately before requesting sleep. Logind also
                # enforces inhibitors; never force or ignore them.
                if not blockers():
                    print("15 quiet minutes elapsed; requesting suspend", flush=True)
                    subprocess.run(["systemctl", "suspend"], check=True, timeout=30)
                quiet_since = time.monotonic()
        except Exception as error:
            quiet_since = time.monotonic()
            print("Staying awake: activity check failed: " + str(error), flush=True)
            if args.check:
                raise
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
