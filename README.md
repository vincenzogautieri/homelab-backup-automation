# Homelab Power-Cycle Automation

🇮🇹 [Leggi in italiano](README.it.md)

> Bash automation for a Proxmox homelab that coordinates backup-server power management, automated backups, integrity verification, PBS retention, garbage collection, and shutdown.

This repository contains the standalone automation script extracted from the larger [`homelab-selfhosted`](https://github.com/vincenzogautieri/homelab-selfhosted) infrastructure project.

The script is designed to run unattended on the main Proxmox host and orchestrates the complete daily backup lifecycle of a normally powered-off Proxmox Backup Server (PBS).

## What it does

The script (`power-cycle.sh`) runs a deterministic six-step workflow:

1. **Wake** — sends a Wake-on-LAN magic packet to the backup server.
2. **Wait** — waits until PBS becomes reachable, with a maximum boot timeout.
3. **Backup** — runs `vzdump` against all Proxmox VMs and LXC containers.
4. **Verify** — triggers the configured PBS verification job.
5. **Prune & Garbage Collection** — applies the PBS retention policy and reclaims unused storage blocks.
6. **Shutdown** — powers off the backup server remotely via SSH.

The workflow is designed for unattended execution through `cron`.

## Architecture

```text
                    Main Proxmox Host
                         │
                         │ cron — 13:00
                         ▼
                 ┌─────────────────┐
                 │  power-cycle.sh │
                 └────────┬────────┘
                          │
                          │ Wake-on-LAN
                          ▼
                 ┌─────────────────┐
                 │ Proxmox Backup  │
                 │ Server (PBS)    │
                 └────────┬────────┘
                          │
              ┌───────────┼───────────┐
              │           │           │
              ▼           ▼           ▼
           Backup      Verify      Prune
              │           │           │
              └───────────┼───────────┘
                          │
                          ▼
                  Garbage Collection
                          │
                          ▼
                       Shutdown
```

## Backup workflow

### 1. Wake the backup server

Wake-on-LAN is used to power on PBS only when backup and maintenance operations are required.

The script sends the magic packet through the configured Proxmox network bridge:

```bash
etherwake -i "$INTERFACE" "$PBS_MAC"
```

### 2. Wait for PBS availability

The script polls the configured PBS IP address until the server becomes reachable.

The default configuration waits up to approximately three minutes:

```text
36 attempts × 5 seconds
```

Once the server responds, an additional grace period is used to allow Proxmox and PBS services to finish starting.

### 3. Run Proxmox backups

All current and future Proxmox guests are selected automatically:

```bash
vzdump --all 1
```

Backups are written to the PBS storage configured in Proxmox:

```text
pbs-backup
```

The Ollama model directory is explicitly excluded from the backup operation:

```text
/var/lib/docker/volumes/ollama_ollama_data/_data/models/*
```

This avoids unnecessarily backing up large AI model files that can be re-downloaded when required.

Retention is **not handled by `vzdump`**.

Retention is managed directly on the Proxmox Backup Server through a dedicated PBS Prune Job.

### 4. Verify backup integrity

After the backup completes, the configured PBS verification job is triggered:

```bash
proxmox-backup-manager verify-job run "$VERIFY_JOB_ID"
```

If the verification fails, the script stops and intentionally leaves PBS powered on for manual investigation.

### 5. Apply retention and reclaim storage

The PBS Prune Job is executed to apply the retention policy configured on the datastore:

```bash
proxmox-backup-manager prune-job run "$PRUNE_JOB_ID"
```

The current infrastructure uses PBS retention rules including:

* Keep Last: 3
* Keep Daily: 7
* Keep Weekly: 4
* Keep Monthly: 6
* Keep Yearly: 1

Garbage collection is then executed on the configured datastore:

```bash
proxmox-backup-manager garbage-collection start "$DATASTORE"
```

Prune and garbage collection are intentionally handled separately from the `vzdump` operation.

### 6. Shutdown

Once the workflow has completed, PBS is remotely shut down:

```bash
shutdown -h now
```

This keeps the backup server powered off when it is not required.

## Power management strategy

The automation is part of a larger low-power infrastructure strategy.

### Main Proxmox host

The main host is scheduled to power off at midnight using:

```bash
rtcwake -m off -s 25200
```

The RTC alarm wakes the host approximately seven hours later.

### Backup server

The PBS node normally remains powered off and is started only when the daily backup workflow runs.

This reduces unnecessary idle power consumption while retaining automated backup capability.

## Scheduling

The backup workflow runs daily at 13:00:

```cron
0 13 * * * /root/power-cycle.sh
```

The main host nightly power cycle is scheduled at midnight:

```cron
00 00 * * * /usr/sbin/rtcwake -m off -s 25200
```

See [`crontab.example`](crontab.example) for a complete example.

## Relationship to the main homelab

This repository is a standalone extraction of the backup and power-management automation implemented in:

**[`vincenzogautieri/homelab-selfhosted`](https://github.com/vincenzogautieri/homelab-selfhosted)**

The main repository documents the complete infrastructure, including:

* Proxmox VE
* Proxmox Backup Server
* LXC containers
* Docker
* Tailscale
* AdGuard Home
* Nginx Proxy Manager
* Nextcloud
* n8n
* Ollama
* administration and monitoring services

This repository focuses specifically on the automated backup and power-cycle component.