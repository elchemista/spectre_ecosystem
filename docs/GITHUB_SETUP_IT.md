# Configurazione GitHub passo per passo

Questa procedura configura `spectre_ecosystem` senza modificare `spectre`. Il
core continua a occuparsi soltanto del proprio codice e delle proprie release.

## 1. Unisci l'orchestratore sul branch predefinito

Nel repository `elchemista/spectre_ecosystem`:

1. pubblica il branch di implementazione;
2. apri una pull request verso `master`;
3. attendi il workflow `CI`;
4. unisci la pull request.

I workflow schedulati e manuali funzionano soltanto quando i file esistono sul
branch predefinito.

## 2. Crea la GitHub App

Nel tuo account GitHub:

1. apri **Settings**;
2. apri **Developer settings**;
3. apri **GitHub Apps**;
4. premi **New GitHub App**;
5. usa un nome univoco, per esempio `Spectre Ecosystem CI`;
6. imposta Homepage URL a `https://github.com/elchemista/spectre_ecosystem`;
7. disabilita **Active** nella sezione Webhook;
8. in **Repository permissions** imposta:

   - **Actions: Read and write**;
   - **Metadata: Read-only**;

9. lascia tutti gli altri repository permission su **No access**;
10. lascia tutti gli user permission su **No access**;
11. scegli **Only on this account**;
12. premi **Create GitHub App**.

Non servono callback URL, OAuth o webhook: l'App viene usata soltanto per token
effimeri durante la matrice.

## 3. Installa l'App sui satellite

Dalla pagina dell'App:

1. apri **Install App**;
2. scegli l'account `elchemista`;
3. seleziona **Only select repositories**;
4. seleziona:

   - `spectre_beam`;
   - `spectre_directive`;
   - `spectre_kinetic`;
   - `spectre_lab`;
   - `spectre_ledger`;
   - `spectre_lens`;
   - `spectre_mnemonic`;
   - `spectre_prism`;
   - `spectre_pulse`;

5. conferma l'installazione.

Non installare l'App su `spectre`: il watcher legge dati pubblici del core e il
core non deve ricevere alcuna integrazione dall'ecosistema.

## 4. Crea la chiave privata e configura Actions

Nella pagina della GitHub App:

1. annota il valore **Client ID**;
2. nella sezione **Private keys**, premi **Generate a private key**;
3. salva il file PEM in un luogo sicuro.

Poi apri `elchemista/spectre_ecosystem`:

1. vai in **Settings > Secrets and variables > Actions**;
2. nella scheda **Variables**, crea `SPECTRE_APP_CLIENT_ID` con il Client ID;
3. nella scheda **Secrets**, crea `SPECTRE_APP_PRIVATE_KEY`;
4. incolla l'intero contenuto PEM, incluse le righe BEGIN e END;
5. elimina copie temporanee non protette della chiave.

La chiave rimane soltanto nel repository centrale. I satellite ricevono una
dispatch GitHub, non la chiave.

## 5. Abilita il watcher interno

In `elchemista/spectre_ecosystem`:

1. apri **Settings > Actions > General**;
2. in **Workflow permissions** seleziona **Read and write permissions**;
3. salva.

Questo consente a `watch-core.yml` di avviare `compatibility.yml` nello stesso
repository. Non concede scrittura sul core o sui satellite.

## 6. Installa il workflow in ogni satellite

Su ciascun branch predefinito deve esistere esattamente:

```text
.github/workflows/spectre-compatibility.yml
```

Parti dal modello descritto in
[SATELLITE_WORKFLOW.md](SATELLITE_WORKFLOW.md), poi adatta servizi e gate al
repository. Il `run-name` deve mantenere `campaign_id`.

Stato bootstrap verificato il 14 agosto 2026:

- `spectre_ledger` e `spectre_lab`: boundary `SPECTRE_PATH` già presente;
- gli altri sette satellite: aggiungere il boundary conservando requirement e
  opzioni della dipendenza esistente;
- tutti e nove: aggiungere il workflow richiesto.

Prima di procedere, verifica manualmente ogni workflow dalla scheda Actions
usando un commit reale del core.

## 7. Verifica la configurazione via CLI

Da un clone di `spectre_ecosystem` con GitHub CLI autenticato:

```bash
MIX_ENV=prod mix escript.build
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem doctor --github
```

Il report deve mostrare `ok` per dieci repository (core più nove satellite), il
workflow centrale e i nove workflow satellite. Il doctor non avvia job.

## 8. Prima campagna manuale

Nel repository centrale:

1. apri **Actions**;
2. seleziona **Spectre ecosystem compatibility**;
3. premi **Run workflow**;
4. compila:

   - `spectre_ref`: SHA esatto del core;
   - `profile`: inizialmente `compat`;
   - `packages`: `all`;
   - `campaign_id`: `bootstrap-core-0-3-1`;

5. avvia il workflow;
6. verifica che ogni job centrale mostri il link al run del satellite;
7. apri il report finale e controlla eventuali risultati mancanti.

## 9. Prova il watcher

1. seleziona **Watch Spectre core releases**;
2. premi **Run workflow**;
3. scegli `dry_run: true`;
4. verifica tag, SHA e campaign ID nel log;
5. ripeti con `dry_run: false` solo quando la campagna manuale è verde.

Il watcher gira anche al minuto 17 di ogni ora. GitHub può ritardare i workflow
schedulati nei periodi di carico.

## 10. Proteggi `master`

In **Settings > Branches** crea una regola per `master`:

1. richiedi una pull request;
2. richiedi il job `Format, compile, tests and CLI contracts`;
3. richiedi branch aggiornato prima del merge;
4. disabilita force push e cancellazione.

## 11. Retry

Per una campagna fallita puoi:

- usare **Re-run failed jobs** sul workflow centrale;
- avviare manualmente il watcher con `retry_failed: true`;
- creare una campagna manuale con un nuovo `campaign_id`.

Il watcher non trasforma automaticamente un fallimento in una nuova campagna.
