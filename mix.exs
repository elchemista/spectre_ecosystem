defmodule SpectreEcosystem.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :spectre_ecosystem,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Spectre.Ecosystem.CLI, name: "spectre-ecosystem"],
      test_coverage: [summary: [threshold: 90]]
    ]
  end

  def application do
    [extra_applications: [:crypto, :inets, :public_key, :ssl]]
  end

  def cli do
    [preferred_envs: [cover: :test]]
  end
end
