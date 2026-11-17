defmodule SpectreStackToolsIntegration.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectre_stack_tools_integration,
      version: "0.4.0",
      elixir: "~> 1.19",
      elixirc_paths: ["support"],
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    packages = ~w(kinetic mnemonic lens prism beam directive pulse ledger lab)a

    [spectre_dep()] ++
      Enum.map(packages, fn package ->
        app = String.to_atom("spectre_#{package}")
        {app, path: "../../../#{app}", override: true}
      end)
  end

  defp spectre_dep do
    case System.get_env("SPECTRE_PATH") do
      path when is_binary(path) and path != "" ->
        {:spectre, path: Path.expand(path), override: true}

      _unset ->
        {:spectre, "~> 0.4.0", override: true}
    end
  end
end
