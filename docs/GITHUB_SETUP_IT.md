# Configurazione GitHub

La configurazione richiede soltanto GitHub Pages:

1. pubblica questo repository su `main`;
2. apri **Settings > Pages**;
3. in **Build and deployment**, seleziona **GitHub Actions**;
4. apri **Actions > Check and publish ecosystem**;
5. premi **Run workflow** lasciando `spectre_ref: main` e `packages: all`.

Il workflow usa repository pubblici e `contents: read`. Non creare una GitHub
App e non aggiungere `SPECTRE_APP_CLIENT_ID`, `SPECTRE_APP_PRIVATE_KEY` o PAT.

Quando il run termina, verifica:

```text
https://elchemista.github.io/spectre_ecosystem/
https://elchemista.github.io/spectre_ecosystem/status.json
```

GitHub può impiegare alcuni minuti ad attivare Pages al primo deployment.
