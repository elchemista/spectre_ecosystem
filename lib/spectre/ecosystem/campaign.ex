defmodule Spectre.Ecosystem.Campaign do
  @moduledoc false

  @spec new_id() :: String.t()
  def new_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    suffix = 5 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{timestamp}-#{String.downcase(suffix)}"
  end

  @spec valid_id?(term()) :: boolean()
  def valid_id?(value) when is_binary(value) do
    byte_size(value) in 1..120 and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value)
  end

  def valid_id?(_value), do: false
end
