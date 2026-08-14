defmodule Spectre.Ecosystem do
  @moduledoc """
  Compatibility orchestration for the repositories in the Spectre ecosystem.

  This project is tooling only. It is not a runtime dependency of Spectre or of
  any satellite package. It observes repositories and orchestrates their own
  GitHub Actions compatibility workflows.
  """

  @version "0.1.0"

  @doc "Returns the CLI contract version."
  @spec version() :: String.t()
  def version, do: @version
end
