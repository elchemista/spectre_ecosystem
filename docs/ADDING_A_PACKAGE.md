# Adding a library

## Requisiti

Il repository deve:

1. essere pubblico e appartenere all'owner del manifest;
2. avere un nome `spectre_*` univoco e un `mix.exs` con versione leggibile;
3. passare `mix compile --warnings-as-errors` e `mix test`;
4. usare `SPECTRE_PATH` come override esplicito della dipendenza `:spectre`;
5. dichiarare nel manifest soltanto dipendenze Spectre già registrate.

Non servono GitHub App, secret o workflow satellite.

## Procedura

1. Aggiungi il boundary `SPECTRE_PATH` alla libreria.
2. Provalo localmente contro il checkout corrente del core.
3. Aggiungi la voce a `ecosystem.json`.
4. Aggiorna l'elenco contrattuale in `test/repository_contract_test.exs`.
5. Esegui:

   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test --cover
   ./spectre-ecosystem validate
   ```

6. Avvia il workflow centrale limitando `packages` alla nuova libreria.
7. Dopo il successo, usa nuovamente `packages: all`.
