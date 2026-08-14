defmodule Spectre.Ecosystem.Report do
  @moduledoc "Builds aggregate compatibility reports from per-package results."

  alias Spectre.Ecosystem.JSON

  @doc "Loads every result JSON file below a directory."
  @spec load_directory(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load_directory(directory) do
    pattern = Path.join([Path.expand(directory), "**", "*.json"])

    pattern
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      with {:ok, bytes} <- File.read(path),
           {:ok, result} <- JSON.decode(bytes),
           :ok <- valid_result(result) do
        {:cont, {:ok, [result | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_result_file, path, reason}}}
      end
    end)
    |> then(fn
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end)
  end

  @doc "Builds a campaign summary and detects missing expected packages."
  @spec build([map()], [String.t()]) :: map()
  def build(results, expected \\ []) do
    by_package = Map.new(results, &{&1["package"], &1})
    missing = Enum.reject(expected, &Map.has_key?(by_package, &1))
    failed = results |> Enum.filter(&(&1["status"] != "passed")) |> Enum.map(& &1["package"])
    duplicates = duplicate_packages(results)

    %{
      "schema" => 1,
      "status" =>
        if(failed == [] and missing == [] and duplicates == [], do: "passed", else: "failed"),
      "total" => length(results),
      "passed" => Enum.count(results, &(&1["status"] == "passed")),
      "failed" => Enum.sort(failed),
      "missing" => Enum.sort(missing),
      "duplicates" => duplicates,
      "packages" => Enum.sort_by(results, & &1["package"])
    }
  end

  @doc "Formats an aggregate report for a GitHub step summary."
  @spec markdown(map()) :: binary()
  def markdown(report) do
    header = [
      "# Spectre ecosystem compatibility\n\n",
      "**Status:** `#{String.upcase(report["status"])}`  \n",
      "**Passed:** #{report["passed"]}/#{report["total"]}\n\n",
      "| Package | Status | Profile | Duration | Failed gate |\n",
      "|---|---:|---|---:|---|\n"
    ]

    rows =
      Enum.map(report["packages"], fn result ->
        failed_gate =
          result
          |> Map.get("gates", [])
          |> Enum.find(&(&1["status"] == "failed"))
          |> case do
            nil -> "—"
            gate -> markdown_link(gate["gate"], gate["url"])
          end

        duration = format_duration(result["duration_ms"] || 0)
        package = markdown_link("`#{result["package"]}`", result["run_url"])

        "| #{package} | #{status_icon(result["status"])} #{result["status"]} | `#{result["profile"]}` | #{duration} | #{failed_gate} |\n"
      end)

    missing =
      case report["missing"] do
        [] -> []
        packages -> ["\n## Missing results\n\n", Enum.map(packages, &"- `#{&1}`\n")]
      end

    duplicates =
      case report["duplicates"] do
        [] -> []
        packages -> ["\n## Duplicate results\n\n", Enum.map(packages, &"- `#{&1}`\n")]
      end

    IO.iodata_to_binary([header, rows, missing, duplicates])
  end

  defp valid_result(%{
         "schema" => 1,
         "package" => package,
         "repository" => repository,
         "profile" => profile,
         "status" => status,
         "duration_ms" => duration,
         "gates" => gates
       })
       when is_binary(package) and is_binary(repository) and is_binary(profile) and
              status in ["passed", "failed"] and is_integer(duration) and duration >= 0 and
              is_list(gates),
       do: :ok

  defp valid_result(_result), do: {:error, :invalid_result}

  defp status_icon("passed"), do: "✅"
  defp status_icon(_status), do: "❌"

  defp duplicate_packages(results) do
    results
    |> Enum.map(& &1["package"])
    |> Enum.frequencies()
    |> Enum.filter(fn {_package, count} -> count > 1 end)
    |> Enum.map(fn {package, _count} -> package end)
    |> Enum.sort()
  end

  defp markdown_link(label, url) when is_binary(url) and url != "", do: "[#{label}](#{url})"
  defp markdown_link(label, _url), do: label

  defp format_duration(milliseconds) when is_integer(milliseconds) do
    seconds = div(milliseconds, 1_000)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end
end
