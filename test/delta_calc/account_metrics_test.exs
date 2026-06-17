defmodule DeltaCalc.AccountMetricsTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.AccountMetrics

  describe "calculate/2" do
    test "returns long account leverage, liquidation distance, margin usage, and safety" do
      account = %{
        entry_price: Decimal.new("3000"),
        notional: Decimal.new("10000"),
        equity: Decimal.new("5000"),
        margin_used: Decimal.new("1000"),
        mmr_total: Decimal.new("0.005"),
        side: :long,
        swan_pct: Decimal.new("25")
      }

      result = AccountMetrics.calculate(account)

      assert Decimal.equal?(result.effective_leverage, Decimal.new("2.00000000"))
      assert Decimal.equal?(result.liquidation_price, Decimal.new("1507.50000000"))
      assert Decimal.equal?(result.liquidation_distance_pct, Decimal.new("49.75000000"))
      assert Decimal.equal?(result.margin_usage_pct, Decimal.new("20.00000000"))
      assert result.safety.verdict == :tight
    end

    test "returns short account liquidation distance through Calc.safety/5" do
      account = %{
        entry_price: Decimal.new("3000"),
        notional: Decimal.new("10000"),
        equity: Decimal.new("5000"),
        margin_used: Decimal.new("2500"),
        mmr_total: Decimal.new("0.005"),
        side: :short,
        swan_pct: Decimal.new("25")
      }

      result = AccountMetrics.calculate(account)

      assert Decimal.equal?(result.effective_leverage, Decimal.new("2.00000000"))
      assert Decimal.equal?(result.liquidation_price, Decimal.new("4492.50000000"))
      assert Decimal.equal?(result.liquidation_distance_pct, Decimal.new("49.75000000"))
      assert Decimal.equal?(result.margin_usage_pct, Decimal.new("50.00000000"))
    end

    test "accepts safety configuration options" do
      account = %{
        entry_price: Decimal.new("3000"),
        notional: Decimal.new("10000"),
        equity: Decimal.new("5000"),
        margin_used: Decimal.new("1000"),
        mmr_total: Decimal.new("0.005"),
        side: :long,
        swan_pct: Decimal.new("25")
      }

      result =
        AccountMetrics.calculate(account, %{
          safety_cfg: %{safe_multiplier: Decimal.new("1.5")}
        })

      assert result.safety.verdict == :safe
    end
  end

  describe "margin_usage_pct/2" do
    test "returns margin used as a percentage of account equity" do
      result = AccountMetrics.margin_usage_pct(Decimal.new("1250"), Decimal.new("5000"))

      assert Decimal.equal?(result, Decimal.new("25.00000000"))
    end

    test "returns zero when equity is zero" do
      result = AccountMetrics.margin_usage_pct(Decimal.new("1250"), Decimal.new("0"))

      assert Decimal.equal?(result, Decimal.new("0"))
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(AccountMetrics) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for AccountMetrics, got: #{inspect(other)}")
        end

      public_functions =
        AccountMetrics.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert AccountMetrics.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
