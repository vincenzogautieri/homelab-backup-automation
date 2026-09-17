#!/bin/bash
# ==============================================================================
# FULL BACKUP ORCHESTRATION
# ------------------------------------------------------------------------------
# Wakes a normally-powered-off backup server via Wake-on-LAN, runs a full
# Proxmox backup job with pruning, verifies data integrity, reclaims disk
# space via garbage collection, and powers the backup server back off.
#
# Designed to run unattended via cron on the main Proxmox host.
# ==============================================================================

set -euo pipefail

# --- Configuration (edit these for your environment) ------------------------

IP_PBS="<IP-PBS>"
MAC_PBS="AA:BB:CC:DD:EE:FF"
INTERFACE="vmbr0"
DATASTORE="backup-envy"
VERIFY_JOB_ID="<PBS-VERIFY-JOB-ID>"
PRUNE_JOB_ID="<PBS-PRUNE-JOB-ID>"
SSH_KEY="/root/.ssh/id_pbs"
LOGFILE="/var/log/pbs-backup-cycle.log"
MAX_WAIT_ATTEMPTS=36
POST_BOOT_GRACE=15

log() {
    echo "$(date '+%F %T') $1" | tee -a "$LOGFILE"
}

ssh_pbs() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 root@"$IP_PBS" "$1"
}

log "========== AVVIO CICLO DI BACKUP =========="

# 1. Wake-up

log "[1/6] Invio pacchetto magico a $MAC_PBS su $INTERFACE"
/usr/sbin/etherwake -i "$INTERFACE" "$MAC_PBS" >> "$LOGFILE" 2>&1

# 2. Wait for online status

log "[2/6] Attendo che PBS sia raggiungibile (max 3 min)..."
attempt=0
while ! ping -c1 -W2 "$IP_PBS" &>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$MAX_WAIT_ATTEMPTS" ]; then
        log "[ERRORE CRITICO] PBS non raggiungibile dopo 3 minuti. Interrompo."
        exit 1
    fi
    sleep 5
done
log "PBS online, attendo $POST_BOOT_GRACE secondi per i servizi..."
sleep "$POST_BOOT_GRACE"

# 3. Backup

log "[3/6] Avvio backup di tutti i guest (retention gestita da PBS, non qui)"
if vzdump --all 1 --exclude-path "/var/lib/docker/volumes/ollama_ollama_data/_data/models/*" --storage pbs-backup --mode snapshot --remove 0 --quiet 1 >> "$LOGFILE" 2>&1; then
    log "Backup completato con successo"
else
    log "[ERRORE] Backup fallito - PBS lasciato ACCESO per diagnosi manuale"
    exit 1
fi

# 4. Integrity check

log "[4/6] Avvio verifica integrità blocchi"
if ssh_pbs "proxmox-backup-manager verify-job run $VERIFY_JOB_ID" >> "$LOGFILE" 2>&1; then
    log "Verifica OK"
else
    log "[ATTENZIONE] Verifica fallita - PBS lasciato ACCESO per controllo manuale"
    exit 1
fi

# 5. Prune + Garbage Collection

log "[5/6] Applicazione retention (prune) e liberazione spazio (GC)"
ssh_pbs "proxmox-backup-manager prune-job run $PRUNE_JOB_ID" >> "$LOGFILE" 2>&1 || log "[ATTENZIONE] Prune fallito"
ssh_pbs "proxmox-backup-manager garbage-collection start $DATASTORE" >> "$LOGFILE" 2>&1 || log "[ATTENZIONE] GC fallito"

# 6. Shutdown

log "[6/6] Ciclo completo - spengo PBS tra 15s"
sleep 15
ssh_pbs "shutdown -h now" >> "$LOGFILE" 2>&1

log "========== CICLO COMPLETATO CON SUCCESSO =========="

exit 0
