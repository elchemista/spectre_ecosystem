defmodule Spectre.Ecosystem.CLI do
  @moduledoc """
  Command-line entrypoint for ecosystem metadata and compatibility campaigns.
  """

  alias Spectre.Ecosystem
  alias Spectre.Ecosystem.Campaign
  alias Spectre.Ecosystem.GitHub.Client
  alias Spectre.Ecosystem.Hex.Client, as: HexClient
  alias Spectre.Ecosystem.JSON
  alias Spectre.Ecosystem.Manifest
  alias Spectre.Ecosystem.Report
  alias Spectre.Ecosystem.Status

  @formats ~w(table json github-matrix names markdown)
  @discovery_interval 2_000

  @help """
  Spectre Ecosystem #{Ecosystem.version()}

  Public ecosystem compatibility status.

  Usage:
    spectre-ecosystem validate [--manifest PATH] [--format table|json]
    spectre-ecosystem list [--manifest PATH] [--format table|json]
    spectre-ecosystem plan --spectre-ref REF [--packages all|a,b] [--include-core]
    spectre-ecosystem report --results-dir PATH [options]
    spectre-ecosystem snapshot --results-dir PATH [--output PATH]
    spectre-ecosystem version

  Public status generation needs no cross-repository write permission.
  """

  @check_help """
  Usage:
    spectre-ecosystem check --package NAME --spectre-ref REF [options]
    spectre-ecosystem check --all --spectre-ref REF [options]

  Options:
    --profile compat|full       Satellite-owned compatibility profile
    --campaign-id ID           Stable cross-repository campaign identifier
    --result PATH               Result file for a single package
    --results-dir PATH          Result directory for multiple packages
    --timeout-minutes N         Override wait timeout for this invocation

  The command dispatches .github/workflows/spectre-compatibility.yml in each
  selected repository. It does not run Mix commands or satellite code locally.
  """

  @doc "Escript entrypoint."
  @spec main([String.t()]) :: no_return()
  def main(args), do: System.halt(run(args))

  @doc "Runs one command and returns a process exit code."
  @spec run([String.t()]) :: 0 | 1 | 2 | 3
  def run([]), do: output(@help)
  def run(["help"]), do: output(@help)
  def run(["help", "check"]), do: output(@check_help)
  def run(["help", _command]), do: output(@help)
  def run(["version"]), do: output(Ecosystem.version())
  def run(["version" | _extra]), do: usage_error(:takes_no_options)
  def run(["validate" | args]), do: validate_command(args)
  def run(["list" | args]), do: list_command(args)
  def run(["plan" | args]), do: plan_command(args)
  def run(["check" | args]), do: check_command(args)
  def run(["dispatch" | args]), do: dispatch_command(args)
  def run(["status" | args]), do: status_command(args)
  def run(["watch" | args]), do: watch_command(args)
  def run(["doctor" | args]), do: doctor_command(args)
  def run(["report" | args]), do: report_command(args)
  def run(["snapshot" | args]), do: snapshot_command(args)
  def run([command | _args]), do: usage_error({:unknown_command, command})

  defp validate_command(args) do
    with {:ok, options} <- parse(args, strict: [manifest: :string, format: :string]),
         {:ok, format} <- selected_format(options, ~w(table json), "table"),
         {:ok, manifest} <- load_manifest(options) do
      case format do
        "json" ->
          output_json(%{
            status: :ok,
            schema: 1,
            packages: length(manifest.packages),
            core_repository: manifest.core.repository
          })

        "table" ->
          output("registry valid: #{length(manifest.packages)} repositories")
      end
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp list_command(args) do
    with {:ok, options} <- parse(args, strict: [manifest: :string, format: :string]),
         {:ok, format} <- selected_format(options, ~w(table json), "table"),
         {:ok, manifest} <- load_manifest(options) do
      packages = Manifest.ordered_packages(manifest)

      case format do
        "json" -> output_json(Enum.map(packages, &package_data/1))
        "table" -> output(package_table(packages))
      end
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp plan_command(args) do
    switches = [
      manifest: :string,
      spectre_ref: :string,
      profile: :string,
      packages: :string,
      campaign_id: :string,
      format: :string,
      include_core: :boolean
    ]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, manifest} <- load_manifest(options),
         {:ok, spectre_ref} <- required_option(options, :spectre_ref),
         {:ok, profile} <- profile(manifest, options),
         {:ok, campaign_id} <- campaign_id(options),
         {:ok, selected} <- selected_packages(manifest, Keyword.get(options, :packages, "all")),
         {:ok, format} <- selected_format(options, @formats -- ["markdown"], "table") do
      packages =
        if Keyword.get(options, :include_core, false),
          do: [manifest.core | selected],
          else: selected

      plan = plan_data(manifest, packages, spectre_ref, profile, campaign_id)
      render_plan(plan, format)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp check_command(args) do
    switches = [
      manifest: :string,
      package: :string,
      all: :boolean,
      spectre_ref: :string,
      profile: :string,
      campaign_id: :string,
      result: :string,
      results_dir: :string,
      timeout_minutes: :integer
    ]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, manifest} <- load_manifest(options),
         {:ok, packages} <- check_packages(manifest, options),
         {:ok, spectre_ref} <- required_option(options, :spectre_ref),
         {:ok, profile} <- profile(manifest, options),
         {:ok, campaign_id} <- campaign_id(options),
         :ok <- validate_result_options(packages, options),
         {:ok, client} <- authenticated_client(),
         {:ok, results} <-
           run_remote_checks(
             client,
             manifest,
             packages,
             spectre_ref,
             profile,
             campaign_id,
             options
           ) do
      Enum.each(results, fn result ->
        output("#{result["package"]}: #{result["status"]} #{result["run_url"] || ""}")
      end)

      if Enum.all?(results, &(&1["status"] == "passed")), do: 0, else: 1
    else
      {:error, :github_token_required} -> auth_error(:github_token_required)
      {:error, reason} -> command_error(reason)
    end
  end

  defp dispatch_command(args) do
    switches = [
      manifest: :string,
      spectre_ref: :string,
      profile: :string,
      packages: :string,
      campaign_id: :string
    ]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, manifest} <- load_manifest(options),
         {:ok, spectre_ref} <- required_option(options, :spectre_ref),
         {:ok, profile} <- profile(manifest, options),
         {:ok, campaign_id} <- campaign_id(options),
         {:ok, packages} <-
           selected_package_names(manifest, Keyword.get(options, :packages, "all")),
         {:ok, client} <- authenticated_client(),
         {:ok, _response} <-
           Client.dispatch_workflow(
             client,
             manifest.orchestrator.repository,
             manifest.orchestrator.workflow,
             manifest.orchestrator.default_ref,
             %{
               "spectre_ref" => spectre_ref,
               "profile" => profile,
               "packages" => packages,
               "campaign_id" => campaign_id
             }
           ) do
      output("dispatched #{campaign_id}")
    else
      {:error, :github_token_required} -> auth_error(:github_token_required)
      {:error, reason} -> command_error(reason)
    end
  end

  defp status_command(args) do
    switches = [manifest: :string, campaign_id: :string, format: :string]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, manifest} <- load_manifest(options),
         {:ok, id} <- required_option(options, :campaign_id),
         :ok <- valid_campaign_id(id),
         {:ok, format} <- selected_format(options, ~w(table json), "table"),
         {:ok, client} <- authenticated_client(),
         {:ok, run} <-
           Client.find_campaign_run(
             client,
             manifest.orchestrator.repository,
             manifest.orchestrator.workflow,
             id
           ) do
      data = run_data(run)
      if format == "json", do: output_json(data), else: output(status_table(data))
    else
      {:error, :github_token_required} -> auth_error(:github_token_required)
      {:error, reason} -> command_error(reason)
    end
  end

  defp watch_command(args) do
    switches = [
      manifest: :string,
      profile: :string,
      packages: :string,
      dry_run: :boolean,
      retry_failed: :boolean
    ]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, manifest} <- load_manifest(options),
         {:ok, profile} <- profile(manifest, options),
         {:ok, packages} <-
           selected_package_names(manifest, Keyword.get(options, :packages, "all")),
         {:ok, client} <- authenticated_client(),
         {:ok, release} <- Client.latest_release(client, manifest.core.repository),
         {:ok, tag} <- release_tag(release),
         {:ok, sha} <- Client.resolve_commit(client, manifest.core.repository, tag),
         campaign_id = release_campaign_id(tag),
         {:ok, decision} <- watch_decision(client, manifest, campaign_id, options),
         {:ok, action} <-
           execute_watch(decision, client, manifest, sha, profile, packages, campaign_id, options) do
      output("#{action}: #{campaign_id} core=#{sha}")
    else
      {:error, :github_token_required} -> auth_error(:github_token_required)
      {:error, reason} -> command_error(reason)
    end
  end

  defp doctor_command(args) do
    switches = [manifest: :string, github: :boolean, format: :string]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, format} <- selected_format(options, ~w(table json), "table"),
         {:ok, manifest} <- load_manifest(options),
         {:ok, checks} <- doctor_checks(manifest, options) do
      report = %{
        "schema" => 1,
        "status" => if(Enum.all?(checks, &(&1["status"] == "ok")), do: "ok", else: "error"),
        "checks" => checks
      }

      if format == "json", do: output_json(report), else: output(doctor_table(report))
      if report["status"] == "ok", do: 0, else: 1
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp report_command(args) do
    switches = [
      results_dir: :string,
      expected: :string,
      format: :string,
      output: :string
    ]

    with {:ok, options} <- parse(args, strict: switches),
         {:ok, directory} <- required_option(options, :results_dir),
         {:ok, format} <- selected_format(options, ~w(json markdown), "markdown"),
         {:ok, results} <- Report.load_directory(directory) do
      expected = csv(Keyword.get(options, :expected, ""))
      report = Report.build(results, expected)
      bytes = if format == "json", do: JSON.encode_pretty(report), else: Report.markdown(report)

      case Keyword.fetch(options, :output) do
        {:ok, path} -> File.write!(path, bytes)
        :error -> IO.write(bytes)
      end

      if report["status"] == "passed", do: 0, else: 1
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp snapshot_command(args) do
    with {:ok, options} <-
           parse(args,
             strict: [manifest: :string, results_dir: :string, output: :string]
           ),
         {:ok, manifest} <- load_manifest(options),
         {:ok, directory} <- required_option(options, :results_dir),
         {:ok, results} <- Report.load_directory(directory),
         {:ok, snapshot} <-
           Status.build(manifest, Client.new(), HexClient.new(), results: results),
         bytes = JSON.encode_pretty(snapshot),
         :ok <- write_snapshot(bytes, Keyword.get(options, :output)) do
      0
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp write_snapshot(bytes, nil) do
    IO.write(bytes)
    :ok
  end

  defp write_snapshot(bytes, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      :ok
    else
      {:error, reason} -> {:error, {:snapshot_write_failed, classify_file(reason)}}
    end
  end

  defp run_remote_checks(client, manifest, packages, spectre_ref, profile, campaign_id, options) do
    packages
    |> Enum.reduce_while({:ok, []}, fn package, {:ok, acc} ->
      result = remote_check(client, manifest, package, spectre_ref, profile, campaign_id, options)

      with :ok <- write_result(result, packages, options) do
        {:cont, {:ok, [result | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp remote_check(client, manifest, package, spectre_ref, profile, campaign_id, options) do
    started = System.monotonic_time(:millisecond)
    timeout_minutes = Keyword.get(options, :timeout_minutes, package.timeout_minutes)

    inputs = %{
      "spectre_ref" => spectre_ref,
      "spectre_repository" => manifest.core.repository,
      "campaign_id" => campaign_id,
      "profile" => profile
    }

    outcome =
      with :ok <- valid_timeout(timeout_minutes),
           {:ok, dispatch_response} <-
             Client.dispatch_workflow(
               client,
               package.repository,
               manifest.orchestrator.satellite_workflow,
               package.default_ref,
               inputs
             ),
           {:ok, run} <-
             dispatched_run(
               dispatch_response,
               client,
               package.repository,
               manifest.orchestrator.satellite_workflow,
               campaign_id
             ),
           {:ok, completed, jobs} <-
             Client.wait(client, package.repository, run["id"],
               timeout: timeout_minutes * 60_000,
               interval: 10_000
             ) do
        {:ok, completed, jobs}
      end

    duration = System.monotonic_time(:millisecond) - started
    remote_result(package, campaign_id, spectre_ref, profile, duration, outcome)
  end

  defp dispatched_run(%{"workflow_run_id" => id} = response, _client, _repository, _workflow, _id)
       when is_integer(id) do
    {:ok, %{"id" => id, "html_url" => response["html_url"]}}
  end

  defp dispatched_run(_response, client, repository, workflow, campaign_id) do
    Client.wait_for_campaign_run(client, repository, workflow, campaign_id,
      timeout: 120_000,
      interval: @discovery_interval
    )
  end

  defp remote_result(package, campaign_id, spectre_ref, profile, duration, {:ok, run, jobs}) do
    passed = run["conclusion"] == "success"

    %{
      "schema" => 1,
      "package" => package.name,
      "repository" => package.repository,
      "campaign_id" => campaign_id,
      "profile" => profile,
      "spectre_ref" => spectre_ref,
      "status" => if(passed, do: "passed", else: "failed"),
      "conclusion" => run["conclusion"],
      "run_id" => run["id"],
      "run_url" => run["html_url"],
      "duration_ms" => duration,
      "gates" => Enum.map(jobs, &job_gate/1)
    }
  end

  defp remote_result(package, campaign_id, spectre_ref, profile, duration, {:error, reason}) do
    %{
      "schema" => 1,
      "package" => package.name,
      "repository" => package.repository,
      "campaign_id" => campaign_id,
      "profile" => profile,
      "spectre_ref" => spectre_ref,
      "status" => "failed",
      "conclusion" => "orchestration_error",
      "run_id" => nil,
      "run_url" => nil,
      "duration_ms" => duration,
      "reason_class" => reason_class(reason),
      "gates" => []
    }
  end

  defp job_gate(job) do
    conclusion = job["conclusion"] || "unknown"

    %{
      "gate" => job["name"] || "unnamed",
      "status" => if(conclusion in ["success", "skipped"], do: "passed", else: "failed"),
      "conclusion" => conclusion,
      "url" => job["html_url"]
    }
  end

  defp write_result(result, packages, options) do
    path =
      cond do
        length(packages) == 1 and is_binary(options[:result]) ->
          options[:result]

        is_binary(options[:results_dir]) ->
          Path.join(options[:results_dir], result["package"] <> ".json")

        length(packages) == 1 ->
          nil

        true ->
          Path.join("campaign-results", result["package"] <> ".json")
      end

    if path do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, JSON.encode_pretty(result)) do
        :ok
      else
        {:error, reason} -> {:error, {:result_write_failed, classify_file(reason)}}
      end
    else
      :ok
    end
  end

  defp doctor_checks(manifest, options) do
    base = [check("manifest", "ok", manifest.path)]

    if Keyword.get(options, :github, false) do
      client = Client.new()

      repositories =
        [
          {manifest.core.repository, nil},
          {manifest.orchestrator.repository, manifest.orchestrator.workflow}
        ] ++
          Enum.map(manifest.packages, fn package ->
            {package.repository, manifest.orchestrator.satellite_workflow}
          end)

      checks =
        Enum.flat_map(repositories, fn {repository, workflow} ->
          repository_check = github_repository_check(client, repository)

          if workflow do
            [repository_check, github_workflow_check(client, repository, workflow)]
          else
            [repository_check]
          end
        end)

      {:ok, base ++ checks}
    else
      {:ok, base}
    end
  end

  defp github_repository_check(client, repository) do
    case Client.repository(client, repository) do
      {:ok, data} -> check("repository:#{repository}", "ok", data["default_branch"])
      {:error, reason} -> check("repository:#{repository}", "error", reason_class(reason))
    end
  end

  defp github_workflow_check(client, repository, workflow) do
    case Client.workflow(client, repository, workflow) do
      {:ok, data} -> check("workflow:#{repository}", "ok", data["path"] || workflow)
      {:error, reason} -> check("workflow:#{repository}", "error", reason_class(reason))
    end
  end

  defp check(name, status, detail),
    do: %{"check" => name, "status" => status, "detail" => to_string(detail)}

  defp watch_decision(client, manifest, campaign_id, options) do
    case Client.find_campaign_run(
           client,
           manifest.orchestrator.repository,
           manifest.orchestrator.workflow,
           campaign_id
         ) do
      {:ok, run} ->
        cond do
          run["status"] != "completed" -> {:ok, {:skip, "already-running"}}
          run["conclusion"] == "success" -> {:ok, {:skip, "already-passed"}}
          Keyword.get(options, :retry_failed, false) -> {:ok, :dispatch}
          true -> {:ok, {:skip, "already-failed"}}
        end

      {:error, {:campaign_run_not_found, _id}} ->
        {:ok, :dispatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_watch({:skip, reason}, _client, _manifest, _sha, _profile, _packages, _id, _opts),
    do: {:ok, reason}

  defp execute_watch(:dispatch, client, manifest, sha, profile, packages, campaign_id, opts) do
    if Keyword.get(opts, :dry_run, false) do
      {:ok, "would-dispatch"}
    else
      with {:ok, _response} <-
             Client.dispatch_workflow(
               client,
               manifest.orchestrator.repository,
               manifest.orchestrator.workflow,
               manifest.orchestrator.default_ref,
               %{
                 "spectre_ref" => sha,
                 "profile" => profile,
                 "packages" => packages,
                 "campaign_id" => campaign_id
               }
             ) do
        {:ok, "dispatched"}
      end
    end
  end

  defp release_tag(%{"tag_name" => tag}) when is_binary(tag) and tag != "", do: {:ok, tag}
  defp release_tag(_release), do: {:error, :invalid_core_release}

  defp release_campaign_id(tag) do
    safe = Regex.replace(~r/[^A-Za-z0-9_.-]/, tag, "-")
    "core-release-#{safe}"
  end

  defp check_packages(manifest, options) do
    case {Keyword.get(options, :package), Keyword.get(options, :all, false)} do
      {nil, false} ->
        {:error, :select_package_or_all}

      {nil, true} ->
        Manifest.select_packages(manifest, :all)

      {_package, true} ->
        {:error, :package_and_all_are_mutually_exclusive}

      {name, false} ->
        with {:ok, package} <- Manifest.fetch_package(manifest, name), do: {:ok, [package]}
    end
  end

  defp validate_result_options(packages, options) do
    cond do
      length(packages) > 1 and is_binary(options[:result]) ->
        {:error, :result_requires_single_package}

      is_binary(options[:result]) and is_binary(options[:results_dir]) ->
        {:error, :result_options_conflict}

      true ->
        :ok
    end
  end

  defp selected_packages(manifest, "all"), do: Manifest.select_packages(manifest, :all)
  defp selected_packages(manifest, value), do: Manifest.select_packages(manifest, csv(value))

  defp selected_package_names(manifest, value) do
    with {:ok, packages} <- selected_packages(manifest, value) do
      {:ok, Enum.map_join(packages, ",", & &1.name)}
    end
  end

  defp profile(manifest, options),
    do: Manifest.profile(manifest, Keyword.get(options, :profile, "compat"))

  defp campaign_id(options) do
    value = Keyword.get(options, :campaign_id, Campaign.new_id())
    if Campaign.valid_id?(value), do: {:ok, value}, else: {:error, :invalid_campaign_id}
  end

  defp valid_campaign_id(value) do
    if Campaign.valid_id?(value), do: :ok, else: {:error, :invalid_campaign_id}
  end

  defp plan_data(manifest, packages, spectre_ref, profile, campaign_id) do
    %{
      "schema" => 1,
      "campaign_id" => campaign_id,
      "spectre_ref" => spectre_ref,
      "spectre_repository" => manifest.core.repository,
      "profile" => profile,
      "satellite_workflow" => manifest.orchestrator.satellite_workflow,
      "packages" => Enum.map(packages, &package_data/1)
    }
  end

  defp package_data(package) do
    %{
      "name" => package.name,
      "repository" => package.repository,
      "default_ref" => package.default_ref,
      "dependencies" => package.dependencies,
      "timeout_minutes" => package.timeout_minutes
    }
  end

  defp render_plan(plan, "json"), do: output_json(plan)

  defp render_plan(plan, "github-matrix") do
    include =
      Enum.map(plan["packages"], fn package ->
        Map.merge(package, %{
          "profile" => plan["profile"],
          "campaign_id" => plan["campaign_id"],
          "spectre_ref" => plan["spectre_ref"]
        })
      end)

    output(JSON.encode(%{"include" => include}))
  end

  defp render_plan(plan, "names") do
    output(Enum.map_join(plan["packages"], ",", & &1["name"]))
  end

  defp render_plan(plan, "table") do
    output([
      "campaign: #{plan["campaign_id"]}\n",
      "core: #{plan["spectre_ref"]}\n",
      "profile: #{plan["profile"]}\n\n",
      package_table(plan["packages"])
    ])
  end

  defp package_table(packages) do
    rows =
      Enum.map(packages, fn package ->
        name = field(package, :name)
        repository = field(package, :repository)
        ref = field(package, :default_ref)
        dependencies = field(package, :dependencies) |> Enum.join(",")
        "#{name}\t#{repository}\t#{ref}\t#{dependencies}"
      end)

    Enum.join(["NAME\tREPOSITORY\tREF\tDEPENDS" | rows], "\n")
  end

  defp status_table(data) do
    "campaign: #{data["campaign_id"]}\nstatus: #{data["status"]}\nconclusion: #{data["conclusion"]}\nurl: #{data["url"]}"
  end

  defp run_data(run) do
    %{
      "campaign_id" => run["display_title"] || run["name"],
      "status" => run["status"],
      "conclusion" => run["conclusion"],
      "url" => run["html_url"],
      "id" => run["id"]
    }
  end

  defp doctor_table(report) do
    rows = Enum.map(report["checks"], &"#{&1["check"]}: #{&1["status"]} (#{&1["detail"]})")
    Enum.join(["status: #{report["status"]}" | rows], "\n")
  end

  defp parse(args, opts) do
    case OptionParser.parse(args, opts) do
      {options, [], []} -> {:ok, options}
      {_options, remaining, invalid} -> {:error, {:invalid_options, remaining, invalid}}
    end
  end

  defp load_manifest(options),
    do: Manifest.load(Keyword.get(options, :manifest, Manifest.default_path()))

  defp selected_format(options, allowed, default) do
    value = Keyword.get(options, :format, default)
    if value in allowed, do: {:ok, value}, else: {:error, {:invalid_format, value}}
  end

  defp required_option(options, key) do
    case Keyword.get(options, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_option, key}}
    end
  end

  defp authenticated_client do
    client = Client.new()
    if Client.authenticated?(client), do: {:ok, client}, else: {:error, :github_token_required}
  end

  defp valid_timeout(value) when is_integer(value) and value in 1..50, do: :ok
  defp valid_timeout(_value), do: {:error, :invalid_timeout_minutes}

  defp csv(""), do: []

  defp csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp field(%_module{} = value, key), do: Map.fetch!(value, key)
  defp field(value, key), do: Map.fetch!(value, Atom.to_string(key))

  defp reason_class({:github_http_error, status, _message}), do: "github_http_#{status}"
  defp reason_class({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_class(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_class(_reason), do: "orchestration_error"

  defp classify_file(reason) when is_atom(reason), do: reason
  defp classify_file(_reason), do: :file_error

  defp output(value) do
    IO.puts(value)
    0
  end

  defp output_json(value), do: output(JSON.encode_pretty(value))

  defp usage_error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    2
  end

  defp auth_error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    3
  end

  defp command_error(reason) do
    IO.puts(:stderr, "error: #{inspect(reason)}")
    1
  end
end
