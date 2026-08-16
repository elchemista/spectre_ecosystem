# Satellite compatibility boundary

Non serve un workflow Actions nel repository satellite. Il runner centrale lo
clona e avvia direttamente i normali comandi Mix.

Il solo contratto speciale è `SPECTRE_PATH`: quando è valorizzata, `mix.exs`
deve usare quel checkout per la dipendenza `:spectre`; altrimenti deve
conservare la normale dipendenza Hex.

```elixir
defp spectre_dep do
  case System.get_env("SPECTRE_PATH") do
    path when is_binary(path) and path != "" ->
      {:spectre, path: Path.expand(path, __DIR__), override: true}

    _unset ->
      {:spectre, "~> 0.3.0"}
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
