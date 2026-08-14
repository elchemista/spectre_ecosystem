defmodule Spectre.Ecosystem.JSONCampaignTest do
  use ExUnit.Case, async: true

  alias Spectre.Ecosystem.Campaign
  alias Spectre.Ecosystem.JSON

  test "JSON round-trips maps, booleans, nil and atom values" do
    value = %{
      status: :passed,
      enabled: true,
      disabled: false,
      missing: nil,
      nested: [%{count: 2}]
    }

    encoded = JSON.encode(value)
    assert {:ok, decoded} = JSON.decode(encoded)
    assert decoded["status"] == "passed"
    assert decoded["enabled"] == true
    assert decoded["disabled"] == false
    assert decoded["missing"] == :null
    assert decoded["nested"] == [%{"count" => 2}]
    assert {:ok, ^decoded} = decoded |> JSON.encode() |> JSON.decode()
  end

  test "pretty JSON is deterministic and rejects invalid input" do
    left = JSON.encode_pretty(%{"z" => 1, "a" => [true, %{}]})
    right = JSON.encode_pretty(%{"a" => [true, %{}], "z" => 1})

    assert left == right
    assert String.starts_with?(left, "{\n  \"a\"")
    assert String.ends_with?(left, "\n")
    assert {:error, :invalid_json} = JSON.decode("{")
  end

  test "campaign identifiers are bounded and portable" do
    id = Campaign.new_id()
    assert Campaign.valid_id?(id)
    refute Campaign.valid_id?("")
    refute Campaign.valid_id?("contains spaces")
    refute Campaign.valid_id?(String.duplicate("a", 121))
    refute Campaign.valid_id?(:atom)
  end
end
