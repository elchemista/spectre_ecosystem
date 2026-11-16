# Architecture

## Flusso centrale

`compatibility.yml` è l'unico workflow di compatibilità e pubblicazione:

```text
ecosystem.json
      │
      ▼
matrice: core + librerie pubbliche
      │ checkout del core, della libreria e dei satelliti richiesti
      │ SPECTRE_PATH e override dei satelliti → checkout coordinati
      ▼
mix deps.get → compile → test
      │
      ▼
artifact JSON per libreria
      │
      ▼
versioni GitHub + Hex → status.json → GitHub Pages
```

La matrice usa runner separati e non condivide build o dipendenze tra
librerie. `fail-fast` è disabilitato per ottenere sempre un risultato completo.

## Confine delle dipendenze

Ogni libreria conserva la normale dipendenza Hex quando `SPECTRE_PATH` non è
impostata. Durante la compatibilità, la stessa dipendenza punta al checkout
centrale con `path:` e `override: true`. Le dipendenze satellite ricevono gli
override `<NOME_PACCHETTO>_PATH` dopo essere state selezionate dai `default_ref`
del registry. Il workflow non riscrive `mix.exs`.

Il catalogo 0.4 fissa core e satelliti a SHA completi pubblicati; il workflow
schedulato usa lo stesso core per default. Il formato accetta anche branch e tag
per campagne esplicite. Gli artifact registrano i commit risolti, compresi i
satelliti transitivi. L'orchestratore resta su `main` per evitare un pin a se stesso.

## Stato pubblico

Il risultato del test determina `status`. Il generatore legge `mix.exs` allo
SHA realmente testato, interroga soltanto Hex e pubblica entrambe le versioni:

- `hex_version` è `null` quando il package non esiste su Hex;
- `github_version` è sempre la versione del checkout GitHub;
- `version` preferisce Hex e usa GitHub come fallback.

Un artifact mancante produce `unknown`; un test fallito produce `failing`.
Anche con librerie fallite, il job di pubblicazione usa gli artifact disponibili
e aggiorna la pagina.

## Sicurezza

Tutti i repository sono pubblici. Il workflow ha soltanto il permesso
`contents: read`; il flusso giornaliero non chiama la GitHub API, nessun
workflow remoto viene avviato e nessuna credenziale cross-repository viene
creata. Il deploy usa `pages: write` e `id-token: write` soltanto nel job
dedicato.
