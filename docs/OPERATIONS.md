# Operations

## Prima configurazione

1. Pubblica il workflow sul branch `main`.
2. Apri **Settings > Pages**.
3. Seleziona **GitHub Actions** come sorgente.
4. Avvia **Check and publish ecosystem** manualmente.

Non configurare GitHub App, PAT, repository variable o secret.

## Controllo manuale

Apri **Actions > Check and publish ecosystem > Run workflow**. Il default di
`spectre_ref` è lo SHA del core 0.4 verificato; i satelliti e le loro dipendenze
transitive usano i commit completi in `ecosystem.json`. Anche i run pianificati
selezionano questo insieme congelato. `packages` accetta `all` o nomi separati da
virgole; `full` aggiunge la coverage ai test di compatibilità. Per il core,
aggrega i test in RAM e quelli con proiezione persistita prima di controllare
la soglia; ogni satellite conserva la propria suite e soglia.

Puoi scegliere un branch, tag o altro SHA come override del core. Questo non
modifica i pin satellite: per una nuova combinazione aggiorna esplicitamente
anche i relativi `default_ref`. Gli artifact e il feed conservano i commit
risolti delle dipendenze in `check.dependency_sources`.

Quando aggiorni il core nel catalogo, allinea anche il default e i fallback di
`compatibility.yml`: il test contrattuale controlla che coincidano. Il riferimento
dell'orchestratore rimane `main`, senza un pin circolare al proprio commit.

## Diagnosi

- Un job con il nome di una libreria fallisce quando checkout, dipendenze,
  compilazione o test falliscono. Apri quel job dal link `check.run_url`.
- `hex_version: null` è normale per una libreria non ancora pubblicata.
- `status: unknown` indica un artifact mancante, per esempio dopo una
  cancellazione o un errore del runner prima del test.
- Un errore `status_source_failed` nel publisher giornaliero indica che Hex non
  ha fornito i metadati pubblici necessari; GitHub non viene interrogato via
  API.
- Se il deploy fallisce, verifica che Pages usi GitHub Actions come sorgente.

Il workflow può risultare rosso e pubblicare comunque una pagina valida: il
rosso rappresenta una incompatibilità, non necessariamente un errore del
publisher.

## Endpoint

```text
https://elchemista.github.io/spectre_ecosystem/
https://elchemista.github.io/spectre_ecosystem/status.json
```

Il client deve controllare `generated_at` e trattare come vecchio un feed non
aggiornato entro l'intervallo atteso.
