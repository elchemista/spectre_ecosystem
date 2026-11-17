# Configurazione GitHub

La configurazione richiede soltanto GitHub Pages:

1. pubblica questo repository su `main`;
2. apri **Settings > Pages**;
3. in **Build and deployment**, seleziona **GitHub Actions**;
4. apri **Actions > Check and publish ecosystem**;
5. premi **Run workflow** lasciando il default `spectre_ref` e `packages: all`
   per verificare i commit congelati della linea 0.4.

Per un controllo diverso puoi inserire un branch, tag o SHA del core. I satelliti
restano quelli fissati in `ecosystem.json`, anche quando cambi questo input.

Il workflow usa repository pubblici e `contents: read`. Non creare una GitHub
App e non aggiungere `SPECTRE_APP_CLIENT_ID`, `SPECTRE_APP_PRIVATE_KEY` o PAT.

Quando il run termina, verifica:

```text
https://elchemista.github.io/spectre_ecosystem/
https://elchemista.github.io/spectre_ecosystem/status.json
```

GitHub può impiegare alcuni minuti ad attivare Pages al primo deployment.
