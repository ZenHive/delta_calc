defmodule DeltaCalc.DecimalTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Decimal, as: DecimalInput

  describe "cast/1" do
    test "accepts Decimal values without changing them" do
      decimal = Decimal.new("123.4500")

      assert {:ok, ^decimal} = DecimalInput.cast(decimal)
    end

    test "accepts integers exactly" do
      assert {:ok, decimal} = DecimalInput.cast(-42)
      assert Decimal.equal?(decimal, Decimal.new("-42"))
    end

    test "accepts complete canonical decimal strings" do
      assert {:ok, decimal} = DecimalInput.cast("-1.25e3")
      assert Decimal.equal?(decimal, Decimal.new("-1250"))
    end

    test "rejects raw floats, malformed strings, and unsupported values" do
      invalid_values = [1.25, "1.25 trailing", "", nil, :invalid, %{}, [1]]

      for value <- invalid_values do
        assert {:error, :invalid_decimal} = DecimalInput.cast(value)
      end
    end
  end

  describe "cast!/1" do
    test "uses the same accepted-type rules as cast/1" do
      assert Decimal.equal?(DecimalInput.cast!("12.5"), Decimal.new("12.5"))

      for value <- [12.5, "12.5 trailing", nil] do
        assert_raise ArgumentError,
                     ~r/expected a Decimal, integer, or canonical decimal string/,
                     fn -> DecimalInput.cast!(value) end
      end
    end
  end
end
