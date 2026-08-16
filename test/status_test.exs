defmodule Spectre.Ecosystem.StatusTest do
  use ExUnit.Case, async: true

  alias Spectre.Ecosystem.Manifest
  alias Spectre.Ecosystem.Status

  @manifest Path.expand("../ecosystem.json", __DIR__)

  defmodule GitHubStub do
    def resolve_commit(%{head_error: repository}, repository, _ref), do: {:error, :unavailable}

    def resolve_commit(_client, repository, _ref),
      do: {:ok, "head-#{repository_name(repository)}"}

    def file_contents(_client, repository, "mix.exs", _ref) do
      version =
        case repository_name(repository) do
          "spectre" -> "0.3.2"
          name when name in ["spectre_lab", "spectre_ledger"] -> "0.1.0"
          _name -> "0.3.0"
        end

      {:ok, "defmodule Example do\n  @version \"#{version}\"\nend\n"}
    end

    def latest_workflow_run(client, repository, "ci.yml", _branch) do
      name = repository_name(repository)

      case Map.get(client.runs, name, :passing) do
        :missing ->
          {:error, {:github_http_error, 404, "Not Found"}}

        nil ->
          {:ok, nil}

        :stale ->
          {:ok, run(name, "old-sha", "completed", "success")}

        :pending ->
          {:ok, run(name, "head-#{name}", "in_progress", nil)}

        :failing ->
          {:ok, run(name, "head-#{name}", "completed", "failure")}

        :unknown ->
          {:ok, run(name, "head-#{name}", "mystery", nil)}

        :passing ->
          {:ok, run(name, "head-#{name}", "completed", "success")}
      end
    end

    defp run(name, sha, status, conclusion) do
      %{
        "id" => :erlang.phash2(name),
        "head_sha" => sha,
        "status" => status,
        "conclusion" => conclusion,
        "html_url" => "https://github.test/#{name}/runs/latest",
        "created_at" => "2026-08-16T04:00:00Z",
        "updated_at" => "2026-08-16T04:01:00Z"
      }
    end

    defp repository_name(repository), do: repository |> String.split("/") |> List.last()
  end

  defmodule HexStub do
    def latest_stable_version(%{error: package}, package), do: {:error, :unavailable}

    def latest_stable_version(client, package),
      do: {:ok, Map.get(client.versions, package)}
  end

  defmodule NoGitHubCalls do
    def resolve_commit(_client, _repository, _ref), do: raise("unexpected GitHub API call")

    def file_contents(_client, _repository, _path, _ref),
      do: raise("unexpected GitHub API call")

    def latest_workflow_run(_client, _repository, _workflow, _branch),
      do: raise("unexpected GitHub API call")
  end

  test "builds stable website data with CI states and Hex-first versions" do
    assert {:ok, manifest} = Manifest.load(@manifest)

    github = %{
      runs: %{
        "spectre_beam" => :failing,
        "spectre_directive" => :pending,
        "spectre_kinetic" => :stale,
        "spectre_lab" => nil,
        "spectre_ledger" => :missing
      }
    }

    hex = %{versions: %{"spectre" => "0.3.2"}}

    assert {:ok, snapshot} =
             Status.build(manifest, github, hex,
               github_module: GitHubStub,
               hex_module: HexStub,
               generated_at: ~U[2026-08-16 04:37:00Z]
             )

    assert snapshot["schema"] == 1
    assert snapshot["generated_at"] == "2026-08-16T04:37:00Z"
    assert snapshot["status"] == "failing"

    assert snapshot["summary"] == %{
             "total" => 10,
             "passing" => 5,
             "failing" => 1,
             "pending" => 1,
             "stale" => 1,
             "not_run" => 1,
             "not_configured" => 1,
             "unknown" => 0
           }

    spectre = library(snapshot, "spectre")
    assert spectre["version"] == "0.3.2"
    assert spectre["version_source"] == "hex"
    assert spectre["hex_version"] == "0.3.2"
    assert spectre["github_version"] == "0.3.2"
    assert spectre["version_url"] == "https://hex.pm/packages/spectre"
    assert spectre["status"] == "passing"
    assert spectre["check"]["conclusion"] == "success"
    assert spectre["check"]["source"] == "repository_ci"

    beam = library(snapshot, "spectre_beam")
    assert beam["version"] == "0.3.0"
    assert beam["version_source"] == "github"
    assert beam["hex_version"] == nil
    assert beam["github_version"] == "0.3.0"
    assert beam["status"] == "failing"
    assert beam["version_url"] =~ "/blob/head-spectre_beam/mix.exs"

    assert library(snapshot, "spectre_directive")["status"] == "pending"
    assert library(snapshot, "spectre_kinetic")["status"] == "stale"
    assert library(snapshot, "spectre_lab")["status"] == "not_run"

    ledger = library(snapshot, "spectre_ledger")
    assert ledger["status"] == "not_configured"
    assert ledger["check"]["run_id"] == nil
  end

  test "uses central compatibility results as the published library status" do
    assert {:ok, manifest} = Manifest.load(@manifest)

    results =
      [manifest.core | Manifest.ordered_packages(manifest)]
      |> Enum.map(fn component ->
        %{
          "package" => component.name,
          "repository" => component.repository,
          "profile" => "compat",
          "status" => if(component.name == "spectre_beam", do: "failed", else: "passed"),
          "head_sha" => "tested-#{component.name}",
          "github_version" => "0.3.0",
          "spectre_sha" => "tested-spectre",
          "duration_ms" => 1_000,
          "run_url" => "https://github.test/ecosystem/runs/10"
        }
      end)

    assert {:ok, snapshot} =
             Status.build(
               manifest,
               %{runs: %{}},
               %{versions: %{"spectre" => "0.3.2"}},
               github_module: GitHubStub,
               hex_module: HexStub,
               results: results
             )

    assert snapshot["status"] == "failing"
    assert snapshot["summary"]["passing"] == 9
    assert snapshot["summary"]["failing"] == 1

    beam = library(snapshot, "spectre_beam")
    assert beam["status"] == "failing"
    assert beam["head_sha"] == "tested-spectre_beam"
    assert beam["check"]["source"] == "compatibility"
    assert beam["check"]["spectre_sha"] == "tested-spectre"
  end

  test "central results never query GitHub and missing artifacts stay unknown" do
    assert {:ok, manifest} = Manifest.load(@manifest)

    core_result = %{
      "package" => "spectre",
      "status" => "passed",
      "head_sha" => "tested-spectre",
      "github_version" => "0.3.2",
      "spectre_sha" => "tested-spectre"
    }

    assert {:ok, snapshot} =
             Status.build(
               manifest,
               :no_github_client,
               %{versions: %{"spectre" => "0.3.2"}},
               github_module: NoGitHubCalls,
               hex_module: HexStub,
               results: [core_result]
             )

    assert snapshot["status"] == "incomplete"
    assert snapshot["summary"]["passing"] == 1
    assert snapshot["summary"]["unknown"] == 9

    beam = library(snapshot, "spectre_beam")
    assert beam["status"] == "unknown"
    assert beam["head_sha"] == nil
    assert beam["github_version"] == nil
    assert beam["version"] == nil
    assert beam["version_source"] == nil
    assert beam["version_url"] == nil
  end

  test "extracts repository versions without evaluating Mix files" do
    assert Status.github_version("  @version \"1.2.3\"\n") == {:ok, "1.2.3"}

    assert Status.github_version("project: [version: \"ignored\"]\nversion: \"2.0.0\",\n") ==
             {:ok, "2.0.0"}

    assert Status.github_version("version: project_version()") ==
             {:error, :github_version_not_found}
  end

  test "marks a snapshot incomplete when a current run has an unknown state" do
    assert {:ok, manifest} = Manifest.load(@manifest)

    assert {:ok, snapshot} =
             Status.build(
               manifest,
               %{runs: %{"spectre_beam" => :unknown}},
               %{versions: %{}},
               github_module: GitHubStub,
               hex_module: HexStub
             )

    assert snapshot["status"] == "incomplete"
    assert snapshot["summary"]["unknown"] == 1
    assert library(snapshot, "spectre_beam")["status"] == "unknown"
  end

  test "fails the snapshot instead of publishing partial source data" do
    assert {:ok, manifest} = Manifest.load(@manifest)

    assert {:error, {:status_source_failed, "spectre", :github_head, :unavailable}} =
             Status.build(
               manifest,
               %{runs: %{}, head_error: "elchemista/spectre"},
               %{versions: %{}},
               github_module: GitHubStub,
               hex_module: HexStub
             )

    assert {:error, {:status_source_failed, "spectre", :hex_version, :unavailable}} =
             Status.build(
               manifest,
               %{runs: %{}},
               %{versions: %{}, error: "spectre"},
               github_module: GitHubStub,
               hex_module: HexStub
             )
  end

  defp library(snapshot, name),
    do: Enum.find(snapshot["libraries"], &(&1["name"] == name))
end
