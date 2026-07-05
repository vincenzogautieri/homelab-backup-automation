#!/bin/bash
# ==============================================================================
# GREEN BACKUP ORCHESTRATION SCRIPT
# ------------------------------------------------------------------------------
# Wakes a normally-powered-off backup server via Wake-on-LAN, runs a full
# Proxmox backup job with pruning, verifies data integrity, reclaims disk
# space via garbage collection, and powers the backup server back off.
#
# Designed to run unattended via cron on the main Proxmox host.
# ==============================================================================

set -euo pipefail

# --- Configuration (edit these for your environment) ------------------------
PBS_IP="<BACKUP_SERVER_IP>"          # Tailscale/LAN IP of the Proxmox Backup Server
PBS_MAC="<BACKUP_SERVER_MAC_ADDRESS>" # MAC address of the backup server's NIC (for WoL)
DATASTORE="backup-datastore"          # PBS datastore name
VERIFY_JOB_ID="<PBS_VERIFY_JOB_ID>"   # Verify Job ID configured on PBS
INTERFACE="vmbr0"                     # Network bridge on the main host used to send the WoL packet

MAX_WAIT_ATTEMPTS=36   # 36 * 5s = 3 minutes max wait for the backup server to boot
POST_BOOT_GRACE_PERIOD=15  # extra seconds to let Proxmox services fully start after ping succeeds

echo "========================================================="
echo "   STARTING AUTOMATED BACKUP WORKFLOW: $(date)"
echo "========================================================="

# --- 1. Wake the backup server -----------------------------------------------
echo "--> [1/6] Sending Wake-on-LAN packet to wake up the backup server..."
etherwake -i "$INTERFACE" "$PBS_MAC"

# --- 2. Wait for the backup server to come online ----------------------------
echo "--> [2/6] Waiting for the backup server to come online (max 3 minutes)..."
attempt=0
while ! ping -c 1 -W 1 "$PBS_IP" > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MAX_WAIT_ATTEMPTS" ]; then
        echo "    [CRITICAL ERROR] Backup server did not come online in time. Exiting."
        exit 1
    fi
    echo "    Attempt $attempt/$MAX_WAIT_ATTEMPTS: server not responding, retrying in 5 seconds..."
    sleep 5
done

echo "    [OK] Server is responding to ping!"
echo "    Waiting $POST_BOOT_GRACE_PERIOD more seconds for services to fully initialize..."
sleep "$POST_BOOT_GRACE_PERIOD"

# --- 3. Run the backup job with pruning --------------------------------------
echo "--> [3/6] Starting backup of all guests with prune policy (7d, 4wk, 1mo)..."
vzdump --all 1 \
    --prune-backups 'keep-last=7,keep-weekly=4,keep-monthly=1' \
    --storage pbs-backup \
    --mode snapshot \
    --remove 1

# --- 4. Verify backup integrity -----------------------------------------------
echo "--> [4/6] Running the Verify Job on PBS to check block integrity..."
ssh -o ConnectTimeout=10 "root@$PBS_IP" "proxmox-backup-manager verify-job run $VERIFY_JOB_ID"

# --- 5. Reclaim disk space ----------------------------------------------------
echo "--> [5/6] Running Garbage Collection on PBS to physically free up space..."
ssh -o ConnectTimeout=10 "root@$PBS_IP" "proxmox-backup-manager garbage-collection start $DATASTORE"

# --- 6. Power off the backup server --------------------------------------------
echo "--> [6/6] All done. Powering off the backup server..."
ssh -o ConnectTimeout=10 "root@$PBS_IP" "poweroff"

echo "========================================================="
echo "   WORKFLOW COMPLETED SUCCESSFULLY: $(date)"
echo "========================================================="
