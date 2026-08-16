defmodule Spectre.Ecosystem.HexClientTest do
  use ExUnit.Case, async: false

  alias Spectre.Ecosystem.Hex.Client
  alias Spectre.Ecosystem.JSON

  test "reads stable versions, falls back to latest, and treats 404 as unpublished" do
    {api, server} =
      start_server(3, fn request ->
        cond do
          request =~ "GET /packages/stable HTTP" ->
            json(200, %{"latest_stable_version" => "1.2.3", "latest_version" => "2.0.0-rc.1"})

          request =~ "GET /packages/prerelease HTTP" ->
            json(200, %{"latest_version" => "2.0.0-rc.1"})

          request =~ "GET /packages/missing HTTP" ->
            json(404, %{"message" => "Not Found"})
        end
      end)

    client = Client.new(api: api <> "/")
    assert client.api == api
    assert Client.latest_stable_version(client, "stable") == {:ok, "1.2.3"}
    assert Client.latest_stable_version(client, "prerelease") == {:ok, "2.0.0-rc.1"}
    assert Client.latest_stable_version(client, "missing") == {:ok, nil}
    await_server(server)
  end

  test "reports invalid responses and sanitized HTTP failures" do
    {api, server} =
      start_server(4, fn request ->
        cond do
          request =~ "/packages/metadata" -> json(200, %{"name" => "metadata"})
          request =~ "/packages/broken" -> {200, "not-json"}
          request =~ "/packages/failed" -> json(503, %{"detail" => "private detail"})
          request =~ "/packages/message" -> json(429, %{"message" => "rate limited"})
        end
      end)

    client = Client.new(api: api)
    assert Client.latest_stable_version(client, "metadata") == {:error, :invalid_hex_response}
    assert Client.latest_stable_version(client, "broken") == {:error, :invalid_hex_response}

    assert Client.latest_stable_version(client, "failed") ==
             {:error, {:hex_http_error, 503, "request_failed"}}

    assert Client.latest_stable_version(client, "message") ==
             {:error, {:hex_http_error, 429, "rate limited"}}

    await_server(server)
  end

  test "classifies transport failures without exposing connection internals" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, {:hex_transport_error, reason}} =
             Client.latest_stable_version(
               Client.new(api: "http://127.0.0.1:#{port}"),
               "unreachable"
             )

    assert is_atom(reason)
  end

  test "uses the configured Hex API environment" do
    previous = System.get_env("HEX_API_URL")

    on_exit(fn -> restore_env("HEX_API_URL", previous) end)

    System.put_env("HEX_API_URL", "https://hex.test/api/")
    assert Client.new().api == "https://hex.test/api"

    System.put_env("HEX_API_URL", "   ")
    assert Client.new().api == "https://hex.pm/api"
  end

  defp start_server(count, responder) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        Enum.each(1..count, fn _index ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, request} = receive_request(socket, "")
          {status, body} = responder.(request)
          :ok = :gen_tcp.send(socket, http_response(status, body))
          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp receive_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, bytes} -> receive_request(socket, acc <> bytes)
        error -> error
      end
    end
  end

  defp http_response(status, body) do
    reason = if status in 200..299, do: "OK", else: "Error"

    IO.iodata_to_binary([
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end

  defp json(status, value), do: {status, JSON.encode(value)}
  defp await_server(task), do: assert(:ok == Task.await(task, 3_000))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
