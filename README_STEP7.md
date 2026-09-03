# Baby ti porto al biliardino — Step 7

## Cosa aggiunge

Step 7 rende automatica tutta la fase a eliminazione diretta.

Quando viene confermato l'ultimo risultato dei gironi, il database esegue nella stessa transazione:

1. verifica che ogni partita dei gironi sia `finished` o `forfeit`;
2. calcola la classifica finale di ogni girone con: punti → differenza reti → gol fatti → scontro diretto/mini-classifica → sorteggio stabile;
3. prende le prime `N` di ogni girone;
4. crea il ranking globale usando punti/partita → differenza reti/partita → gol fatti/partita;
5. assegna i seed;
6. porta il numero di posti alla potenza di 2 successiva e assegna i bye alle migliori;
7. crea tutto il bracket;
8. mette in coda solo il primo turno realmente giocabile;
9. assegna i campi liberi e riusa il sistema push di Step 6.

Dopo ogni eliminatoria il vincitore viene propagato automaticamente al turno successivo. Un turno successivo non entra in coda finché il precedente non è completamente concluso.

Se il 3º/4º posto è attivo, viene alimentato automaticamente dalle due perdenti delle semifinali. Con un solo campo viene messo in coda prima della finale.

## UI

Sono state aggiunte:

- `Tabellone` nell'interfaccia giocatore;
- `Tabellone` nell'admin;
- bracket sulla modalità TV quando il torneo passa alla fase eliminatoria;
- ranking globale delle qualificate nell'admin.

## Aggiornamento database

Esegui SOLO la nuova migration, dopo 001, 002, 003 e 004:

`supabase/migrations/005_knockout_engine.sql`

Supabase → SQL Editor → New query → incolla tutto → Run.

Non rieseguire le migration precedenti.

## Aggiornamento frontend

Se usi il pacchetto `baby-biliardino-step7-update.zip`, copia il contenuto sopra la cartella attuale e accetta la sostituzione. `.env.local` non è incluso e quindi non viene sovrascritto.

Poi ferma e riavvia Vite:

```bash
Ctrl+C
npm run dev
```

Non sono state aggiunte dipendenze npm.

## Test consigliato

Crea un torneo piccolo:

- 8 squadre
- 2 gironi da 4
- 2 qualificate per girone
- 2 campi
- timer 1 minuto / target 3 o 5

Completa tutte le 12 partite dei gironi. All'ultimo risultato devono succedere automaticamente queste cose:

- `tournament.phase` passa da `groups` a `knockout`;
- compaiono 4 qualificate nel ranking globale;
- vengono create 2 semifinali + finale (e finalina, se attiva);
- le semifinali entrano in coda e vengono assegnate ai campi;
- dopo entrambe le semifinali, i vincitori entrano in finale;
- le perdenti entrano nella finalina, se attiva;
- dopo l'ultima partita il torneo passa a `completed`.

Per testare i bye usa, ad esempio, 3 gironi × 2 qualificate = 6 qualificate: il sistema crea un bracket da 8 e i seed #1 e #2 saltano il primo turno.

## Sicurezza delle correzioni admin

- Un risultato eliminatorio può essere corretto se il match successivo dipendente non è ancora partito; il partecipante viene propagato di nuovo.
- Una correzione ai gironi dopo la generazione del bracket è permessa solo finché nessuna eliminatoria reale è partita. In quel caso il bracket viene rigenerato automaticamente.
- Se un match successivo è già iniziato, il database blocca la modifica del vincitore invece di corrompere il tabellone.

