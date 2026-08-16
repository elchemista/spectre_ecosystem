defmodule Spectre.Ecosystem.Hex.Client do
  @moduledoc "Minimal read-only client for public Hex package metadata."

  alias Spectre.Ecosystem.JSON

  @api "https://hex.pm/api"

  @enforce_keys [:api]
  defstruct [:api]

  @type t :: %__MODULE__{api: String.t()}

  @doc "Creates a client for Hex.pm or an explicitly configured API endpoint."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    api =
      Keyword.get(opts, :api) ||
        present(System.get_env("HEX_API_URL")) ||
        @api

    %__MODULE__{api: String.trim_trailing(api, "/")}
  end

  @doc "Returns the latest stable package version, or nil when it is not published."
  @spec latest_stable_version(t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def latest_stable_version(%__MODULE__{} = client, package) when is_binary(package) do
    path = "/packages/#{URI.encode_www_form(package)}"

    case request(client, path) do
      {:ok, %{"latest_stable_version" => version}}
      when is_binary(version) and version != "" ->
        {:ok, version}

      {:ok, %{"latest_version" => version}} when is_binary(version) and version != "" ->
        {:ok, version}

      {:error, {:hex_http_error, 404, _message}} ->
        {:ok, nil}

      {:ok, _metadata} ->
        {:error, :invalid_hex_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(client, path) do
    :ok = ensure_http_started()
    url = client.api <> path

    headers = [
      {~c"accept", ~c"application/json"},
      {~c"user-agent", ~c"spectre-ecosystem-cli"}
    ]

    http_options = [timeout: 30_000, connect_timeout: 10_000, ssl: ssl_options()]

    case :httpc.request(:get, {to_charlist(url), headers}, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _response_headers, body}} when status in 200..299 ->
        case JSON.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> {:error, :invalid_hex_response}
        end

      {:ok, {{_version, status, _reason}, _response_headers, body}} ->
        {:error, {:hex_http_error, status, response_message(body)}}

      {:error, reason} ->
        {:error, {:hex_transport_error, classify_transport(reason)}}
    end
  rescue
    _error -> {:error, :hex_client_failure}
  catch
    _kind, _reason -> {:error, :hex_client_failure}
  end

  defp ensure_http_started do
    with {:ok, _applications} <- Application.ensure_all_started(:inets),
         {:ok, _applications} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp response_message(body) do
    case JSON.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _other -> "request_failed"
    end
  end

  defp classify_transport(reason) when is_atom(reason), do: reason
  defp classify_transport({reason, _detail}) when is_atom(reason), do: reason
  defp classify_transport(_reason), do: :transport_failure

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
