# Baby ti porto al biliardino — Step 7.1

Questo aggiornamento aggiunge il setup manuale dei gironi e i nomi personalizzati.

## Nuove funzioni

- Nel form **Nuovo torneo** puoi scegliere tra:
  - distribuzione automatica equilibrata;
  - inserimento delle squadre già divise per girone.
- In modalità manuale, **una riga vuota separa un girone dal successivo**.
- Esempio:

```text
Team 1
Team 2

Team 3
Team 4
Team 5

Team 6
```

produce 3 gironi con dimensioni 2 / 3 / 1.
- Il formato PIN continua a funzionare: `Team 1 | 1234`.
- Ogni girone può ricevere un nome personalizzato durante la creazione.
- L'admin può rinominare i gironi anche successivamente dalla pagina **Gironi** cliccando sul nome.
- Nessuna migration Supabase è necessaria: la tabella `groups` supportava già i nomi personalizzati.

## Aggiornamento

Copia i file dell'update sopra il progetto Step 7 e riavvia Vite se necessario:

```bash
npm run dev
```

## Note di validazione

Il sistema impedisce:
- nomi squadra duplicati;
- nomi girone duplicati;
- gironi con meno squadre del numero di qualificate impostato.

Il motore torneo resta invariato e i suoi 9 test continuano a passare.
