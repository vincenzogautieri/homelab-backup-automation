# Homelab Backup Automation

🇬🇧 [Read in English](README.md)

> Automazione Bash per un homelab Proxmox che coordina gestione dell'alimentazione del server di backup, backup automatici, verifica dell'integrità, retention PBS, garbage collection e spegnimento.

Questa repository contiene la versione standalone dello script di automazione estratto dal progetto infrastrutturale [`homelab-selfhosted`](https://github.com/vincenzogautieri/homelab-selfhosted).

Lo script è progettato per essere eseguito automaticamente sull'host principale Proxmox e coordina l'intero ciclo giornaliero di backup di un Proxmox Backup Server (PBS) normalmente spento.

## Cosa fa

Lo script (`backup-orchestrator.sh`) esegue un workflow deterministico composto da sei fasi:

1. **Wake** — invia un pacchetto Wake-on-LAN al server di backup.
2. **Wait** — attende che PBS diventi raggiungibile, con un timeout massimo.
3. **Backup** — esegue `vzdump` su tutte le VM e i container LXC Proxmox.
4. **Verify** — avvia il job PBS configurato per la verifica dell'integrità.
5. **Prune & Garbage Collection** — applica la retention configurata su PBS e libera lo spazio non più utilizzato.
6. **Shutdown** — spegne remotamente il server di backup tramite SSH.

Il workflow è progettato per essere eseguito senza intervento manuale tramite `cron`.

## Architettura

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

## Workflow di backup

### 1. Accensione del server di backup

Wake-on-LAN viene utilizzato per accendere PBS solamente quando sono necessarie le operazioni di backup e manutenzione.

Lo script invia il magic packet attraverso il bridge di rete Proxmox configurato:

```bash
etherwake -i "$INTERFACE" "$PBS_MAC"
```

### 2. Attesa della disponibilità di PBS

Lo script verifica periodicamente l'indirizzo IP configurato di PBS fino a quando il server diventa raggiungibile.

La configurazione predefinita attende per circa tre minuti:

```text
36 tentativi × 5 secondi
```

Quando il server risponde, viene utilizzato un ulteriore periodo di attesa per permettere ai servizi Proxmox e PBS di completare l'avvio.

### 3. Esecuzione dei backup Proxmox

Tutti i guest Proxmox attuali e futuri vengono selezionati automaticamente:

```bash
vzdump --all 1
```

I backup vengono inviati allo storage PBS configurato su Proxmox:

```text
pbs-backup
```

La directory contenente i modelli Ollama viene esclusa esplicitamente:

```text
/var/lib/docker/volumes/ollama_ollama_data/_data/models/*
```

In questo modo non vengono copiati inutilmente grandi file di modelli AI che possono essere eventualmente riscaricati.

La retention **non viene gestita da `vzdump`**.

La retention viene invece gestita direttamente da Proxmox Backup Server tramite un apposito PBS Prune Job.

### 4. Verifica dell'integrità

Dopo il completamento del backup viene avviato il job PBS configurato:

```bash
proxmox-backup-manager verify-job run "$VERIFY_JOB_ID"
```

Se la verifica fallisce, lo script si interrompe e lascia intenzionalmente PBS acceso per consentire una diagnosi manuale.

### 5. Retention e garbage collection

Il PBS Prune Job viene eseguito per applicare la politica di retention configurata sul datastore:

```bash
proxmox-backup-manager prune-job run "$PRUNE_JOB_ID"
```

L'infrastruttura attuale utilizza:

* Keep Last: 3
* Keep Daily: 7
* Keep Weekly: 4
* Keep Monthly: 6
* Keep Yearly: 1

Successivamente viene eseguita la garbage collection sul datastore configurato:

```bash
proxmox-backup-manager garbage-collection start "$DATASTORE"
```

Prune e garbage collection sono quindi gestiti separatamente dalla creazione dei backup tramite `vzdump`.

### 6. Spegnimento di PBS

Al termine del workflow PBS viene spento remotamente:

```bash
shutdown -h now
```

In questo modo il server di backup rimane spento quando non è necessario.

## Strategia di gestione energetica

L'automazione fa parte di una più ampia strategia di riduzione dei consumi dell'infrastruttura.

### Host principale Proxmox

L'host principale viene spento ogni notte tramite:

```bash
rtcwake -m off -s 25200
```

L'allarme RTC provvede a riaccenderlo dopo circa sette ore.

### Backup server

Il nodo PBS rimane normalmente spento e viene acceso solamente quando viene eseguito il workflow giornaliero di backup.

In questo modo si riducono i consumi durante le ore in cui il server non è necessario, mantenendo comunque un sistema di backup completamente automatizzato.

## Scheduling

Il workflow di backup viene eseguito ogni giorno alle 13:00:

```cron
0 13 * * * /root/power-cycle.sh
```

Il ciclo notturno dell'host principale viene eseguito a mezzanotte:

```cron
00 00 * * * /usr/sbin/rtcwake -m off -s 25200
```

Per un esempio completo consulta [`crontab.example`](crontab.example).

## Relazione con il progetto principale

Questa repository è l'estrazione standalone dell'automazione di backup e gestione energetica implementata nel progetto:

**[`vincenzogautieri/homelab-selfhosted`](https://github.com/vincenzogautieri/homelab-selfhosted)**

Il progetto principale documenta l'intera infrastruttura, inclusi:

* Proxmox VE
* Proxmox Backup Server
* container LXC
* Docker
* Tailscale
* AdGuard Home
* Nginx Proxy Manager
* Nextcloud
* n8n
* Ollama
* strumenti di amministrazione e monitoraggio

Questa repository si concentra esclusivamente sul componente di automazione del backup e del power-cycle.
