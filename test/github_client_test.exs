defmodule Spectre.Ecosystem.GitHubClientTest do
  use ExUnit.Case, async: false

  alias Spectre.Ecosystem.GitHub.Client
  alias Spectre.Ecosystem.JSON

  test "reads tokens only from standard environment variables" do
    previous_gh = System.get_env("GH_TOKEN")
    previous_github = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("GH_TOKEN", previous_gh)
      restore_env("GITHUB_TOKEN", previous_github)
    end)

    System.delete_env("GITHUB_TOKEN")
    System.put_env("GH_TOKEN", "test-token")
    assert %Client{token: "test-token"} = Client.new()
    assert Client.authenticated?(Client.new())
    refute Client.authenticated?(Client.new(token: ""))
  end

  test "calls repository, release, commit and workflow endpoints" do
    {api, server} =
      start_server(11, fn request ->
        cond do
          request =~ "GET /repos/elchemista/spectre HTTP" ->
            json(200, %{"default_branch" => "main", "topics" => []})

          request =~ "GET /repos/elchemista/spectre/releases/latest HTTP" ->
            json(200, %{"tag_name" => "v0.3.1"})

          request =~ "GET /repos/elchemista/spectre/commits/v0.3.1 HTTP" ->
            json(200, %{"sha" => "abc123"})

          request =~ "GET /repos/elchemista/spectre/contents/mix.exs?" ->
            json(200, %{
              "encoding" => "base64",
              "content" => Base.encode64("@version \"0.3.1\"\n")
            })

          request =~ "GET /repos/elchemista/spectre/actions/workflows/ci.yml/runs?" ->
            assert request =~ "branch=main"
            assert request =~ "event=push"
            json(200, %{"workflow_runs" => [%{"id" => 12, "conclusion" => "success"}]})

          request =~
              "GET /repos/elchemista/spectre_beam/actions/workflows/spectre-compatibility.yml HTTP" ->
            json(200, %{"path" => ".github/workflows/spectre-compatibility.yml"})

          request =~
              "POST /repos/elchemista/spectre_ecosystem/actions/workflows/compatibility.yml/dispatches HTTP" ->
            assert request =~ "return_run_details"
            empty(204)

          request =~
              "GET /repos/elchemista/spectre_ecosystem/actions/workflows/compatibility.yml/runs?" ->
            json(200, %{
              "workflow_runs" => [
                %{"id" => 10, "display_title" => "compatibility:campaign-1 core=abc"}
              ]
            })

          request =~ "GET /repos/elchemista/spectre_ecosystem/actions/runs/10/jobs?" ->
            json(200, %{"jobs" => [%{"name" => "test", "conclusion" => "success"}]})

          request =~ "GET /repos/elchemista/spectre_ecosystem/actions/runs/10 HTTP" ->
            json(200, %{"id" => 10, "status" => "completed", "conclusion" => "success"})

          true ->
            json(404, %{"message" => "unexpected"})
        end
      end)

    client = Client.new(token: "token", api: api)
    assert {:ok, %{"default_branch" => "main"}} = Client.repository(client, "elchemista/spectre")
    assert {:ok, %{"tag_name" => "v0.3.1"}} = Client.latest_release(client, "elchemista/spectre")
    assert {:ok, "abc123"} = Client.resolve_commit(client, "elchemista/spectre", "v0.3.1")

    assert {:ok, "@version \"0.3.1\"\n"} =
             Client.file_contents(client, "elchemista/spectre", "mix.exs", "abc123")

    assert {:ok, %{"id" => 12}} =
             Client.latest_workflow_run(client, "elchemista/spectre", "ci.yml", "main")

    assert {:ok, %{"path" => ".github/workflows/spectre-compatibility.yml"}} =
             Client.workflow(
               client,
               "elchemista/spectre_beam",
               "spectre-compatibility.yml"
             )

    assert {:ok, nil} =
             Client.dispatch_workflow(
               client,
               "elchemista/spectre_ecosystem",
               "compatibility.yml",
               "master",
               %{"campaign_id" => "campaign-1"}
             )

    assert {:ok, %{"id" => 10}} =
             Client.find_campaign_run(
               client,
               "elchemista/spectre_ecosystem",
               "compatibility.yml",
               "campaign-1"
             )

    assert {:ok, [%{"id" => 10}]} =
             Client.recent_workflow_runs(
               client,
               "elchemista/spectre_ecosystem",
               "compatibility.yml"
             )

    assert {:ok, %{"id" => 10}} =
             Client.run(client, "elchemista/spectre_ecosystem", 10)

    assert {:ok, [%{"name" => "test"}]} =
             Client.jobs(client, "elchemista/spectre_ecosystem", 10)

    await_server(server)
  end

  test "handles empty workflow histories and malformed repository files" do
    {api, server} =
      start_server(2, fn request ->
        if request =~ "/contents/" do
          json(200, %{"encoding" => "base64", "content" => "not base64!"})
        else
          json(200, %{"workflow_runs" => []})
        end
      end)

    client = Client.new(api: api)

    assert Client.file_contents(client, "elchemista/spectre", "mix.exs", "main") ==
             {:error, :invalid_github_file}

    assert Client.latest_workflow_run(client, "elchemista/spectre", "ci.yml", "main") ==
             {:ok, nil}

    await_server(server)
  end

  test "waits for GitHub to expose a dispatched campaign" do
    counter = :counters.new(1, [])

    {api, server} =
      start_server(2, fn _request ->
        :counters.add(counter, 1, 1)
        call = :counters.get(counter, 1)

        if call == 1 do
          json(200, %{"workflow_runs" => []})
        else
          json(200, %{
            "workflow_runs" => [
              %{"id" => 22, "display_title" => "compatibility:campaign-22 core=abc"}
            ]
          })
        end
      end)

    assert {:ok, %{"id" => 22}} =
             Client.wait_for_campaign_run(
               Client.new(api: api),
               "elchemista/spectre_beam",
               "spectre-compatibility.yml",
               "campaign-22",
               interval: 1,
               timeout: 100
             )

    await_server(server)
  end

  test "campaign lookup paginates and does not accept identifier substrings" do
    counter = :counters.new(1, [])

    first_page =
      Enum.map(1..100, fn index ->
        %{"id" => index, "display_title" => "compatibility:wanted-extra-#{index} core=abc"}
      end)

    {api, server} =
      start_server(2, fn request ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          json(200, %{"workflow_runs" => first_page})
        else
          assert request =~ "page=2"

          json(200, %{
            "workflow_runs" => [
              %{"id" => 101, "display_title" => "compatibility:wanted core=abc"}
            ]
          })
        end
      end)

    assert {:ok, %{"id" => 101}} =
             Client.find_campaign_run(
               Client.new(api: api),
               "elchemista/spectre_ecosystem",
               "compatibility.yml",
               "wanted"
             )

    await_server(server)
  end

  test "wait returns completed run and jobs" do
    {api, server} =
      start_server(2, fn request ->
        if request =~ "/jobs?" do
          json(200, %{"jobs" => [%{"name" => "compat", "conclusion" => "success"}]})
        else
          json(200, %{"id" => 7, "status" => "completed", "conclusion" => "success"})
        end
      end)

    assert {:ok, %{"id" => 7}, [%{"name" => "compat"}]} =
             Client.wait(Client.new(api: api), "elchemista/spectre_ecosystem", 7,
               interval: 1,
               timeout: 100
             )

    await_server(server)
  end

  test "default wait options complete immediately for already visible runs" do
    {api, discovery_server} =
      start_server(1, fn _request ->
        json(200, %{
          "workflow_runs" => [
            %{"id" => 31, "display_title" => "compatibility:default-contract core=abc"}
          ]
        })
      end)

    assert {:ok, %{"id" => 31}} =
             Client.wait_for_campaign_run(
               Client.new(api: api),
               "elchemista/spectre_beam",
               "spectre-compatibility.yml",
               "default-contract"
             )

    await_server(discovery_server)

    {api, wait_server} =
      start_server(2, fn request ->
        if request =~ "/jobs?" do
          json(200, %{"jobs" => []})
        else
          json(200, %{"id" => 31, "status" => "completed", "conclusion" => "success"})
        end
      end)

    assert {:ok, %{"id" => 31}, []} =
             Client.wait(Client.new(api: api), "elchemista/spectre_beam", 31)

    await_server(wait_server)
  end

  test "wait polls a pending run and enforces both timeout contracts" do
    counter = :counters.new(1, [])

    {api, server} =
      start_server(3, fn request ->
        if request =~ "/jobs?" do
          json(200, %{"jobs" => []})
        else
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            json(200, %{"id" => 7, "status" => "queued"})
          else
            json(200, %{"id" => 7, "status" => "completed", "conclusion" => "success"})
          end
        end
      end)

    assert {:ok, %{"status" => "completed"}, []} =
             Client.wait(Client.new(api: api), "elchemista/spectre_beam", 7,
               interval: 1,
               timeout: 100
             )

    await_server(server)

    {api, server} = start_server(1, fn _request -> json(200, %{"status" => "queued"}) end)

    assert {:error, {:workflow_wait_timeout, 8}} =
             Client.wait(Client.new(api: api), "elchemista/spectre_beam", 8,
               interval: 1,
               timeout: 0
             )

    await_server(server)

    {api, server} = start_server(1, fn _request -> json(200, %{"workflow_runs" => []}) end)

    assert {:error, {:campaign_discovery_timeout, "missing"}} =
             Client.wait_for_campaign_run(
               Client.new(api: api),
               "elchemista/spectre_beam",
               "spectre-compatibility.yml",
               "missing",
               interval: 1,
               timeout: 0
             )

    await_server(server)
  end

  test "reports not-found campaign, HTTP errors and invalid JSON" do
    {api, server} = start_server(1, fn _request -> json(200, %{"workflow_runs" => []}) end)

    assert {:error, {:campaign_run_not_found, "missing"}} =
             Client.find_campaign_run(
               Client.new(api: api),
               "elchemista/spectre_ecosystem",
               "compatibility.yml",
               "missing"
             )

    await_server(server)

    {api, server} = start_server(1, fn _request -> json(403, %{"message" => "forbidden"}) end)

    assert {:error, {:github_http_error, 403, "forbidden"}} =
             Client.repository(Client.new(api: api), "x/y")

    await_server(server)

    {api, server} = start_server(1, fn _request -> {200, "not-json"} end)
    assert {:error, :invalid_github_response} = Client.repository(Client.new(api: api), "x/y")
    await_server(server)

    {api, server} = start_server(1, fn _request -> json(500, %{"detail" => "internal"}) end)

    assert {:error, {:github_http_error, 500, "request_failed"}} =
             Client.repository(Client.new(api: api), "x/y")

    await_server(server)
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
          response = http_response(status, body)
          :ok = :gen_tcp.send(socket, response)
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

    [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp json(status, value), do: {status, JSON.encode(value)}
  defp empty(status), do: {status, ""}
  defp await_server(task), do: assert(:ok == Task.await(task, 3_000))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
