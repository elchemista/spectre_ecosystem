defmodule Spectre.Ecosystem.GitHub.Client do
  @moduledoc """
  Minimal GitHub Actions client used by the CLI.

  Authentication is accepted only through an environment-derived token. Token
  values are never accepted as command-line arguments or included in errors.
  """

  alias Spectre.Ecosystem.JSON

  @api "https://api.github.com"
  @api_version "2026-03-10"

  @enforce_keys [:token]
  defstruct [:token, api: @api]

  @type t :: %__MODULE__{token: String.t() | nil, api: String.t()}

  @doc "Creates a client from an explicit token or the standard token variables."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    token =
      Keyword.get(opts, :token) ||
        present(System.get_env("GH_TOKEN")) ||
        present(System.get_env("GITHUB_TOKEN"))

    api =
      Keyword.get(opts, :api) ||
        present(System.get_env("GITHUB_API_URL")) ||
        @api

    %__MODULE__{token: token, api: api}
  end

  @doc "Returns whether the client has authenticated credentials."
  @spec authenticated?(t()) :: boolean()
  def authenticated?(%__MODULE__{token: token}), do: is_binary(token) and token != ""

  @doc "Gets public metadata for one repository."
  @spec repository(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def repository(client, repository), do: request(client, :get, "/repos/#{repository}")

  @doc "Gets one repository-owned Actions workflow by file name."
  @spec workflow(t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def workflow(client, repository, workflow) do
    request(client, :get, "/repos/#{repository}/actions/workflows/#{workflow}")
  end

  @doc "Gets the latest non-prerelease GitHub release."
  @spec latest_release(t(), String.t()) :: {:ok, map()} | {:error, term()}
  def latest_release(client, repository) do
    request(client, :get, "/repos/#{repository}/releases/latest")
  end

  @doc "Resolves a branch, tag or SHA to the exact commit SHA observed by GitHub."
  @spec resolve_commit(t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_commit(client, repository, ref) do
    encoded_ref = URI.encode_www_form(ref)

    with {:ok, %{"sha" => sha}} <-
           request(client, :get, "/repos/#{repository}/commits/#{encoded_ref}") do
      {:ok, sha}
    end
  end

  @doc "Reads one repository file at an explicit ref."
  @spec file_contents(t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def file_contents(client, repository, path, ref) do
    encoded_path =
      path
      |> String.split("/", trim: true)
      |> Enum.map_join("/", &URI.encode_www_form/1)

    query = URI.encode_query(%{"ref" => ref})

    with {:ok, %{"content" => content, "encoding" => "base64"}}
         when is_binary(content) <-
           request(client, :get, "/repos/#{repository}/contents/#{encoded_path}?#{query}"),
         {:ok, bytes} <- content |> String.replace(~r/\s+/, "") |> Base.decode64() do
      {:ok, bytes}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_github_file}
    end
  end

  @doc "Gets the latest push run for a workflow on one branch."
  @spec latest_workflow_run(t(), String.t(), String.t(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def latest_workflow_run(client, repository, workflow, branch) do
    query =
      URI.encode_query(%{
        "branch" => branch,
        "event" => "push",
        "per_page" => "1"
      })

    with {:ok, %{"workflow_runs" => runs}} when is_list(runs) <-
           request(
             client,
             :get,
             "/repos/#{repository}/actions/workflows/#{workflow}/runs?#{query}"
           ) do
      {:ok, List.first(runs)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_github_response}
    end
  end

  @doc "Dispatches the orchestrator compatibility workflow."
  @spec dispatch_workflow(t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map() | nil} | {:error, term()}
  def dispatch_workflow(client, repository, workflow, ref, inputs) do
    body = %{"ref" => ref, "inputs" => inputs, "return_run_details" => true}
    request(client, :post, "/repos/#{repository}/actions/workflows/#{workflow}/dispatches", body)
  end

  @doc "Finds a recently dispatched run by campaign identifier."
  @spec find_campaign_run(t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def find_campaign_run(client, repository, workflow, campaign_id) do
    find_campaign_page(client, repository, workflow, campaign_id, 1)
  end

  @doc "Waits until GitHub exposes a newly dispatched campaign run."
  @spec wait_for_campaign_run(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_campaign_run(client, repository, workflow, campaign_id, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 120_000)
    interval = Keyword.get(opts, :interval, 2_000)
    find_campaign_loop(client, repository, workflow, campaign_id, deadline, interval)
  end

  @doc "Returns recent workflow-dispatch runs for the orchestrator workflow."
  @spec recent_workflow_runs(t(), String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def recent_workflow_runs(client, repository, workflow) do
    query = URI.encode_query(%{"event" => "workflow_dispatch", "per_page" => "100"})

    with {:ok, %{"workflow_runs" => runs}} <-
           request(
             client,
             :get,
             "/repos/#{repository}/actions/workflows/#{workflow}/runs?#{query}"
           ) do
      {:ok, runs}
    end
  end

  @doc "Gets one workflow run."
  @spec run(t(), String.t(), pos_integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def run(client, repository, run_id) do
    request(client, :get, "/repos/#{repository}/actions/runs/#{run_id}")
  end

  @doc "Gets every job for one workflow run."
  @spec jobs(t(), String.t(), pos_integer() | String.t()) :: {:ok, [map()]} | {:error, term()}
  def jobs(client, repository, run_id) do
    with {:ok, %{"jobs" => jobs}} <-
           request(client, :get, "/repos/#{repository}/actions/runs/#{run_id}/jobs?per_page=100") do
      {:ok, jobs}
    end
  end

  @doc "Waits for a workflow run and returns the final run and jobs."
  @spec wait(t(), String.t(), pos_integer() | String.t(), keyword()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def wait(client, repository, run_id, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 7_200_000)
    interval = Keyword.get(opts, :interval, 10_000)
    wait_loop(client, repository, run_id, deadline, interval)
  end

  @doc "Performs a raw API request and decodes JSON responses."
  @spec request(t(), :get | :post, String.t(), map() | nil) ::
          {:ok, map() | nil} | {:error, term()}
  def request(%__MODULE__{} = client, method, path, body \\ nil) do
    :ok = ensure_http_started()
    url = client.api <> path
    headers = headers(client)
    http_options = [timeout: 30_000, connect_timeout: 10_000, ssl: ssl_options()]
    request_options = [body_format: :binary]

    request =
      case method do
        :get -> {to_charlist(url), headers}
        :post -> {to_charlist(url), headers, ~c"application/json", JSON.encode(body)}
      end

    case :httpc.request(method, request, http_options, request_options) do
      {:ok, {{_version, status, _reason}, _response_headers, response_body}}
      when status in 200..299 ->
        decode_response(response_body)

      {:ok, {{_version, status, _reason}, _response_headers, response_body}} ->
        {:error, {:github_http_error, status, response_message(response_body)}}

      {:error, reason} ->
        {:error, {:github_transport_error, classify_transport(reason)}}
    end
  rescue
    _error -> {:error, :github_client_failure}
  catch
    _kind, _reason -> {:error, :github_client_failure}
  end

  defp wait_loop(client, repository, run_id, deadline, interval) do
    with {:ok, run} <- run(client, repository, run_id) do
      if run["status"] == "completed" do
        with {:ok, jobs} <- jobs(client, repository, run_id), do: {:ok, run, jobs}
      else
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:workflow_wait_timeout, run_id}}
        else
          Process.sleep(interval)
          wait_loop(client, repository, run_id, deadline, interval)
        end
      end
    end
  end

  defp find_campaign_loop(client, repository, workflow, campaign_id, deadline, interval) do
    case find_campaign_run(client, repository, workflow, campaign_id) do
      {:ok, run} ->
        {:ok, run}

      {:error, {:campaign_run_not_found, ^campaign_id}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:campaign_discovery_timeout, campaign_id}}
        else
          Process.sleep(interval)
          find_campaign_loop(client, repository, workflow, campaign_id, deadline, interval)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_campaign_page(client, repository, workflow, campaign_id, page) do
    query =
      URI.encode_query(%{
        "event" => "workflow_dispatch",
        "per_page" => "100",
        "page" => Integer.to_string(page)
      })

    with {:ok, %{"workflow_runs" => runs}} <-
           request(
             client,
             :get,
             "/repos/#{repository}/actions/workflows/#{workflow}/runs?#{query}"
           ) do
      case Enum.find(runs, &campaign_run?(&1, campaign_id)) do
        nil when length(runs) == 100 and page < 10 ->
          find_campaign_page(client, repository, workflow, campaign_id, page + 1)

        nil ->
          {:error, {:campaign_run_not_found, campaign_id}}

        run ->
          {:ok, run}
      end
    end
  end

  defp headers(client) do
    base = [
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"x-github-api-version", to_charlist(@api_version)},
      {~c"user-agent", ~c"spectre-ecosystem-cli"}
    ]

    case client.token do
      token when is_binary(token) and token != "" ->
        [{~c"authorization", to_charlist("Bearer " <> token)} | base]

      _missing ->
        base
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ensure_http_started do
    with {:ok, _applications} <- Application.ensure_all_started(:inets),
         {:ok, _applications} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp decode_response(<<>>), do: {:ok, nil}

  defp decode_response(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_github_response}
    end
  end

  defp response_message(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) -> String.slice(message, 0, 300)
      _other -> "request_failed"
    end
  end

  defp campaign_run?(run, campaign_id) do
    display = run["display_title"] || run["name"] || ""

    String.starts_with?(display, "compatibility:#{campaign_id} ") or
      display == "compatibility:#{campaign_id}"
  end

  defp classify_transport(reason) when is_atom(reason), do: reason
  defp classify_transport({reason, _detail}) when is_atom(reason), do: reason
  defp classify_transport(_reason), do: :request_failed

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
