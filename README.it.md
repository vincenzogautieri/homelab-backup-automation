# Homelab Power-Cycle Automation

🇬🇧 [Read in English](README.md)

Uno script Bash di automazione che orchestra l'intero ciclo di alimentazione di un homelab basato su Proxmox: l'host principale si sospende e si risveglia da solo secondo una pianificazione notturna, mentre un server di backup separato viene risvegliato on-demand tramite Wake-on-LAN una volta al giorno per eseguire un backup, verificarne l'integrità, liberare spazio disco e spegnersi di nuovo autonomamente. Insieme, queste due pianificazioni mantengono l'intera infrastruttura a un consumo prossimo agli 0 W per circa 23 ore e mezza al giorno.

Originariamente parte di un progetto più ampio di [infrastruttura homelab](https://github.com/vincenzogautieri/homelab-selfhosted); estratto qui come esempio autonomo di automazione e orchestrazione infrastrutturale.

## Cosa fa

Lo script (`power-cycle.sh`) esegue una sequenza fissa di sei passaggi, con gestione degli errori a ogni fase:

1. **Risveglio** — invia un magic packet Wake-on-LAN all'interfaccia di rete del server di backup.
2. **Attesa** — controlla la disponibilità del server via ping per un massimo di 3 minuti; termina con un errore se non risponde in tempo, invece di procedere alla cieca.
3. **Backup** — esegue `vzdump` su tutte le VM/container LXC, con una politica di retention integrata (mantiene gli ultimi 7 giornalieri, 4 settimanali, 1 mensile).
4. **Verifica** — avvia un Verify Job di Proxmox Backup Server per controllare l'integrità a livello di blocco dei dati appena scritti.
5. **Garbage collection** — libera spazio disco rimuovendo fisicamente i blocchi di dati orfani non più referenziati da alcun backup.
6. **Spegnimento** — spegne il server di backup da remoto via SSH, solo dopo che tutti i passaggi precedenti sono andati a buon fine.

## Il quadro generale: un ciclo di alimentazione completamente deterministico

Questo script è metà di una strategia energetica a doppio binario:

- **Host principale**: resta acceso, ma viene messo in sospensione profonda ogni notte (`rtcwake -m off -s 25200`) e si risveglia da solo tramite l'orologio hardware RTC dopo una finestra fissa — di notte non avviene nessun backup o manutenzione, quindi non ha senso tenerlo acceso.
- **Server di backup**: resta completamente spento (0 W) per praticamente tutta la giornata, e viene risvegliato on-demand, una volta al giorno, solo per i pochi minuti necessari a completare i passaggi 1-6 sopra descritti.

Entrambe le pianificazioni sono gestite da cron sull'host principale (vedi `crontab.example`), quindi l'intero ciclo — sospensione, risveglio, backup, verifica, pulizia, spegnimento — non richiede alcun intervento manuale.

## Perché questo design

- **Tolleranza ai guasti anziché esecuzione alla cieca**: lo script non lancia semplicemente comandi sperando che vadano bene; attende attivamente che il server di backup sia raggiungibile prima di toccarlo, e fallisce in modo esplicito (`exit 1`) se non lo è, invece di eseguire comandi di backup contro un server che non è ancora disponibile.
- **Politica di retention idempotente**: il pruning è gestito dal flag nativo `--prune-backups` di `vzdump` invece che da uno script di pulizia separato, mantenendo la logica di retention in un unico punto.
- **Gestione completa del ciclo di vita**: lo script non si limita a "eseguire un backup" — gestisce l'intero ciclo di vita della macchina di destinazione, dall'accensione allo spegnimento, trattando il server di backup come una risorsa on-demand piuttosto che sempre attiva.
- **Osservabilità**: ogni passaggio registra una riga di stato numerata chiaramente (`[1/6]`, `[2/6]`, ...) per rendere immediato capire, dal solo file di log, esattamente dove si sia interrotta un'esecuzione fallita.

## Requisiti

- Un host Proxmox VE (lo script presuppone la disponibilità di `vzdump` e degli strumenti in stile `pct`)
- Una seconda macchina con Proxmox Backup Server (PBS), raggiungibile in rete e configurata per accettare il Wake-on-LAN
- `etherwake` installato sull'host principale (`apt install etherwake`)
- Accesso SSH basato su chiave dall'host principale al server di backup (per permettere l'esecuzione non interattiva)
- Un Verify Job configurato su PBS (va creato prima dalla web UI di PBS, poi se ne annota l'ID)

## Configurazione

1. Copia `power-cycle.sh` sull'host Proxmox principale (es. `/root/power-cycle.sh`) e rendilo eseguibile:
   ```bash
   chmod +x power-cycle.sh
   ```
2. Modifica il blocco di configurazione in cima allo script con i tuoi valori reali:
   ```bash
   PBS_IP="<IP_SERVER_BACKUP>"
   PBS_MAC="<MAC_ADDRESS_SERVER_BACKUP>"
   DATASTORE="backup-datastore"
   VERIFY_JOB_ID="<ID_VERIFY_JOB_PBS>"
   INTERFACE="vmbr0"
   ```
3. Testalo manualmente per primo:
   ```bash
   ./power-cycle.sh
   ```
4. Una volta che gira correttamente dall'inizio alla fine, pianificalo con cron — vedi `crontab.example` per una configurazione pronta da adattare, che copre sia il job di backup sia il ciclo di sospensione notturna dell'host principale.

## Controlli di integrità

- La riga di log `[OK] Server is responding to ping!` dovrebbe apparire ben entro la finestra di 3 minuti (tipicamente dopo 9-12 tentativi di polling) — un'attesa molto più lunga può indicare che il server di backup non si sta risvegliando correttamente dalla sospensione.
- I timestamp nell'interfaccia web di Proxmox Backup Server e nei file di indice sono registrati in UTC (suffisso `Z`) — è un comportamento previsto e non richiede alcuna correzione manuale del fuso orario.
- Poiché l'intero ciclo di vita è gestito da remoto da questo script, le pianificazioni native di PBS per Prune/GC e Verify Jobs possono essere lasciate disabilitate ("No Schedule Set") nella sua web UI — vengono invece attivate on-demand.

## Nota di sicurezza

`PBS_MAC`, `PBS_IP` e `VERIFY_JOB_ID` in questo repository sono placeholder. Sostituiscili con i tuoi valori reali solo in locale — non caricare mai MAC address reali, IP interni o identificativi di infrastruttura su un repository pubblico.
