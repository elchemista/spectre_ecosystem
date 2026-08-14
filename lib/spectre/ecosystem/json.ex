defmodule Spectre.Ecosystem.JSON do
  @moduledoc false

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_json}
  def decode(bytes) when is_binary(bytes) do
    {:ok, :json.decode(bytes)}
  rescue
    _error -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  @spec encode(term()) :: binary()
  def encode(value) do
    value
    |> normalize_for_json()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @spec encode_pretty(term()) :: binary()
  def encode_pretty(value) do
    value
    |> normalize_for_json()
    |> pretty(0)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp normalize_for_json(%_module{} = struct),
    do: struct |> Map.from_struct() |> normalize_for_json()

  defp normalize_for_json(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_for_json(value)} end)
  end

  defp normalize_for_json(list) when is_list(list), do: Enum.map(list, &normalize_for_json/1)
  defp normalize_for_json(nil), do: :null
  defp normalize_for_json(:null), do: :null
  defp normalize_for_json(value) when is_boolean(value), do: value
  defp normalize_for_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_for_json(value), do: value

  defp pretty(map, indent) when is_map(map) do
    entries = Enum.sort_by(map, fn {key, _value} -> key end)

    case entries do
      [] -> "{}"
      _entries -> ["{\n", join_entries(entries, indent), "\n", spaces(indent), "}"]
    end
  end

  defp pretty(list, indent) when is_list(list) do
    case list do
      [] -> "[]"
      _items -> ["[\n", join_items(list, indent), "\n", spaces(indent), "]"]
    end
  end

  defp pretty(value, _indent), do: :json.encode(value)

  defp join_entries(entries, indent) do
    next = indent + 2

    entries
    |> Enum.map(fn {key, value} ->
      [spaces(next), :json.encode(key), ": ", pretty(value, next)]
    end)
    |> Enum.intersperse(",\n")
  end

  defp join_items(items, indent) do
    next = indent + 2

    items
    |> Enum.map(fn item -> [spaces(next), pretty(item, next)] end)
    |> Enum.intersperse(",\n")
  end

  defp spaces(count), do: String.duplicate(" ", count)
end
