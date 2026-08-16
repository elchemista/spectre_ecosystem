# Spectre Ecosystem

`spectre_ecosystem` controlla ogni giorno che le librerie Spectre pubbliche
compilino e passino i test insieme al core richiesto. Il risultato viene
pubblicato come pagina HTML e come JSON utilizzabile da qualsiasi sito.

Non servono GitHub App, PAT o secret: il workflow clona repository pubblici e
usa soltanto `contents: read`.

La generazione giornaliera non interroga la GitHub API: SHA e versioni GitHub
arrivano direttamente dai checkout e dagli artifact prodotti dalla matrice.

## Come funziona

Il workflow [`.github/workflows/compatibility.yml`](.github/workflows/compatibility.yml):

1. legge i repository da [`ecosystem.json`](ecosystem.json);
2. clona `spectre` e ogni libreria pubblica;
3. imposta `SPECTRE_PATH` sul checkout del core;
4. esegue `mix deps.get`, compilazione warning-free e test;
5. legge le versioni da `mix.exs` e da Hex;
6. pubblica `index.html` e `status.json` con GitHub Pages.

I job sono indipendenti: una libreria fallita rende rosso il proprio job, ma il
report viene comunque pubblicato e mostra il fallimento.

## Repository

Il registry contiene il core `spectre` e nove librerie:

- `spectre_beam`
- `spectre_directive`
- `spectre_kinetic`
- `spectre_lab`
- `spectre_ledger`
- `spectre_lens`
- `spectre_mnemonic`
- `spectre_prism`
- `spectre_pulse`

## Feed pubblico

Dopo aver selezionato **GitHub Actions** in **Settings > Pages > Build and
deployment**, gli endpoint sono:

```text
https://elchemista.github.io/spectre_ecosystem/
https://elchemista.github.io/spectre_ecosystem/status.json
```

Ogni libreria espone sempre:

- `status`: risultato del controllo centrale;
- `hex_version`: ultima versione Hex stabile, oppure `null`;
- `github_version`: versione dichiarata dal checkout GitHub;
- `version`: versione Hex quando esiste, altrimenti quella GitHub;
- `check.run_url`: link al run che ha prodotto il risultato.

Il campo `generated_at` permette al sito consumatore di rilevare dati vecchi.

## Esecuzione manuale

Da **Actions > Check and publish ecosystem > Run workflow** puoi scegliere:

- `spectre_ref`: branch, tag o SHA del core, normalmente `main`;
- `profile`: `compat` esegue i test, `full` aggiunge la coverage;
- `packages`: `all` oppure una lista separata da virgole.

Il workflow parte anche ogni giorno alle 04:37 UTC e ai push rilevanti su
`main`.

## CLI locale

Il progetto non ha dipendenze esterne e richiede Erlang/OTP 28+ ed Elixir
1.19+.

```bash
MIX_ENV=prod mix escript.build
./spectre-ecosystem validate
./spectre-ecosystem list
./spectre-ecosystem plan --spectre-ref main --include-core --format github-matrix
```

Per generare il feed da risultati già raccolti:

```bash
./spectre-ecosystem snapshot \
  --results-dir compatibility-results \
  --output status.json
```

## Aggiungere una libreria

La libreria deve essere pubblica, essere registrata in `ecosystem.json` e usare
il checkout indicato da `SPECTRE_PATH` quando la variabile è presente. Non deve
avere un workflow speciale. Vedi [docs/ADDING_A_PACKAGE.md](docs/ADDING_A_PACKAGE.md).

## Gate locali

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix escript.build
./spectre-ecosystem validate
```

Licenza Apache-2.0: [LICENSE](LICENSE).
