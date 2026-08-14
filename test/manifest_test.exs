defmodule Spectre.Ecosystem.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Spectre.Ecosystem.JSON
  alias Spectre.Ecosystem.Manifest

  @manifest Path.expand("../ecosystem.json", __DIR__)
  @packages ~w(
    spectre_beam
    spectre_directive
    spectre_kinetic
    spectre_lab
    spectre_ledger
    spectre_lens
    spectre_mnemonic
    spectre_prism
    spectre_pulse
  )

  test "loads the exact nine-repository registry in dependency order" do
    assert {:ok, manifest} = Manifest.load(@manifest)
    assert manifest.owner == "elchemista"
    assert manifest.core.repository == "elchemista/spectre"
    assert manifest.orchestrator.satellite_workflow == "spectre-compatibility.yml"
    assert manifest.profiles == ~w(compat full)
    assert Enum.sort(Enum.map(manifest.packages, & &1.name)) == Enum.sort(@packages)
    assert {:ok, %{default_ref: "main"}} = Manifest.fetch_package(manifest, "spectre_kinetic")

    ordered = Enum.map(Manifest.ordered_packages(manifest), & &1.name)
    assert index(ordered, "spectre_ledger") < index(ordered, "spectre_lab")
    assert index(ordered, "spectre_beam") < index(ordered, "spectre_pulse")
    assert List.last(ordered) == "spectre_pulse"
  end

  test "fetches components, selects packages and validates profiles" do
    assert {:ok, manifest} = Manifest.load(@manifest)
    assert {:ok, %{name: "spectre"}} = Manifest.fetch_component(manifest, "spectre")
    assert {:ok, pulse} = Manifest.fetch_package(manifest, "spectre_pulse")
    assert "spectre_lens" in pulse.dependencies
    assert {:error, {:unknown_package, "missing"}} = Manifest.fetch_package(manifest, "missing")

    assert {:ok, [beam, pulse]} =
             Manifest.select_packages(manifest, ["spectre_beam", "spectre_pulse"])

    assert beam.name == "spectre_beam"
    assert pulse.name == "spectre_pulse"
    assert {:ok, "compat"} = Manifest.profile(manifest, "compat")
    assert {:error, {:unknown_profile, "missing"}} = Manifest.profile(manifest, "missing")

    assert {:error, {:unknown_packages, ["missing"]}} =
             Manifest.select_packages(manifest, ["missing"])
  end

  test "rejects unsupported schema, unknown keys and missing files", %{tmp_dir: tmp_dir} do
    data = manifest_data!()

    assert {:error, {:manifest_not_found, _path}} =
             Manifest.load(Path.join(tmp_dir, "missing.json"))

    assert_manifest_error(
      tmp_dir,
      Map.put(data, "schema", 99),
      {:unsupported_manifest_schema, 99}
    )

    assert_manifest_error(
      tmp_dir,
      Map.put(data, "surprise", true),
      {:unknown_manifest_keys, :manifest, ["surprise"]}
    )

    invalid_json = Path.join(tmp_dir, "invalid.json")
    File.write!(invalid_json, "{")
    assert {:error, :invalid_json} = Manifest.load(invalid_json)
  end

  test "rejects duplicate repositories, unknown dependencies and cycles", %{tmp_dir: tmp_dir} do
    data = manifest_data!()
    [first, second | _rest] = data["packages"]

    duplicate = put_in(data, ["packages", Access.at(1), "repository"], first["repository"])

    assert_manifest_error(
      tmp_dir,
      duplicate,
      {:duplicate_repositories, [first["repository"]]}
    )

    unknown = put_in(data, ["packages", Access.at(0), "dependencies"], ["spectre_missing"])

    assert_manifest_error(
      tmp_dir,
      unknown,
      {:unknown_dependencies, first["name"], ["spectre_missing"]}
    )

    cyclic =
      data
      |> put_in(["packages", Access.at(0), "dependencies"], [second["name"]])
      |> put_in(["packages", Access.at(1), "dependencies"], [first["name"]])

    assert {:error, {:dependency_cycle, _name}} = load_data(tmp_dir, cyclic)
  end

  test "rejects malformed workflows, profiles and repository ownership", %{tmp_dir: tmp_dir} do
    data = manifest_data!()

    invalid_workflow = put_in(data, ["orchestrator", "satellite_workflow"], "../unsafe.yml")

    assert {:error, {:invalid_orchestrator, :invalid_workflow}} =
             load_data(tmp_dir, invalid_workflow)

    assert_manifest_error(tmp_dir, Map.put(data, "profiles", ["compat"]), :invalid_profiles)
    assert_manifest_error(tmp_dir, Map.put(data, "owner", "-bad"), :invalid_owner)

    wrong_owner = put_in(data, ["packages", Access.at(0), "repository"], "someone/spectre_beam")

    assert {:error, {:invalid_package, "spectre_beam", :invalid_repository}} =
             load_data(tmp_dir, wrong_owner)

    malformed = put_in(data, ["packages", Access.at(0), "repository"], %{"unsafe" => true})

    assert {:error, {:invalid_package, "spectre_beam", :invalid_repository}} =
             load_data(tmp_dir, malformed)
  end

  test "default path resolves the checked-in registry" do
    previous = System.get_env("SPECTRE_ECOSYSTEM_MANIFEST")
    on_exit(fn -> restore_env("SPECTRE_ECOSYSTEM_MANIFEST", previous) end)

    System.put_env("SPECTRE_ECOSYSTEM_MANIFEST", @manifest)
    assert Manifest.default_path() == @manifest
  end

  defp manifest_data!, do: @manifest |> File.read!() |> JSON.decode() |> elem(1)

  defp assert_manifest_error(tmp_dir, data, expected) do
    assert {:error, ^expected} = load_data(tmp_dir, data)
  end

  defp load_data(tmp_dir, data) do
    path = Path.join(tmp_dir, "manifest-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode_pretty(data))
    Manifest.load(path)
  end

  defp index(values, value), do: Enum.find_index(values, &(&1 == value))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
