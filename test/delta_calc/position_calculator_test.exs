defmodule DeltaCalc.PositionCalculatorTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.{Calc, PositionCalculator, Presets}

  @config %{risk_modes: Presets.load_modes()}

  defp base_params(overrides \\ []) do
    defaults = %{
      aum: D.new("10000"),
      mode: :conservative,
      side: :long,
      entry_price: D.new("3000"),
      subaccount_allocation: D.new("100"),
      initial_position_pct: D.new("0.5"),
      black_swan_pct: D.new("0.15"),
      ui_leverage: D.new("2"),
      mmr_rate: D.new("0.005"),
      mark_buffer: D.new("0.001"),
      fee_rate: D.new("0.0004")
    }

    Map.merge(defaults, Map.new(overrides))
  end

  describe "calculate_position/2 — golden ETH long (source scenario 1)" do
    test "matches TradingDashboard golden calc pipeline with 3x UI leverage" do
      params =
        base_params(
          ui_leverage: D.new("3"),
          black_swan_pct: D.new("0.25"),
          mark_buffer: D.new("0")
        )

      result = PositionCalculator.calculate_position(params, @config)

      assert D.equal?(result.allocation.sub_eq, D.new("100.00000000"))
      assert D.equal?(result.allocation.init_position, D.new("50.00000000"))
      assert D.equal?(result.allocation.reserve, D.new("50.00000000"))
      assert D.equal?(result.allocation.reserve_pct, D.new("50.00000000"))
      assert D.equal?(result.allocation.leftover, D.new("9900.00000000"))

      assert D.equal?(result.position.notional, D.new("150.00000000"))
      assert D.equal?(result.position.eff_lev, D.new("1.50000000"))
      assert D.equal?(result.position.tokens, D.new("0.05000000"))

      assert D.equal?(result.effective_leverage, D.new("1.50000000"))
      assert D.equal?(result.leverage_to_aum, D.new("0.01500000"))

      assert result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("1010.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("2250.00000000"))
      assert D.equal?(result.safety.distance_to_liq_pct, D.new("66.33333333"))
      assert D.equal?(result.safety.black_swan_pct, D.new("25.00"))

      assert D.equal?(result.mmr_info.mmr, D.new("0.00500000"))
      assert D.equal?(result.mmr_info.rate_display, D.new("0.50000000"))
    end
  end

  describe "calculate_position/2 — allocation pipeline" do
    test "computes subaccount equity, initial allocation, reserve, and leftover" do
      params = base_params()
      result = PositionCalculator.calculate_position(params, @config)

      assert D.equal?(result.allocation.sub_eq, params.subaccount_allocation)
      assert D.equal?(result.allocation.init_position, D.new("50.00000000"))
      assert D.equal?(result.allocation.reserve, D.new("50.00000000"))
      assert D.equal?(result.allocation.leftover, D.sub(params.aum, params.subaccount_allocation))
    end

    for {mode, expected} <- [
          conservative: @config.risk_modes.conservative,
          moderate: @config.risk_modes.moderate,
          aggressive: @config.risk_modes.aggressive
        ] do
      test "includes #{mode} mode_config in allocation" do
        result = PositionCalculator.calculate_position(base_params(mode: unquote(mode)), @config)
        assert result.allocation.mode_config == unquote(Macro.escape(expected))
      end
    end
  end

  describe "calculate_position/2 — position and leverage" do
    test "notional equals initial allocation times UI leverage" do
      params = base_params()
      result = PositionCalculator.calculate_position(params, @config)

      expected_notional =
        params.subaccount_allocation
        |> D.mult(params.initial_position_pct)
        |> D.mult(params.ui_leverage)

      assert D.equal?(result.position.notional, Calc.quantize(expected_notional))
      assert D.equal?(result.effective_leverage, D.new("1.00000000"))
      assert D.equal?(result.leverage_to_aum, D.new("0.01000000"))
    end

    test "long positions include token count" do
      result = PositionCalculator.calculate_position(base_params(side: :long), @config)

      assert Map.has_key?(result.position, :tokens)
      assert D.equal?(result.position.tokens, D.new("0.03333333"))
    end

    test "short positions omit token count" do
      result = PositionCalculator.calculate_position(base_params(side: :short), @config)

      refute Map.has_key?(result.position, :tokens)
      assert D.equal?(result.position.notional, D.new("100.00000000"))
    end
  end

  describe "calculate_position/2 — safety and mmr_info" do
    test "long liquidation sits below black swan when safe" do
      result = PositionCalculator.calculate_position(base_params(side: :long), @config)

      assert result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("18.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("2550.00000000"))
      assert D.compare(result.safety.liquidation_price, result.safety.black_swan_price) == :lt
    end

    test "short liquidation sits above black swan when safe" do
      result = PositionCalculator.calculate_position(base_params(side: :short), @config)

      assert result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("5982.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("3450.00000000"))
      assert D.compare(result.safety.liquidation_price, result.safety.black_swan_price) == :gt
    end

    test "high leverage can fail black swan safety check" do
      params =
        base_params(
          ui_leverage: D.new("10"),
          black_swan_pct: D.new("0.25"),
          mark_buffer: D.new("0")
        )

      result = PositionCalculator.calculate_position(params, @config)

      refute result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("2403.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("2250.00000000"))
    end

    test "mmr_info includes rate and display percentage" do
      result = PositionCalculator.calculate_position(base_params(), @config)

      assert D.equal?(result.mmr_info.mmr, D.new("0.00500000"))
      assert D.equal?(result.mmr_info.rate_display, D.new("0.50000000"))
    end
  end

  describe "calculate_position/2 — BTC short golden (source scenario 2)" do
    test "moderate short at 50k entry matches expected leverage and liquidation" do
      params = %{
        aum: D.new("10000"),
        mode: :moderate,
        side: :short,
        entry_price: D.new("50000"),
        subaccount_allocation: D.new("200"),
        initial_position_pct: D.new("0.3"),
        black_swan_pct: D.new("0.20"),
        ui_leverage: D.new("2"),
        mmr_rate: D.new("0.005"),
        mark_buffer: D.new("0"),
        fee_rate: D.new("0.0004")
      }

      result = PositionCalculator.calculate_position(params, @config)

      assert D.equal?(result.position.notional, D.new("120.00000000"))
      assert D.equal?(result.effective_leverage, D.new("0.60000000"))
      assert result.safety.is_safe

      assert_in_delta D.to_float(result.safety.liquidation_price), 132_916.6667, 0.01
    end
  end

  describe "Descripex api() declarations" do
    test "calculate_position/2 is annotated with api() hints" do
      {:docs_v1, _, :elixir, _, _, _, fn_docs} = Code.fetch_docs(PositionCalculator)

      doc =
        Enum.find(fn_docs, fn
          {{:function, :calculate_position, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert doc
      {{:function, :calculate_position, 2}, _, _, _, meta} = doc
      assert Map.has_key?(meta, :hints)
    end
  end
end
