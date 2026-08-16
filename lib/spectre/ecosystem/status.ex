defmodule Spectre.Ecosystem.Status do
  @moduledoc "Builds the public, point-in-time status document for every registered library."

  alias Spectre.Ecosystem.GitHub.Client, as: GitHubClient
  alias Spectre.Ecosystem.Hex.Client, as: HexClient
  alias Spectre.Ecosystem.Manifest

  @ci_workflow "ci.yml"

  @doc "Builds a status snapshot from compatibility results or repository metadata."
  @spec build(Manifest.t(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(manifest, github_client, hex_client, opts \\ []) do
    github_module = Keyword.get(opts, :github_module, GitHubClient)
    hex_module = Keyword.get(opts, :hex_module, HexClient)
    generated_at = Keyword.get_lazy(opts, :generated_at, &DateTime.utc_now/0)
    checks = checks(opts)
    components = [manifest.core | Manifest.ordered_packages(manifest)]

    with {:ok, libraries} <-
           map_components(
             components,
             github_client,
             hex_client,
             github_module,
             hex_module,
             checks
           ) do
      summary = summary(libraries)

      {:ok,
       %{
         "schema" => 1,
         "generated_at" => DateTime.to_iso8601(generated_at),
         "status" => overall_status(summary),
         "summary" => summary,
         "libraries" => libraries
       }}
    end
  end

  @doc "Extracts a Mix project version without executing repository code."
  @spec github_version(binary()) :: {:ok, String.t()} | {:error, :github_version_not_found}
  def github_version(mix_source) when is_binary(mix_source) do
    patterns = [
      ~r/^\s*@version\s+"([^"]+)"\s*$/m,
      ~r/^\s*version:\s*"([^"]+)"(?:,|\s*$)/m
    ]

    Enum.find_value(patterns, {:error, :github_version_not_found}, fn pattern ->
      case Regex.run(pattern, mix_source, capture: :all_but_first) do
        [version] when version != "" -> {:ok, version}
        _no_match -> nil
      end
    end)
  end

  defp map_components(
         components,
         github_client,
         hex_client,
         github_module,
         hex_module,
         checks
       ) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, libraries} ->
      case library(component, github_client, hex_client, github_module, hex_module, checks) do
        {:ok, data} -> {:cont, {:ok, [data | libraries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, libraries} -> {:ok, Enum.reverse(libraries)}
      error -> error
    end
  end

  defp library(component, github_client, hex_client, github_module, hex_module, checks) do
    name = component.name
    result = compatibility_result(checks, name)

    with {:ok, head_sha} <-
           component_head(component, result, checks, github_client, github_module),
         {:ok, github_version} <-
           component_version(
             component,
             result,
             checks,
             head_sha,
             github_client,
             github_module
           ),
         {:ok, hex_version} <-
           source(hex_module.latest_stable_version(hex_client, name), name, :hex_version),
         {:ok, status, check} <-
           check_status(
             checks,
             result,
             github_module,
             github_client,
             component,
             head_sha
           ) do
      effective_version = hex_version || github_version

      version_source =
        cond do
          hex_version -> "hex"
          github_version -> "github"
          true -> nil
        end

      {:ok,
       %{
         "name" => name,
         "repository" => component.repository,
         "repository_url" => "https://github.com/#{component.repository}",
         "default_ref" => component.default_ref,
         "head_sha" => head_sha,
         "status" => status,
         "version" => effective_version,
         "version_source" => version_source,
         "hex_version" => hex_version,
         "github_version" => github_version,
         "version_url" => version_url(component.repository, head_sha, name, version_source),
         "check" => check
       }}
    end
  end

  defp checks(opts) do
    case Keyword.fetch(opts, :results) do
      {:ok, results} -> {:compatibility, Map.new(results, &{&1["package"], &1})}
      :error -> :repository_ci
    end
  end

  defp compatibility_result({:compatibility, results}, name), do: Map.get(results, name)
  defp compatibility_result(:repository_ci, _name), do: nil

  defp component_head(_component, %{"head_sha" => sha}, _checks, _client, _module)
       when is_binary(sha) and sha != "",
       do: {:ok, sha}

  defp component_head(_component, _result, {:compatibility, _results}, _client, _module),
    do: {:ok, nil}

  defp component_head(component, _result, :repository_ci, client, module) do
    source(
      module.resolve_commit(client, component.repository, component.default_ref),
      component.name,
      :github_head
    )
  end

  defp component_version(
         _component,
         %{"github_version" => version},
         _checks,
         _head_sha,
         _client,
         _module
       )
       when is_binary(version) and version != "",
       do: {:ok, version}

  defp component_version(
         _component,
         _result,
         {:compatibility, _results},
         _head_sha,
         _client,
         _module
       ),
       do: {:ok, nil}

  defp component_version(component, _result, :repository_ci, head_sha, client, module) do
    with {:ok, mix_source} <-
           source(
             module.file_contents(client, component.repository, "mix.exs", head_sha),
             component.name,
             :github_mix_file
           ),
         {:ok, version} <-
           source(github_version(mix_source), component.name, :github_version) do
      {:ok, version}
    end
  end

  defp check_status({:compatibility, _results}, result, _module, _client, _component, _sha) do
    status = compatibility_status(result)
    {:ok, status, compatibility_data(result, status)}
  end

  defp check_status(:repository_ci, _result, module, client, component, head_sha) do
    with {:ok, run} <-
           ci_run(
             module,
             client,
             component.repository,
             component.default_ref,
             component.name
           ) do
      status = ci_status(run, head_sha)
      {:ok, status, ci_data(run, status)}
    end
  end

  defp compatibility_status(%{"status" => "passed"}), do: "passing"
  defp compatibility_status(%{"status" => "failed"}), do: "failing"
  defp compatibility_status(_result), do: "unknown"

  defp compatibility_data(nil, status) do
    %{
      "source" => "compatibility",
      "state" => status,
      "profile" => nil,
      "tested_sha" => nil,
      "spectre_sha" => nil,
      "duration_ms" => nil,
      "run_url" => nil
    }
  end

  defp compatibility_data(result, status) do
    %{
      "source" => "compatibility",
      "state" => status,
      "profile" => result["profile"],
      "tested_sha" => result["head_sha"],
      "spectre_sha" => result["spectre_sha"],
      "duration_ms" => result["duration_ms"],
      "run_url" => result["run_url"]
    }
  end

  defp ci_run(github_module, client, repository, branch, name) do
    case github_module.latest_workflow_run(client, repository, @ci_workflow, branch) do
      {:ok, run} -> {:ok, run}
      {:error, {:github_http_error, 404, _message}} -> {:ok, :not_configured}
      {:error, reason} -> source({:error, reason}, name, :github_ci)
    end
  end

  defp ci_status(:not_configured, _head_sha), do: "not_configured"
  defp ci_status(nil, _head_sha), do: "not_run"

  defp ci_status(%{"head_sha" => run_sha}, head_sha) when run_sha != head_sha, do: "stale"

  defp ci_status(%{"status" => status}, _head_sha)
       when status in ["queued", "in_progress", "requested", "waiting", "pending"],
       do: "pending"

  defp ci_status(%{"status" => "completed", "conclusion" => "success"}, _head_sha),
    do: "passing"

  defp ci_status(%{"status" => "completed"}, _head_sha), do: "failing"
  defp ci_status(_run, _head_sha), do: "unknown"

  defp ci_data(:not_configured, status), do: empty_ci(status)
  defp ci_data(nil, status), do: empty_ci(status)

  defp ci_data(run, status) do
    %{
      "source" => "repository_ci",
      "workflow" => @ci_workflow,
      "state" => status,
      "run_status" => run["status"],
      "conclusion" => run["conclusion"],
      "head_sha" => run["head_sha"],
      "run_id" => run["id"],
      "run_url" => run["html_url"],
      "created_at" => run["created_at"],
      "updated_at" => run["updated_at"]
    }
  end

  defp empty_ci(status) do
    %{
      "source" => "repository_ci",
      "workflow" => @ci_workflow,
      "state" => status,
      "run_status" => nil,
      "conclusion" => nil,
      "head_sha" => nil,
      "run_id" => nil,
      "run_url" => nil,
      "created_at" => nil,
      "updated_at" => nil
    }
  end

  defp summary(libraries) do
    counts = libraries |> Enum.map(& &1["status"]) |> Enum.frequencies()

    %{
      "total" => length(libraries),
      "passing" => Map.get(counts, "passing", 0),
      "failing" => Map.get(counts, "failing", 0),
      "pending" => Map.get(counts, "pending", 0),
      "stale" => Map.get(counts, "stale", 0),
      "not_run" => Map.get(counts, "not_run", 0),
      "not_configured" => Map.get(counts, "not_configured", 0),
      "unknown" => Map.get(counts, "unknown", 0)
    }
  end

  defp overall_status(%{"failing" => failing}) when failing > 0, do: "failing"

  defp overall_status(%{"total" => total, "passing" => total}) when total > 0,
    do: "passing"

  defp overall_status(_summary), do: "incomplete"

  defp source({:ok, value}, _name, _source), do: {:ok, value}

  defp source({:error, reason}, name, source),
    do: {:error, {:status_source_failed, name, source, reason}}

  defp version_url(_repository, _sha, name, "hex"), do: "https://hex.pm/packages/#{name}"

  defp version_url(repository, sha, _name, "github"),
    do: "https://github.com/#{repository}/blob/#{sha}/mix.exs"

  defp version_url(_repository, _sha, _name, nil), do: nil
end
