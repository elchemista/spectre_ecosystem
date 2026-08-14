defmodule Spectre.Ecosystem.ReportTest do
  use ExUnit.Case, async: true

  alias Spectre.Ecosystem.JSON
  alias Spectre.Ecosystem.Report

  @moduletag :tmp_dir

  test "aggregates passed, failed and missing package results", %{tmp_dir: tmp_dir} do
    passed = result("spectre_beam", "passed", [])

    failed =
      result("spectre_pulse", "failed", [
        %{"gate" => "test", "status" => "failed"}
      ])

    File.write!(Path.join(tmp_dir, "beam.json"), JSON.encode_pretty(passed))
    nested = Path.join(tmp_dir, "nested")
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "pulse.json"), JSON.encode_pretty(failed))

    assert {:ok, results} = Report.load_directory(tmp_dir)
    report = Report.build(results, ~w(spectre_beam spectre_pulse spectre_lab))
    assert report["status"] == "failed"
    assert report["passed"] == 1
    assert report["failed"] == ["spectre_pulse"]
    assert report["missing"] == ["spectre_lab"]
    assert report["duplicates"] == []

    markdown = Report.markdown(report)
    assert markdown =~ "Spectre ecosystem compatibility"
    assert markdown =~ "[`spectre_beam`](https://github.test/spectre_beam) | ✅ passed"
    assert markdown =~ "[`spectre_pulse`](https://github.test/spectre_pulse) | ❌ failed"
    assert markdown =~ "`spectre_lab`"
    assert markdown =~ "test"
    assert markdown =~ "https://github.test/spectre_beam"
  end

  test "passes only when every expected package passed" do
    report = Report.build([result("spectre_beam", "passed", [])], ["spectre_beam"])
    assert report["status"] == "passed"
    assert report["failed"] == []
    assert report["missing"] == []
  end

  test "duplicate package artifacts fail closed" do
    duplicated = [result("spectre_beam", "passed", []), result("spectre_beam", "passed", [])]
    report = Report.build(duplicated, ["spectre_beam"])

    assert report["status"] == "failed"
    assert report["duplicates"] == ["spectre_beam"]
    assert Report.markdown(report) =~ "Duplicate results"
  end

  test "rejects corrupt and non-result JSON", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "bad.json"), "{")

    assert {:error, {:invalid_result_file, _path, :invalid_json}} =
             Report.load_directory(tmp_dir)

    File.write!(Path.join(tmp_dir, "bad.json"), JSON.encode_pretty(%{"schema" => 1}))

    assert {:error, {:invalid_result_file, _path, :invalid_result}} =
             Report.load_directory(tmp_dir)
  end

  defp result(package, status, gates) do
    %{
      "schema" => 1,
      "package" => package,
      "repository" => "elchemista/#{package}",
      "status" => status,
      "profile" => "compat",
      "duration_ms" => 65_000,
      "run_url" => "https://github.test/#{package}",
      "gates" => gates
    }
  end
end
