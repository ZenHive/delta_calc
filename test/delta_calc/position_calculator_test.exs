defmodule DeltaCalc.PositionCalculatorTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.PositionCalculator

  defp base_params(overrides \\ []) do
    defaults = %{
      aum: D.new("10000"),
      side: :long,
      entry_price: D.new("3000"),
      subaccount_allocation: D.new("100"),
      initial_position_pct: D.new("0.5"),
      black_swan_pct: D.new("0.15"),
      ui_leverage: D.new("2"),
      mmr_rate: D.new("0.005"),
      mark_buffer: D.new("0.001")
    }

    Map.merge(defaults, Map.new(overrides))
  end

  # Compare Decimals within an absolute tolerance (never via to_float).
  defp assert_close(actual, expected, tolerance) do
    diff = actual |> D.sub(expected) |> D.abs()

    assert D.compare(diff, D.new(tolerance)) != :gt,
           "expected #{D.to_string(expected)} ± #{tolerance}, got #{D.to_string(actual)}"
  end

  describe "calculate_position/1 — golden ETH long (source scenario 1)" do
    # Independent sizing + liquidation golden.
    # Provenance: hand calc from the public PositionCalculator.calculate_position/1
    # and Calc.liquidation/4 contracts.
    #   sub_eq=100; init_position = 100×0.5 = 50; reserve = 50; leftover = 9900
    #   notional = 50×3 = 150; tokens = 150/3000 = 0.05; eff_lev = 150/100 = 1.5
    #   lev_to_aum = 150/10000 = 0.015
    #   long liq @ mmr=0.005, L=1.5: 3000×(1 − 0.995/1.5) = 1010 exactly
    #   black_swan @ 25%: 3000×0.75 = 2250
    #   distance_to_liq_pct = (3000−1010)/3000 × 100 = 66.33333333…
    test "matches hand-computed sizing and liquidation fixture with 3x UI leverage" do
      params =
        base_params(
          ui_leverage: D.new("3"),
          black_swan_pct: D.new("0.25"),
          mark_buffer: D.new("0")
        )

      result = PositionCalculator.calculate_position(params)

      assert_close(result.allocation.sub_eq, D.new("100.00000000"), "0.00000001")
      assert_close(result.allocation.init_position, D.new("50.00000000"), "0.00000001")
      assert_close(result.allocation.reserve, D.new("50.00000000"), "0.00000001")
      assert_close(result.allocation.reserve_pct, D.new("50.00000000"), "0.00000001")
      assert_close(result.allocation.leftover, D.new("9900.00000000"), "0.00000001")

      assert_close(result.position.notional, D.new("150.00000000"), "0.00000001")
      assert_close(result.position.eff_lev, D.new("1.50000000"), "0.00000001")
      assert_close(result.position.tokens, D.new("0.05000000"), "0.00000001")

      assert_close(result.effective_leverage, D.new("1.50000000"), "0.00000001")
      assert_close(result.leverage_to_aum, D.new("0.01500000"), "0.00000001")

      assert result.safety.is_safe
      assert_close(result.safety.liquidation_price, D.new("1010.00000000"), "0.00000001")
      assert_close(result.safety.black_swan_price, D.new("2250.00000000"), "0.00000001")
      assert_close(result.safety.distance_to_liq_pct, D.new("66.33333333"), "0.00000001")
      assert_close(result.safety.black_swan_pct, D.new("25.00"), "0.01")

      assert_close(result.mmr_info.mmr, D.new("0.00500000"), "0.00000001")
      assert_close(result.mmr_info.rate_display, D.new("0.50000000"), "0.00000001")
    end
  end

  describe "calculate_position/1 — allocation pipeline" do
    test "computes subaccount equity, initial allocation, reserve, and leftover" do
      params = base_params()
      result = PositionCalculator.calculate_position(params)

      assert D.equal?(result.allocation.sub_eq, params.subaccount_allocation)
      assert D.equal?(result.allocation.init_position, D.new("50.00000000"))
      assert D.equal?(result.allocation.reserve, D.new("50.00000000"))
      assert D.equal?(result.allocation.leftover, D.sub(params.aum, params.subaccount_allocation))
      refute Map.has_key?(result.allocation, :mode_config)
    end
  end

  describe "calculate_position/1 — position and leverage" do
    # Hand calc from public sizing contract (default base_params):
    #   notional = 100 × 0.5 × 2 = 100; eff_lev = 100/100 = 1; lev_to_aum = 100/10000 = 0.01
    test "notional equals initial allocation times UI leverage" do
      params = base_params()
      result = PositionCalculator.calculate_position(params)

      assert D.equal?(result.position.notional, D.new("100.00000000"))
      assert D.equal?(result.effective_leverage, D.new("1.00000000"))
      assert D.equal?(result.leverage_to_aum, D.new("0.01000000"))
    end

    test "long positions include token count" do
      result = PositionCalculator.calculate_position(base_params(side: :long))

      assert Map.has_key?(result.position, :tokens)
      assert D.equal?(result.position.tokens, D.new("0.03333333"))
    end

    test "short positions omit token count" do
      result = PositionCalculator.calculate_position(base_params(side: :short))

      refute Map.has_key?(result.position, :tokens)
      assert D.equal?(result.position.notional, D.new("100.00000000"))
    end
  end

  describe "calculate_position/1 — safety and mmr_info" do
    test "long liquidation sits below black swan when safe" do
      result = PositionCalculator.calculate_position(base_params(side: :long))

      assert result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("18.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("2550.00000000"))
      assert D.compare(result.safety.liquidation_price, result.safety.black_swan_price) == :lt
    end

    test "short liquidation sits above black swan when safe" do
      result = PositionCalculator.calculate_position(base_params(side: :short))

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

      result = PositionCalculator.calculate_position(params)

      refute result.safety.is_safe
      assert D.equal?(result.safety.liquidation_price, D.new("2403.00000000"))
      assert D.equal?(result.safety.black_swan_price, D.new("2250.00000000"))
    end

    test "mmr_info includes rate and display percentage" do
      result = PositionCalculator.calculate_position(base_params())

      assert D.equal?(result.mmr_info.mmr, D.new("0.00500000"))
      assert D.equal?(result.mmr_info.rate_display, D.new("0.50000000"))
    end

    test "returns Calc error when entry price is invalid" do
      result =
        PositionCalculator.calculate_position(base_params(entry_price: D.new("0")))

      assert result == {:error, :non_positive_entry}
    end
  end

  describe "calculate_position/1 — BTC short golden (source scenario 2)" do
    # Independent sizing + liquidation golden.
    # Provenance: hand calc from the public PositionCalculator.calculate_position/1
    # and Calc.liquidation/4 contracts.
    #   notional = 200×0.3×2 = 120; eff_lev = 120/200 = 0.6
    #   short liq: 50000×(1 + 0.995/0.6) = 132916.6666… (quantize → 132916.66666667)
    test "moderate short at 50k entry matches expected leverage and liquidation" do
      params = %{
        aum: D.new("10000"),
        side: :short,
        entry_price: D.new("50000"),
        subaccount_allocation: D.new("200"),
        initial_position_pct: D.new("0.3"),
        black_swan_pct: D.new("0.20"),
        ui_leverage: D.new("2"),
        mmr_rate: D.new("0.005"),
        mark_buffer: D.new("0")
      }

      result = PositionCalculator.calculate_position(params)

      assert_close(result.position.notional, D.new("120.00000000"), "0.00000001")
      assert_close(result.effective_leverage, D.new("0.60000000"), "0.00000001")
      assert result.safety.is_safe
      assert_close(result.safety.liquidation_price, D.new("132916.66666667"), "0.01")
    end
  end

  describe "behavioral input contract" do
    test "every advertised input changes its relevant result" do
      params = base_params(mark_buffer: D.new("0"))
      baseline = PositionCalculator.calculate_position(params)

      mutations = [
        {:aum, D.new("20000"), & &1.leverage_to_aum},
        {:side, :short, & &1.safety.liquidation_price},
        {:entry_price, D.new("4000"), & &1.safety.liquidation_price},
        {:subaccount_allocation, D.new("200"), & &1.position.notional},
        {:initial_position_pct, D.new("0.6"), & &1.position.notional},
        {:black_swan_pct, D.new("0.25"), & &1.safety.black_swan_price},
        {:ui_leverage, D.new("3"), & &1.position.notional},
        {:mmr_rate, D.new("0.01"), & &1.safety.liquidation_price},
        {:mark_buffer, D.new("0.01"), & &1.safety.liquidation_price}
      ]

      for {input, value, relevant_result} <- mutations do
        changed = params |> Map.put(input, value) |> PositionCalculator.calculate_position()

        refute D.equal?(relevant_result.(changed), relevant_result.(baseline)),
               "expected changing #{input} to change its relevant result"
      end
    end
  end

  describe "Descripex api() declarations" do
    test "calculate_position/1 advertises only calculation-driving values" do
      {:docs_v1, _, :elixir, _, _, _, fn_docs} = Code.fetch_docs(PositionCalculator)

      doc =
        Enum.find(fn_docs, fn
          {{:function, :calculate_position, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert doc
      {{:function, :calculate_position, 1}, _, _, _, meta} = doc
      assert Map.has_key?(meta, :hints)

      [api] = PositionCalculator.__api__()
      assert api.param_order == [:params]
      refute api.hints.params.params.description =~ "fee_rate"
      refute api.hints.params.params.description =~ "mode"
    end
  end
end
