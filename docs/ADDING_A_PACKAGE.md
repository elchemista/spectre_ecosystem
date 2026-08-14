# Adding a satellite repository

## Requisiti

Il repository deve:

1. appartenere all'owner del manifest;
2. avere un nome `spectre_*` univoco;
3. avere un branch predefinito esplicito;
4. dichiarare dipendenze soltanto verso il core o altri satellite registrati;
5. contenere `.github/workflows/spectre-compatibility.yml` sul branch predefinito;
6. includere `campaign_id` nel `run-name` del workflow;
7. essere accessibile dalla GitHub App centrale.

## Procedura

1. Aggiungi e prova il workflow nel repository satellite.
2. Installa la GitHub App su quel repository.
3. Aggiungi una voce a `ecosystem.json`.
4. Aggiungi il repository all'elenco contrattuale in
   `test/repository_contract_test.exs`.
5. Aggiorna README e documentazione GitHub.
6. Esegui:

   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test --cover
   ./spectre-ecosystem validate
   GH_TOKEN="$(gh auth token)" ./spectre-ecosystem doctor --github
   ```

7. Avvia una campagna limitata al nuovo repository.
8. Solo dopo il successo, includilo nelle campagne `all`.

Il manifest non accetta comandi, path locali, nomi di runner o variabili
ambiente. Queste scelte appartengono al workflow satellite.
