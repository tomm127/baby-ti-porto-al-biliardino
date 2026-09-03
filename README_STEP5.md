# Step 5 — app collegata a Supabase

Questa versione sostituisce i dati demo con dati reali.

## 1. Applica le migration

Nel SQL Editor di Supabase esegui in ordine:

1. `supabase/migrations/001_initial_schema.sql`
2. `supabase/migrations/002_live_engine.sql`
3. `supabase/migrations/003_app_connection.sql`

Se 001 e 002 sono già state eseguite, esegui solamente 003.

## 2. Attiva Anonymous Sign-Ins

Supabase Dashboard → Authentication → Providers → Anonymous → Enable.

I giocatori non vedranno account o login: serve solo per dare un'identità sicura al dispositivo.

## 3. Crea l'unico admin

Supabase Dashboard → Authentication → Users → Add user.

Crea un utente con una email tecnica (es. `admin@example.com`) e la password che vorrai usare nell'app.
Poi apri SQL Editor ed esegui, sostituendo l'email:

```sql
insert into public.admin_users (user_id)
select id
from auth.users
where email = 'admin@example.com'
on conflict do nothing;
```

Nell'interfaccia admin verrà richiesta solo la password. L'email tecnica è configurata nell'ambiente dell'app.

## 4. Configura il frontend

Copia `.env.example` in `.env.local` e inserisci i valori del tuo progetto:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
VITE_ADMIN_EMAIL=admin@example.com
```

La publishable key è pensata per stare nel frontend. La protezione dei dati è demandata alle policy RLS.
Non mettere mai una service-role key nel frontend.

## 5. Avvio locale

```bash
npm install
npm run dev
```

Apri l'indirizzo indicato da Vite (normalmente `http://localhost:5173`).

## Cosa funziona in Step 5

- login admin reale con sola password nell'interfaccia;
- creazione torneo;
- inserimento squadre;
- PIN individuali opzionali (`Nome squadra | PIN`);
- distribuzione automatica nei gironi;
- modifica manuale del girone prima dell'avvio;
- campi personalizzati;
- timer/goal target distinti per gironi, knockout e finale;
- generazione calendario round-robin;
- modalità ordine rigida per girone o a rotazione;
- avvio torneo e riempimento automatico dei campi;
- homepage reale con tornei attivi;
- accesso anonimo giocatore;
- scelta/cambio squadra;
- pagina giocatore con prossima partita, numero di partite davanti, classifiche e storico;
- schermata partita con 3-2-1 sincronizzato, timer, pausa, termina e conferma risultato;
- blocco del risultato dopo il primo invio;
- correzione risultato solo admin;
- TV dashboard con campi, timer, coda e classifiche;
- polling leggero delle schermate generali, senza tenere 150 WebSocket aperti.

## Prossimo blocco

Step 6: notifiche “preparatevi” / “tocca a voi”, installazione PWA completa, stato online/offline e sincronizzazione più raffinata.
