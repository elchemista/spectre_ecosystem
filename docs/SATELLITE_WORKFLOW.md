# Satellite compatibility boundary

Non serve un workflow Actions nel repository satellite. Il runner centrale lo
clona e avvia direttamente i normali comandi Mix.

Il contratto per il core è `SPECTRE_PATH`: quando è valorizzata, `mix.exs`
deve usare quel checkout per la dipendenza `:spectre`; altrimenti conserva la
normale dipendenza Hex. Prima della pubblicazione 0.4, usa l'override con i
checkout coordinati.

Se la libreria usa altri satelliti, dichiara le dipendenze in `ecosystem.json`
e accetta anche i relativi override `<NOME_PACCHETTO>_PATH`, per esempio
`SPECTRE_LEDGER_PATH`. La matrice risolve i loro `default_ref` dal registry;
non presume che `main` contenga una versione compatibile.

```elixir
defp spectre_dep do
  case System.get_env("SPECTRE_PATH") do
    path when is_binary(path) and path != "" ->
      {:spectre, path: Path.expand(path, __DIR__), override: true}

    _unset ->
      {:spectre, "~> 0.4.0"}
  end
end
```

Conserva opzioni come `only: :test` in entrambe le clausole quando fanno parte
della dipendenza originale. Il path non deve essere cercato implicitamente in
directory sorelle: deve attivarsi soltanto tramite la variabile esplicita.

Verifica locale:

```bash
SPECTRE_PATH=/percorso/al/checkout/spectre MIX_ENV=test mix deps.get
SPECTRE_PATH=/percorso/al/checkout/spectre MIX_ENV=test mix compile --warnings-as-errors
SPECTRE_PATH=/percorso/al/checkout/spectre MIX_ENV=test mix test
```
