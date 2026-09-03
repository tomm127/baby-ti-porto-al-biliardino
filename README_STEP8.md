# Step 8 — Admin Control Room

Questo step completa i principali override operativi dell'admin.

## Nuove funzioni

### Squadre
- Aggiunta squadra in un girone anche a torneo già avviato.
- Le nuove partite vengono aggiunte **in fondo** alla coda esistente.
- Rinomina squadra.
- Imposta/cambia/rimuovi PIN individuale.
- Ritira squadra: i risultati conclusi restano, le partite non concluse vengono rimosse.
- Riattiva squadra: le partite mancanti vengono aggiunte in fondo.
- Elimina completamente squadra: vengono rimossi anche i risultati già giocati e la classifica si ricalcola.
- Spostamento forzato di una squadra tra gironi durante la fase a gironi. A torneo live, tutti i risultati di girone di quella squadra vengono rimossi e il nuovo calendario della squadra viene aggiunto in fondo.
- Le modifiche strutturali vengono bloccate dopo la generazione del tabellone eliminatorio per evitare bracket incoerenti.

### Coda live
- Sposta una partita in cima.
- Sposta su/giù di una posizione.
- Manda in fondo.
- Assegna manualmente una partita a un campo libero.

### Partite live
- Rimanda.
- Annulla.
- Sconfitta a tavolino scegliendo la squadra perdente.
- Start/Pausa/Riprendi/Termina restano disponibili come prima.

### Campi
- Aggiungi un campo in qualsiasi momento.
- Rinomina campo.
- Attiva/disattiva campo.
- Se aggiungi/riattivi un campo durante il torneo, il motore gli assegna immediatamente la prima partita in coda.
- Un campo con una partita live non può essere disattivato.

### Impostazioni
L'admin può cambiare durante il torneo:
- qualificate per girone (finché il bracket non è generato),
- pausa timer,
- PIN squadre,
- terzo/quarto posto (finché il bracket non è generato),
- timer e target goal di gironi, eliminatorie, finale e finalina.

Le nuove regole vengono applicate solo alle partite non ancora iniziate. Una partita già in corso mantiene le regole con cui è partita.

## Installazione

1. Copia i file dello Step 8 sopra il progetto Step 7.1.
2. In Supabase → SQL Editor esegui **solo**:

   `supabase/migrations/006_admin_control_room.sql`

3. Riavvia Vite:

```bash
Ctrl + C
npm run dev
```

Non servono nuove variabili `.env` e non servono nuove dipendenze npm.

## Test rapido consigliato

Con un torneo di prova già attivo:
1. sposta la seconda partita della coda in cima;
2. aggiungi un nuovo campo e verifica che riceva la prossima partita;
3. aggiungi una nuova squadra a un girone e verifica che le sue partite compaiano in fondo;
4. ritira la nuova squadra e verifica che le partite non concluse spariscano;
5. cambia il timer dei gironi e verifica che una partita non ancora iniziata riceva la nuova durata.
