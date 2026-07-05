# Homelab Power-Cycle Automation

🇮🇹 [Leggi in italiano](README.it.md)

A Bash automation script that orchestrates the full power lifecycle of a Proxmox homelab: the main host sleeps and wakes itself on a nightly schedule, while a separate backup server is woken on-demand via Wake-on-LAN once a day to run a backup, verify its integrity, reclaim disk space, and shut itself back down. Together, these two schedules keep the whole infrastructure at close to 0 W of idle power for roughly 23.5 hours a day.

Originally built as part of a larger [homelab infrastructure project](https://github.com/vincenzogautieri/homelab-selfhosted); extracted here as a standalone example of infrastructure automation and orchestration.

## What it does

The script (`power-cycle.sh`) runs a fixed six-step sequence, with error handling at every stage:

1. **Wake** — sends a Wake-on-LAN magic packet to the backup server's network interface.
2. **Wait** — polls the server via ping for up to 3 minutes; exits with an error if it never comes online, rather than proceeding blindly.
3. **Backup** — runs `vzdump` against all VMs/LXC containers, with an integrated retention policy (keep last 7 daily, 4 weekly, 1 monthly).
4. **Verify** — triggers a Proxmox Backup Server verify job to check block-level integrity of the freshly written data.
5. **Garbage-collect** — reclaims disk space by physically removing orphaned data blocks no longer referenced by any backup.
6. **Shut down** — powers off the backup server remotely via SSH, once every step above has completed successfully.

## The bigger picture: a fully deterministic power cycle

This script is one half of a two-sided power strategy:

- **Main host**: stays on, but is put into a scheduled deep sleep every night (`rtcwake -m off -s 25200`) and wakes itself up via the RTC hardware clock after a fixed window — no backup or maintenance work happens overnight, so there's no reason to keep it running.
- **Backup server**: stays fully powered off (0 W) essentially all day, and is woken up on-demand, once a day, only for the few minutes it takes to complete steps 1–6 above.

Both schedules are driven by cron on the main host (see `crontab.example`), so the entire lifecycle — sleep, wake, backup, verify, clean up, shut down — requires zero manual intervention.

## Why this design

- **Fault tolerance over blind execution**: the script doesn't just fire commands and hope; it actively waits for the backup server to be reachable before touching it, and fails loudly (`exit 1`) if it isn't, rather than running backup commands against a server that isn't there yet.
- **Idempotent retention policy**: pruning is handled by `vzdump`'s own `--prune-backups` flag rather than a separate cleanup script, keeping the retention logic in one place.
- **Full lifecycle ownership**: the script is not just "run a backup" — it owns the entire lifecycle of the target machine, from power-on to power-off, treating the backup server as an on-demand resource rather than an always-on one.
- **Observability**: every step logs a clearly numbered status line (`[1/6]`, `[2/6]`, ...) to make it trivial to see, from the log file alone, exactly where a failed run stopped.

## Requirements

- A Proxmox VE host (script assumes `vzdump` and `pct`-style tooling is available)
- A second machine running Proxmox Backup Server (PBS), reachable over the network and configured to accept Wake-on-LAN
- `etherwake` installed on the main host (`apt install etherwake`)
- SSH key-based access from the main host to the backup server (so the script can run non-interactively)
- A configured PBS Verify Job (create one from the PBS web UI first, then note its Job ID)

## Setup

1. Copy `power-cycle.sh` to the main Proxmox host (e.g. `/root/power-cycle.sh`) and make it executable:
   ```bash
   chmod +x power-cycle.sh
   ```
2. Edit the configuration block at the top of the script with your own values:
   ```bash
   PBS_IP="<BACKUP_SERVER_IP>"
   PBS_MAC="<BACKUP_SERVER_MAC_ADDRESS>"
   DATASTORE="backup-datastore"
   VERIFY_JOB_ID="<PBS_VERIFY_JOB_ID>"
   INTERFACE="vmbr0"
   ```
3. Test it manually first:
   ```bash
   ./power-cycle.sh
   ```
4. Once it runs cleanly end-to-end, schedule it with cron — see `crontab.example` for a ready-to-adapt configuration covering both the backup job and the main host's nightly sleep cycle.

## Sanity checks

- The log line `[OK] Server is responding to ping!` should appear well within the 3-minute window (typically after 9-12 polling attempts) — a much longer wait may indicate the backup server isn't waking up correctly from suspend.
- Timestamps inside Proxmox Backup Server's web UI and index files are recorded in UTC (`Z` suffix) — this is expected and requires no manual timezone correction.
- Because the whole lifecycle is driven remotely by this script, PBS's own built-in schedules for Prune/GC and Verify Jobs can safely be left disabled ("No Schedule Set") in its web UI — they're triggered on-demand instead.

## Security note

`PBS_MAC`, `PBS_IP`, and `VERIFY_JOB_ID` in this repository are placeholders. Replace them with your own values locally — never commit real MAC addresses, internal IPs, or infrastructure identifiers to a public repository.
