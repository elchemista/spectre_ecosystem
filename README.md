# Spectre Ecosystem

`spectre_ecosystem` è l'orchestratore indipendente dei test di compatibilità
dell'ecosistema Spectre. Osserva le release GitHub del core, invia un
`workflow_dispatch` ai repository satellite e raccoglie i risultati di GitHub
Actions.

Il confine è intenzionale:

- `spectre` non dipende dall'orchestratore e non contiene hook verso di esso;
- l'orchestratore non modifica, clona o esegue il codice dei satellite;
- ogni satellite possiede il proprio workflow e decide quali test eseguire;
- questo repository conserva solo coordinate GitHub, stato dei run e report;
- il ciclo di distribuzione delle librerie resta fuori da questo progetto.

## Repository registrati

[`ecosystem.json`](ecosystem.json) contiene esattamente:

| Repository | Branch | Dipendenze dell'ecosistema |
|---|---|---|
| `spectre_beam` | `main` | `spectre` |
| `spectre_directive` | `main` | `spectre` |
| `spectre_kinetic` | `main` | `spectre` |
| `spectre_ledger` | `main` | `spectre` |
| `spectre_lab` | `main` | `spectre`, `spectre_ledger` |
| `spectre_lens` | `main` | `spectre` |
| `spectre_mnemonic` | `main` | `spectre` |
| `spectre_prism` | `main` | `spectre` |
| `spectre_pulse` | `main` | core più Beam, Directive, Kinetic, Lens, Mnemonic e Prism |

## Flusso

```text
release GitHub di elchemista/spectre
                 │
                 │ osservata dal repository indipendente
                 ▼
spectre_ecosystem / watch-core.yml
                 │ tag -> SHA esatto
                 ▼
spectre_ecosystem / compatibility.yml
                 │ una dispatch per repository
        ┌────────┼─────────┐
        ▼        ▼         ▼
 spectre_beam spectre_lab spectre_pulse ...
        │        │         │
        └────────┼─────────┘
                 ▼
       report JSON + Markdown con link ai run
```

Il watcher usa l'ID deterministico `core-release-<tag>`. Una release già
osservata non viene inviata di nuovo. Il retry di una campagna fallita richiede
un'azione esplicita.

## Contratto del satellite

Ogni repository registrato deve avere sul branch predefinito:

```text
.github/workflows/spectre-compatibility.yml
```

Il workflow deve accettare quattro input `workflow_dispatch`:

| Input | Significato |
|---|---|
| `spectre_ref` | tag, branch o SHA del core da provare |
| `spectre_repository` | repository del core |
| `campaign_id` | identificatore comune della campagna |
| `profile` | `compat` oppure `full` |

Il `run-name` deve includere `campaign_id`, perché il CLI trova il run appena
creato senza affidarsi a un ritardo fisso. Il satellite può usare runner,
servizi, database e gate differenti: quella configurazione appartiene al
satellite, non al manifest centrale.

Vedi [docs/SATELLITE_WORKFLOW.md](docs/SATELLITE_WORKFLOW.md) per il contratto
completo e un modello iniziale.

### Stato bootstrap iniziale

La verifica GitHub del 14 agosto 2026 rileva che il workflow richiesto non è
ancora presente nei nove repository. `spectre_ledger` e `spectre_lab` hanno già
il boundary `SPECTRE_PATH`; Beam, Directive, Kinetic, Lens, Mnemonic, Prism e
Pulse devono aggiungerlo insieme al workflow. Questa è una modifica posseduta
da ogni satellite, non dal core e non dal runner centrale.

Non abilitare il watcher schedulato finché `doctor --github` non restituisce
tutti i workflow come `ok`.

## CLI

Il progetto non ha dipendenze esterne. Richiede Erlang/OTP 28+ ed Elixir 1.19+.

```bash
MIX_ENV=prod mix escript.build
./spectre-ecosystem help
```

### Validare e pianificare

```bash
./spectre-ecosystem validate
./spectre-ecosystem list
./spectre-ecosystem plan \
  --spectre-ref 0123456789abcdef \
  --profile full \
  --packages all
```

### Avviare una singola compatibilità remota

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem check \
  --package spectre_mnemonic \
  --spectre-ref 0123456789abcdef \
  --profile full \
  --campaign-id manual-core-01234567 \
  --result campaign-results/spectre_mnemonic.json
```

`check` invia e attende il workflow del repository. Non esegue i suoi test nel
processo del CLI.

### Avviare la matrice centrale

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem dispatch \
  --spectre-ref 0123456789abcdef \
  --profile full \
  --packages all \
  --campaign-id manual-core-01234567
```

### Controllare GitHub

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem doctor --github
```

Il doctor esegue soltanto richieste di lettura: verifica repository e presenza
dei workflow, senza avviarli.

## Configurazione GitHub

La configurazione iniziale richiede una GitHub App con accesso limitato ai nove
repository satellite e due valori Actions nel repository centrale. Le istruzioni
UI complete sono in [docs/GITHUB_SETUP_IT.md](docs/GITHUB_SETUP_IT.md).

## Gate di questo repository

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix escript.build
./spectre-ecosystem validate
```

Licenza Apache-2.0: [LICENSE](LICENSE).
