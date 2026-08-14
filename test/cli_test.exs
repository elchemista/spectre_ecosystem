defmodule Spectre.Ecosystem.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Spectre.Ecosystem.CLI
  alias Spectre.Ecosystem.JSON

  @manifest Path.expand("../ecosystem.json", __DIR__)
  @moduletag :tmp_dir

  test "help and version expose a remote-only command contract" do
    assert capture_stdout(fn -> assert CLI.run([]) == 0 end) =~ "Independent GitHub"

    check_help = capture_stdout(fn -> assert CLI.run(["help", "check"]) == 0 end)
    assert check_help =~ "dispatches"
    assert check_help =~ "does not run Mix commands"
    assert capture_stdout(fn -> assert CLI.run(["version"]) == 0 end) =~ "0.1.0"
    assert capture_stderr(fn -> assert CLI.run(["missing"]) == 2 end) =~ "unknown_command"
  end

  test "validate, list and plan expose repository coordinates only" do
    assert capture_stdout(fn ->
             assert CLI.run(["validate", "--manifest", @manifest]) == 0
           end) =~ "9 repositories"

    json =
      capture_stdout(fn ->
        assert CLI.run(["validate", "--manifest", @manifest, "--format", "json"]) == 0
      end)

    assert {:ok, %{"packages" => 9, "status" => "ok"}} = JSON.decode(json)

    table = capture_stdout(fn -> assert CLI.run(["list", "--manifest", @manifest]) == 0 end)
    assert table =~ "elchemista/spectre_ledger"
    assert table =~ "spectre_pulse"

    names =
      capture_stdout(fn ->
        assert CLI.run([
                 "plan",
                 "--manifest",
                 @manifest,
                 "--spectre-ref",
                 "abc123",
                 "--packages",
                 "spectre_lab,spectre_ledger",
                 "--campaign-id",
                 "test-campaign",
                 "--format",
                 "names"
               ]) == 0
      end)

    assert String.trim(names) == "spectre_ledger,spectre_lab"

    matrix =
      capture_stdout(fn ->
        assert CLI.run([
                 "plan",
                 "--manifest",
                 @manifest,
                 "--spectre-ref",
                 "abc123",
                 "--packages",
                 "spectre_ledger",
                 "--campaign-id",
                 "test-campaign",
                 "--format",
                 "github-matrix"
               ]) == 0
      end)

    assert {:ok, %{"include" => [entry]}} = JSON.decode(matrix)
    assert entry["name"] == "spectre_ledger"
    assert entry["repository"] == "elchemista/spectre_ledger"
    assert entry["profile"] == "compat"
    refute Map.has_key?(entry, "runner")
    refute Map.has_key?(entry, "gates")
  end

  test "check and dispatch require GitHub authentication before remote work" do
    without_tokens(fn ->
      check_error =
        capture_stderr(fn ->
          assert CLI.run([
                   "check",
                   "--manifest",
                   @manifest,
                   "--package",
                   "spectre_beam",
                   "--spectre-ref",
                   "abc123"
                 ]) == 3
        end)

      assert check_error =~ "github_token_required"

      dispatch_error =
        capture_stderr(fn ->
          assert CLI.run([
                   "dispatch",
                   "--manifest",
                   @manifest,
                   "--spectre-ref",
                   "abc123"
                 ]) == 3
        end)

      assert dispatch_error =~ "github_token_required"
    end)
  end

  test "usage errors reject unknown options and ambiguous selection" do
    assert capture_stderr(fn ->
             assert CLI.run(["plan", "--manifest", @manifest, "--format", "xml"]) == 1
           end) =~ "missing_option"

    assert capture_stderr(fn ->
             assert CLI.run(["check", "--manifest", @manifest, "--spectre-ref", "abc"]) == 1
           end) =~ "select_package_or_all"

    assert capture_stderr(fn ->
             assert CLI.run([
                      "check",
                      "--manifest",
                      @manifest,
                      "--all",
                      "--package",
                      "spectre_beam",
                      "--spectre-ref",
                      "abc"
                    ]) == 1
           end) =~ "mutually_exclusive"

    assert capture_stderr(fn ->
             assert CLI.run([
                      "check",
                      "--manifest",
                      @manifest,
                      "--package",
                      "spectre_beam",
                      "--spectre-ref",
                      "abc",
                      "--unexpected",
                      "value"
                    ]) == 1
           end) =~ "invalid_options"
  end

  test "doctor is registry-only unless GitHub inspection is requested" do
    output =
      capture_stdout(fn ->
        assert CLI.run(["doctor", "--manifest", @manifest]) == 0
      end)

    assert output =~ "manifest: ok"
    refute output =~ "repository:elchemista"
  end

  test "check dispatches and observes the satellite workflow through GitHub only", %{
    tmp_dir: tmp_dir
  } do
    {api, server} =
      start_server(3, fn request ->
        cond do
          request =~
              "POST /repos/elchemista/spectre_beam/actions/workflows/spectre-compatibility.yml/dispatches" ->
            assert request =~ "return_run_details"
            json(200, %{"workflow_run_id" => 44, "html_url" => "https://github.test/runs/44"})

          request =~ "GET /repos/elchemista/spectre_beam/actions/runs/44/jobs?" ->
            json(200, %{
              "jobs" => [
                %{
                  "name" => "compatibility",
                  "conclusion" => "success",
                  "html_url" => "https://github.test/jobs/1"
                }
              ]
            })

          request =~ "GET /repos/elchemista/spectre_beam/actions/runs/44 HTTP" ->
            json(200, %{
              "id" => 44,
              "status" => "completed",
              "conclusion" => "success",
              "html_url" => "https://github.test/runs/44"
            })

          true ->
            json(404, %{"message" => "unexpected"})
        end
      end)

    result_path = Path.join(tmp_dir, "beam.json")

    output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "check",
                   "--manifest",
                   @manifest,
                   "--package",
                   "spectre_beam",
                   "--spectre-ref",
                   "abc123",
                   "--profile",
                   "compat",
                   "--campaign-id",
                   "remote-contract",
                   "--result",
                   result_path
                 ]) == 0
        end)
      end)

    assert output =~ "spectre_beam: passed"
    assert {:ok, result} = result_path |> File.read!() |> JSON.decode()
    assert result["status"] == "passed"
    assert result["run_id"] == 44
    assert result["spectre_ref"] == "abc123"

    assert result["gates"] == [
             %{
               "conclusion" => "success",
               "gate" => "compatibility",
               "status" => "passed",
               "url" => "https://github.test/jobs/1"
             }
           ]

    await_server(server)
  end

  test "watch resolves the latest core tag to a SHA before central dispatch" do
    {api, server} =
      start_server(4, fn request ->
        cond do
          request =~ "GET /repos/elchemista/spectre/releases/latest HTTP" ->
            json(200, %{"tag_name" => "v0.3.1"})

          request =~ "GET /repos/elchemista/spectre/commits/v0.3.1 HTTP" ->
            json(200, %{"sha" => String.duplicate("a", 40)})

          request =~
              "GET /repos/elchemista/spectre_ecosystem/actions/workflows/compatibility.yml/runs?" ->
            json(200, %{"workflow_runs" => []})

          request =~
              "POST /repos/elchemista/spectre_ecosystem/actions/workflows/compatibility.yml/dispatches" ->
            assert request =~ String.duplicate("a", 40)
            assert request =~ "core-release-v0.3.1"
            empty(204)

          true ->
            json(404, %{"message" => "unexpected"})
        end
      end)

    output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "watch",
                   "--manifest",
                   @manifest,
                   "--profile",
                   "full",
                   "--packages",
                   "spectre_ledger,spectre_lab"
                 ]) == 0
        end)
      end)

    assert output =~ "dispatched: core-release-v0.3.1"
    assert output =~ String.duplicate("a", 40)
    await_server(server)
  end

  test "dispatch and status operate on the central GitHub workflow" do
    {api, dispatch_server} =
      start_server(1, fn request ->
        assert request =~
                 "POST /repos/elchemista/spectre_ecosystem/actions/workflows/compatibility.yml/dispatches"

        assert request =~ "dispatch-contract"
        assert request =~ "spectre_ledger"
        empty(204)
      end)

    dispatched =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "dispatch",
                   "--manifest",
                   @manifest,
                   "--spectre-ref",
                   "core-sha",
                   "--packages",
                   "spectre_ledger",
                   "--campaign-id",
                   "dispatch-contract"
                 ]) == 0
        end)
      end)

    assert dispatched =~ "dispatched dispatch-contract"
    await_server(dispatch_server)

    {api, status_server} =
      start_server(1, fn request ->
        assert request =~ "/actions/workflows/compatibility.yml/runs?"

        json(200, %{
          "workflow_runs" => [
            %{
              "id" => 88,
              "display_title" => "compatibility:dispatch-contract core=core-sha",
              "status" => "completed",
              "conclusion" => "success",
              "html_url" => "https://github.test/runs/88"
            }
          ]
        })
      end)

    status =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "status",
                   "--manifest",
                   @manifest,
                   "--campaign-id",
                   "dispatch-contract",
                   "--format",
                   "json"
                 ]) == 0
        end)
      end)

    assert {:ok, %{"id" => 88, "conclusion" => "success"}} = JSON.decode(status)
    await_server(status_server)
  end

  test "remote orchestration failures become redacted package results", %{tmp_dir: tmp_dir} do
    {api, server} =
      start_server(1, fn request ->
        assert request =~ "/spectre_beam/actions/workflows/spectre-compatibility.yml/dispatches"
        json(403, %{"message" => "credential detail that must not be copied"})
      end)

    result_path = Path.join(tmp_dir, "failed.json")

    output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "check",
                   "--manifest",
                   @manifest,
                   "--package",
                   "spectre_beam",
                   "--spectre-ref",
                   "core-sha",
                   "--campaign-id",
                   "failed-contract",
                   "--result",
                   result_path
                 ]) == 1
        end)
      end)

    assert output =~ "spectre_beam: failed"
    assert {:ok, result} = result_path |> File.read!() |> JSON.decode()
    assert result["reason_class"] == "github_http_403"
    refute File.read!(result_path) =~ "credential detail"
    await_server(server)
  end

  test "GitHub doctor verifies every repository-owned workflow" do
    {api, server} =
      start_server(21, fn request ->
        if request =~ "/actions/workflows/" do
          json(200, %{"path" => ".github/workflows/remote.yml"})
        else
          json(200, %{"default_branch" => "main"})
        end
      end)

    output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "doctor",
                   "--manifest",
                   @manifest,
                   "--github",
                   "--format",
                   "json"
                 ]) == 0
        end)
      end)

    assert {:ok, report} = JSON.decode(output)
    assert report["status"] == "ok"
    assert length(report["checks"]) == 22
    assert Enum.any?(report["checks"], &(&1["check"] == "workflow:elchemista/spectre_lens"))
    await_server(server)
  end

  test "GitHub doctor reports missing repositories and workflows without executing them" do
    {api, server} =
      start_server(21, fn request ->
        cond do
          request =~ "/spectre_prism HTTP" ->
            json(404, %{"message" => "not found"})

          request =~ "/spectre_lens/actions/workflows/" ->
            json(404, %{"message" => "not found"})

          request =~ "/actions/workflows/" ->
            json(200, %{"path" => ".github/workflows/remote.yml"})

          true ->
            json(200, %{"default_branch" => "main"})
        end
      end)

    output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "doctor",
                   "--manifest",
                   @manifest,
                   "--github",
                   "--format",
                   "json"
                 ]) == 1
        end)
      end)

    assert {:ok, report} = JSON.decode(output)
    assert report["status"] == "error"
    assert Enum.count(report["checks"], &(&1["status"] == "error")) == 2
    assert Enum.all?(report["checks"], &(not String.contains?(&1["detail"], "not found")))
    await_server(server)
  end

  test "watch can observe without dispatch and skips an already passed campaign" do
    {api, dry_server} = watch_server([])

    dry_output =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run(["watch", "--manifest", @manifest, "--dry-run"]) == 0
        end)
      end)

    assert dry_output =~ "would-dispatch: core-release-v0.3.1"
    await_server(dry_server)

    existing = %{
      "id" => 99,
      "display_title" => "compatibility:core-release-v0.3.1 core=abc",
      "status" => "completed",
      "conclusion" => "success"
    }

    {api, passed_server} = watch_server([existing])

    passed_output =
      with_github(api, fn ->
        capture_stdout(fn -> assert CLI.run(["watch", "--manifest", @manifest]) == 0 end)
      end)

    assert passed_output =~ "already-passed: core-release-v0.3.1"
    await_server(passed_server)
  end

  test "watch retries a failed campaign only when explicitly requested" do
    failed = %{
      "id" => 100,
      "display_title" => "compatibility:core-release-v0.3.1 core=abc",
      "status" => "completed",
      "conclusion" => "failure"
    }

    {api, skipped_server} = watch_server([failed])

    skipped =
      with_github(api, fn ->
        capture_stdout(fn -> assert CLI.run(["watch", "--manifest", @manifest]) == 0 end)
      end)

    assert skipped =~ "already-failed: core-release-v0.3.1"
    await_server(skipped_server)

    {api, retry_server} = watch_server([failed])

    retry =
      with_github(api, fn ->
        capture_stdout(fn ->
          assert CLI.run([
                   "watch",
                   "--manifest",
                   @manifest,
                   "--retry-failed",
                   "--dry-run"
                 ]) == 0
        end)
      end)

    assert retry =~ "would-dispatch: core-release-v0.3.1"
    await_server(retry_server)
  end

  test "all plan renderings and list JSON contain only registry data" do
    list_json =
      capture_stdout(fn ->
        assert CLI.run(["list", "--manifest", @manifest, "--format", "json"]) == 0
      end)

    assert {:ok, listed} = JSON.decode(list_json)
    assert length(listed) == 9

    plan_json =
      capture_stdout(fn ->
        assert CLI.run([
                 "plan",
                 "--manifest",
                 @manifest,
                 "--spectre-ref",
                 "abc",
                 "--campaign-id",
                 "render-contract",
                 "--format",
                 "json"
               ]) == 0
      end)

    assert {:ok, %{"satellite_workflow" => "spectre-compatibility.yml"}} =
             JSON.decode(plan_json)

    plan_table =
      capture_stdout(fn ->
        assert CLI.run([
                 "plan",
                 "--manifest",
                 @manifest,
                 "--spectre-ref",
                 "abc",
                 "--campaign-id",
                 "render-contract"
               ]) == 0
      end)

    assert plan_table =~ "campaign: render-contract"
    assert plan_table =~ "elchemista/spectre_pulse"
  end

  test "report writes Markdown and fails for a missing repository result", %{tmp_dir: tmp_dir} do
    results = Path.join(tmp_dir, "results")
    File.mkdir_p!(results)

    File.write!(
      Path.join(results, "beam.json"),
      JSON.encode_pretty(%{
        "schema" => 1,
        "package" => "spectre_beam",
        "repository" => "elchemista/spectre_beam",
        "status" => "passed",
        "profile" => "compat",
        "duration_ms" => 1,
        "run_url" => "https://github.com/elchemista/spectre_beam/actions/runs/1",
        "gates" => []
      })
    )

    output = Path.join(tmp_dir, "report.md")

    assert CLI.run([
             "report",
             "--results-dir",
             results,
             "--expected",
             "spectre_beam,spectre_lab",
             "--output",
             output
           ]) == 1

    assert File.read!(output) =~ "Missing results"
  end

  defp capture_stdout(fun), do: capture_io(fun)
  defp capture_stderr(fun), do: capture_io(:stderr, fun)

  defp without_tokens(fun) do
    previous_gh = System.get_env("GH_TOKEN")
    previous_github = System.get_env("GITHUB_TOKEN")

    try do
      System.delete_env("GH_TOKEN")
      System.delete_env("GITHUB_TOKEN")
      fun.()
    after
      restore_env("GH_TOKEN", previous_gh)
      restore_env("GITHUB_TOKEN", previous_github)
    end
  end

  defp with_github(api, fun) do
    previous_token = System.get_env("GH_TOKEN")
    previous_api = System.get_env("GITHUB_API_URL")

    try do
      System.put_env("GH_TOKEN", "test-token")
      System.put_env("GITHUB_API_URL", api)
      fun.()
    after
      restore_env("GH_TOKEN", previous_token)
      restore_env("GITHUB_API_URL", previous_api)
    end
  end

  defp watch_server(runs) do
    start_server(3, fn request ->
      cond do
        request =~ "/spectre/releases/latest" ->
          json(200, %{"tag_name" => "v0.3.1"})

        request =~ "/spectre/commits/v0.3.1" ->
          json(200, %{"sha" => String.duplicate("b", 40)})

        request =~ "/actions/workflows/compatibility.yml/runs?" ->
          json(200, %{"workflow_runs" => runs})

        true ->
          json(404, %{"message" => "unexpected"})
      end
    end)
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
    case request_complete?(acc) do
      true ->
        {:ok, acc}

      false ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, bytes} -> receive_request(socket, acc <> bytes)
          error -> error
        end
    end
  end

  defp request_complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [headers, body] -> byte_size(body) >= content_length(headers)
      _incomplete -> false
    end
  end

  defp content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(name) == "content-length", do: String.to_integer(String.trim(value))

        _other ->
          nil
      end
    end)
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
  defp empty(status), do: {status, ""}
  defp await_server(task), do: assert(:ok == Task.await(task, 3_000))

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
