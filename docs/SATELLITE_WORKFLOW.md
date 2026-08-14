# Satellite workflow contract

Ogni satellite possiede il modo in cui prova un core specifico. Il repository
centrale conosce soltanto il nome del workflow e quattro input.

## Contratto minimo

Percorso obbligatorio:

```text
.github/workflows/spectre-compatibility.yml
```

Header richiesto:

```yaml
name: Spectre core compatibility
run-name: compatibility:${{ inputs.campaign_id }} core=${{ inputs.spectre_ref }}

on:
  workflow_dispatch:
    inputs:
      spectre_ref:
        required: true
        type: string
      spectre_repository:
        required: true
        type: string
      campaign_id:
        required: true
        type: string
      profile:
        required: true
        type: choice
        options: [compat, full]
```

Il resto del workflow appartiene al satellite. Deve però:

1. ottenere il core da `spectre_repository` allo `spectre_ref` richiesto;
2. collegare quel checkout alla dipendenza `:spectre` del test;
3. eseguire almeno compilazione warning-free e suite;
4. applicare i gate aggiuntivi del profilo `full` definiti dal satellite;
5. fallire il run se un gate fallisce;
6. non chiamare l'orchestratore durante l'esecuzione.

## Boundary della dipendenza core

Il centrale non sostituisce file in `deps/` e non modifica `mix.exs`. Il
satellite deve offrire esplicitamente un override test-only. Conserva il
requirement e le opzioni già possedute dal repository; cambia soltanto la source
quando `SPECTRE_PATH` è valorizzato. Forma indicativa:

```elixir
defp spectre_dep do
  requirement = "~> 0.3.1"

  case System.get_env("SPECTRE_PATH") do
    nil ->
      {:spectre, requirement, only: :test}

    path ->
      {:spectre, requirement, path: path, override: true, only: :test}
  end
end
```

Se il satellite usa `:spectre` anche a runtime, conserva il suo scope originale
in entrambe le clausole. Aggiungi un test isolato che provi sia la selezione
normale sia il path e che continui a far rispettare il requirement di versione.
Non rendere il path implicito cercando directory sorelle: in CI deve essere
selezionato soltanto dalla variabile esplicita.

## Modello del job

Il file completo [templates/spectre-compatibility.yml](../templates/spectre-compatibility.yml)
è una base da copiare e adattare. Presuppone che il `mix.exs` del satellite
riconosca `SPECTRE_PATH` in ambiente CI.

```yaml
permissions:
  contents: read

jobs:
  compatibility:
    runs-on: ubuntu-24.04
    timeout-minutes: 45
    steps:
      - name: Check out satellite
        uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          persist-credentials: false

      - name: Check out requested core
        uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          repository: ${{ inputs.spectre_repository }}
          ref: ${{ inputs.spectre_ref }}
          path: requested-spectre-core
          persist-credentials: false

      - name: Set up Erlang/OTP and Elixir
        uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1
        with:
          elixir-version: "1.19.x"
          otp-version: "28.x"

      - name: Run satellite-owned gates
        env:
          MIX_ENV: test
          SPECTRE_PATH: ${{ github.workspace }}/requested-spectre-core
          COMPATIBILITY_PROFILE: ${{ inputs.profile }}
        run: |
          mix deps.get
          mix format --check-formatted
          mix compile --warnings-as-errors
          if [[ "$COMPATIBILITY_PROFILE" == "full" ]]; then
            mix test --cover
          else
            mix test
          fi
```

Repository con PostgreSQL, più dipendenze Spectre o tool specifici devono
aggiungere setup e gate nel proprio file. Non spostare quelle differenze nel
manifest centrale.

## Test manuale

Dalla scheda Actions del satellite esegui il workflow con:

- `spectre_ref`: uno SHA reale del core;
- `spectre_repository`: `elchemista/spectre`;
- `campaign_id`: `satellite-bootstrap`;
- `profile`: `compat`.

Poi esegui dal repository centrale:

```bash
GH_TOKEN="$(gh auth token)" ./spectre-ecosystem check \
  --package NOME_REPOSITORY \
  --spectre-ref SHA_CORE \
  --campaign-id central-bootstrap
```
