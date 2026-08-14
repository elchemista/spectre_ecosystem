defmodule Spectre.Ecosystem.RepositoryContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Ecosystem.Manifest

  @root Path.expand("..", __DIR__)

  test "project is a dependency-free escript" do
    config = Mix.Project.config()
    assert config[:app] == :spectre_ecosystem
    assert config[:deps] in [nil, []]
    assert get_in(config, [:escript, :main_module]) == Spectre.Ecosystem.CLI
    assert get_in(config, [:escript, :name]) == "spectre-ecosystem"
    refute File.exists?(Path.join(@root, "mix.lock"))
  end

  test "registry contains exactly the requested satellite repositories" do
    assert {:ok, manifest} = Manifest.load(Path.join(@root, "ecosystem.json"))

    assert Enum.sort(Enum.map(manifest.packages, & &1.repository)) ==
             Enum.sort([
               "elchemista/spectre_beam",
               "elchemista/spectre_directive",
               "elchemista/spectre_kinetic",
               "elchemista/spectre_lab",
               "elchemista/spectre_ledger",
               "elchemista/spectre_lens",
               "elchemista/spectre_mnemonic",
               "elchemista/spectre_prism",
               "elchemista/spectre_pulse"
             ])
  end

  test "all external Actions are pinned to full commit SHAs" do
    workflows = Path.wildcard(Path.join(@root, ".github/workflows/*.{yml,yaml}"))
    assert length(workflows) == 3
    action_files = workflows ++ [Path.join(@root, "templates/spectre-compatibility.yml")]

    actions =
      action_files
      |> Enum.flat_map(fn workflow ->
        workflow
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "uses:"))
      end)

    assert actions != []

    assert Enum.all?(actions, fn line ->
             Regex.match?(
               ~r/uses:\s+[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}(?:\s+#.*)?$/,
               line
             )
           end)
  end

  test "central compatibility delegates execution to repository-owned workflows" do
    workflow = File.read!(Path.join(@root, ".github/workflows/compatibility.yml"))
    assert workflow =~ "actions/create-github-app-token@"
    assert workflow =~ "./spectre-ecosystem check"
    assert workflow =~ "matrix.name"
  end

  test "satellite template exposes the complete dispatch contract" do
    template = File.read!(Path.join(@root, "templates/spectre-compatibility.yml"))

    for input <- ~w(spectre_ref spectre_repository campaign_id profile) do
      assert template =~ "#{input}:"
    end

    assert template =~ "run-name: compatibility:${{ inputs.campaign_id }}"
    assert template =~ "SPECTRE_PATH:"
  end

  test "development wrapper is executable" do
    path = Path.join(@root, "bin/spectre-ecosystem")
    assert {:ok, %{type: :regular, mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o111) != 0
  end
end
