defmodule DeltaCalc.CarryTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Carry

  describe "basis/2" do
    test "returns contango as a positive percentage premium over spot" do
      basis = Carry.basis(Decimal.new("60000"), Decimal.new("60600"))

      # (60600 - 60000) / 60000 * 100 = 1%
      assert Decimal.equal?(basis, Decimal.new("1.00000000"))
    end

    test "returns backwardation as a negative percentage discount to spot" do
      basis = Carry.basis(Decimal.new("60000"), Decimal.new("59500"))

      # (59500 - 60000) / 60000 * 100 = -500/600 = -0.833333...%
      assert basis == Decimal.new("-0.8333333333333333333333333333333333")
    end

    test "returns zero when spot price is not positive" do
      basis = Carry.basis(Decimal.new("0"), Decimal.new("60600"))

      assert Decimal.equal?(basis, Decimal.new("0"))
    end
  end

  describe "breakeven_funding/1" do
    test "returns the per-period funding rate that offsets one-time basis capture" do
      rate =
        Carry.breakeven_funding(%{
          spot_price: Decimal.new("60000"),
          perp_price: Decimal.new("60600"),
          holding_days: 30
        })

      # basis = 1%, periods = 30 * 3 = 90 → -1 / 90 / 100
      assert rate == Decimal.new("-0.0001111111111111111111111111111111111")
    end
  end

  describe "net_carry/1" do
    test "adds one-time basis capture to accumulated funding over the holding period" do
      result =
        Carry.net_carry(%{
          spot_price: Decimal.new("60000"),
          perp_price: Decimal.new("60600"),
          funding_rate: Decimal.new("0.0001"),
          holding_days: 30
        })

      assert Decimal.equal?(result.basis, Decimal.new("1.00000000"))
      assert Decimal.equal?(result.basis_yield, Decimal.new("1.00000000"))
      assert Decimal.equal?(result.funding_yield, Decimal.new("0.90000000"))
      assert Decimal.equal?(result.net_yield, Decimal.new("1.90000000"))

      assert result.breakeven_funding ==
               Decimal.new("-0.0001111111111111111111111111111111111")

      assert result.profitable? == true
    end

    test "marks the hedge unprofitable when funding cost overwhelms basis" do
      result =
        Carry.net_carry(%{
          spot_price: Decimal.new("60000"),
          perp_price: Decimal.new("60600"),
          funding_rate: Decimal.new("-0.0002"),
          holding_days: 30
        })

      assert Decimal.equal?(result.funding_yield, Decimal.new("-1.80000000"))
      assert Decimal.equal?(result.net_yield, Decimal.new("-0.80000000"))
      assert result.profitable? == false
    end

    test "uses caller-supplied funding period density" do
      result =
        Carry.net_carry(%{
          spot_price: Decimal.new("60000"),
          perp_price: Decimal.new("60600"),
          funding_rate: Decimal.new("0.0001"),
          holding_days: 30,
          periods_per_day: 1
        })

      assert Decimal.equal?(result.funding_yield, Decimal.new("0.30000000"))
      assert Decimal.equal?(result.net_yield, Decimal.new("1.30000000"))
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(Carry) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for Carry, got: #{inspect(other)}")
        end

      public_functions =
        Carry.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert Carry.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
