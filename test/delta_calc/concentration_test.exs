defmodule DeltaCalc.ConcentrationTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Concentration

  describe "hhi/1" do
    test "calculates normalized HHI from fractional weights" do
      weights = %{
        "BTC" => Decimal.new("0.45"),
        "ETH" => Decimal.new("0.30"),
        "SOL" => Decimal.new("0.15"),
        "Others" => Decimal.new("0.10")
      }

      assert Decimal.equal?(Concentration.hhi(weights), Decimal.new("0.32500000"))
    end

    test "normalizes percentage weights before calculating HHI" do
      weights = [
        Decimal.new("45"),
        Decimal.new("30"),
        Decimal.new("15"),
        Decimal.new("10")
      ]

      assert Decimal.equal?(Concentration.hhi(weights), Decimal.new("0.32500000"))
    end

    test "equal four-asset weights produce 0.25 HHI" do
      weights = [Decimal.new("1"), Decimal.new("1"), Decimal.new("1"), Decimal.new("1")]

      assert Decimal.equal?(Concentration.hhi(weights), Decimal.new("0.25000000"))
    end

    test "empty weights return zero" do
      assert Decimal.equal?(Concentration.hhi([]), Decimal.new("0"))
    end

    test "zero total weight returns zero" do
      weights = [Decimal.new("0"), Decimal.new("0")]

      assert Decimal.equal?(Concentration.hhi(weights), Decimal.new("0"))
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(Concentration) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for Concentration, got: #{inspect(other)}")
        end

      public_functions =
        Concentration.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert Concentration.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
