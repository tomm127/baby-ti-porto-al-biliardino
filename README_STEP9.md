# Baby ti porto al biliardino — Step 9

## Obiettivo

Questo step prepara l'app per un torneo reale con molti telefoni e per la pubblicazione HTTPS:

- un solo snapshot API per aggiornare un torneo invece di molte query separate;
- cache locale dell'ultimo stato valido del torneo;
- schermate giocatore e TV consultabili durante brevi interruzioni di rete;
- timer che continua localmente mentre internet manca;
- comandi di scrittura bloccati offline per evitare risultati doppi o conflitti;
- risincronizzazione automatica quando torna la rete;
- sincronizzazione dell'orologio del browser con l'ora del server;
- service worker più robusto per aprire la PWA anche senza rete;
- preparazione al deploy su Cloudflare Pages.

## 1. Supabase

Eseguire una sola volta, dopo 006:

`supabase/migrations/007_snapshot_and_clock.sql`

La funzione `get_tournament_snapshot` restituisce con una singola RPC:

- torneo e settings;
- squadre e gironi;
- campi e regole;
- partite e coda;
- classifiche;
- bracket/qualificate;
- squadra associata al dispositivo;
- ora corrente del server.

Questo riduce drasticamente il numero di richieste quando molti telefoni sono collegati.

## 2. Aggiornare il progetto

Copiare i file Step 9 sopra il progetto attuale. `.env.local` non va sostituito.

Poi:

```bash
npm run dev
```

Non ci sono nuove dipendenze npm.

## 3. Test offline locale

1. Aprire un torneo e una partita in corso.
2. Lasciare caricare la pagina almeno una volta online.
3. Disattivare Wi-Fi/rete (oppure DevTools > Network > Offline).
4. La pagina deve rimanere aperta e mostrare `Sei offline`.
5. Il timer deve continuare a scendere.
6. Start/Pausa/Termina/Conferma devono essere disabilitati offline.
7. Riattivare la rete.
8. L'avviso deve sparire e i dati devono aggiornarsi automaticamente.
9. Se il timer è arrivato a zero offline, al ritorno della rete il server passa la partita a `awaiting_result`.

Non accodiamo risultati offline: è intenzionale. Con più telefoni sulla stessa squadra, una coda offline potrebbe causare due risultati concorrenti. L'ultimo stato viene invece mantenuto in lettura e le modifiche riprendono solo dopo la risincronizzazione.

## 4. Build produzione

Con `.env.local` già configurato:

```bash
npm run build
```

Vite crea la cartella `dist/`.

Non caricare mai `.env.local`. Nel build finiscono solo le variabili `VITE_*` necessarie al browser; non devono esserci secret/service-role/VAPID private key.

## 5. Cloudflare Pages — metodo semplice

Per il primo deploy puoi usare Direct Upload:

1. Cloudflare Dashboard > Workers & Pages.
2. Create application > Pages / Drag and drop.
3. Nome progetto, per esempio `baby-ti-porto-al-biliardino`.
4. Carica **la cartella `dist`**, non la cartella sorgente.
5. Deploy.

Otterrai un indirizzo HTTPS `*.pages.dev`, sufficiente per test PWA e Web Push sui telefoni.

Cloudflare Pages tratta automaticamente un progetto con `index.html` e senza `404.html` come SPA, quindi URL come `/admin`, `/tournament/...` e `/screen/...` continuano a funzionare anche dopo un refresh diretto.

### Nota Direct Upload

Cloudflare segnala che un progetto creato come Direct Upload non può essere convertito in seguito allo stesso progetto Git-integrated. Se in futuro vuoi deploy automatici da GitHub, puoi creare un nuovo progetto Pages con Git integration.

## 6. Dopo il primo URL production

In Supabase > Authentication > URL Configuration:

- imposta **Site URL** sul dominio `https://...pages.dev` ottenuto;
- conserva anche il localhost tra gli URL consentiti se continui lo sviluppo locale.

Per l'attuale login password e anonymous auth non è indispensabile a ogni navigazione, ma è importante per futuri reset/inviti email.

## Test tecnici Step 9

- Tournament engine: 9/9.
- Parser TypeScript/TSX: nessun errore sintattico.
- Il build completo va eseguito sul PC dove `npm install` è già disponibile; l'ambiente di generazione non ha completato il download delle dipendenze npm.
