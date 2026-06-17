defmodule DeltaCalc.GoldenCalcTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DeltaCalc.Calc

  describe "golden scenario 1: ETH long @ $3000, 3x UI, 50% initial margin, conservative mode" do
    test "calculates expected values correctly" do
      # Setup
      entry_price = Decimal.new(3000)
      ui_leverage = Decimal.new(3)
      initial_margin_pct = Decimal.new("0.5")
      # 0.5% MMR
      mmr_rate = Decimal.new("0.005")

      # Conservative allocation (1% of $10k AUM = $100 subaccount equity)
      sub_eq = Decimal.new(100)

      # Calculate position
      position =
        Calc.position(
          sub_eq,
          initial_margin_pct,
          ui_leverage,
          entry_price,
          :long
        )

      # Calculate liquidation
      liquidation_price =
        Calc.liquidation(
          entry_price,
          position.eff_lev,
          mmr_rate,
          :long
        )

      # Calculate safety (25% black swan for conservative)
      safety =
        Calc.safety(
          liquidation_price,
          entry_price,
          Decimal.new(25),
          :long,
          %{threshold_multiplier: Decimal.new("0.6"), safe_multiplier: Decimal.new("1.0")}
        )

      # Assertions with 0.0001 tolerance
      # Expected effective leverage: 1.5x (50% * 3x)
      assert_in_delta(Decimal.to_float(position.eff_lev), 1.5, 0.0001)

      # Expected liquidation: $3000 * (1 - (1 - 0.005) / 1.5) ≈ $1010
      # More precisely: 3000 * (1 - 0.995/1.5) = 3000 * 0.3367 = 1010
      assert_in_delta(Decimal.to_float(liquidation_price), 1010.0, 0.0001)

      # Expected verdict: safe (liquidation is 66.3% below entry, well below 25% threshold)
      assert safety.verdict == :safe
    end
  end

  describe "golden scenario 2: BTC short @ $50000, 2x UI, 30% initial margin, moderate mode" do
    test "calculates expected values correctly" do
      # Setup
      entry_price = Decimal.new(50_000)
      ui_leverage = Decimal.new(2)
      initial_margin_pct = Decimal.new("0.3")
      # 0.5% MMR
      mmr_rate = Decimal.new("0.005")

      # Moderate allocation (2% of $10k AUM = $200 subaccount equity)
      sub_eq = Decimal.new(200)

      # Calculate position
      position =
        Calc.position(
          sub_eq,
          initial_margin_pct,
          ui_leverage,
          entry_price,
          :short
        )

      # Calculate liquidation
      liquidation_price =
        Calc.liquidation(
          entry_price,
          position.eff_lev,
          mmr_rate,
          :short
        )

      # Calculate safety (20% black swan for moderate)
      safety =
        Calc.safety(
          liquidation_price,
          entry_price,
          Decimal.new(20),
          :short,
          %{threshold_multiplier: Decimal.new("0.6"), safe_multiplier: Decimal.new("1.0")}
        )

      # Assertions with 0.0001 tolerance
      # Expected effective leverage: 0.6x (30% * 2x)
      assert_in_delta(Decimal.to_float(position.eff_lev), 0.6, 0.0001)

      # Expected liquidation: $50000 * (1 + (1 - 0.005) / 0.6) ≈ $132,917
      # More precisely: 50000 * (1 + 0.995/0.6) = 50000 * 2.6583 = 132,916.67
      assert_in_delta(Decimal.to_float(liquidation_price), 132_916.6667, 0.0001)

      # Expected verdict: safe (liquidation is 165.8% above entry, well above 20% threshold)
      assert safety.verdict == :safe
    end
  end

  describe "property tests with StreamData" do
    property "more initial_margin % → lower effective leverage" do
      check all(
              sub_eq <- positive_decimal(),
              ui_lev <- leverage_decimal(),
              entry <- price_decimal(),
              im_pct_low <- float(min: 0.1, max: 0.3),
              im_pct_high <- float(min: 0.5, max: 0.9)
            ) do
        pos_low =
          Calc.position(
            sub_eq,
            Decimal.from_float(im_pct_low),
            ui_lev,
            entry,
            :long
          )

        pos_high =
          Calc.position(
            sub_eq,
            Decimal.from_float(im_pct_high),
            ui_lev,
            entry,
            :long
          )

        # Higher initial margin % should result in higher effective leverage
        assert Decimal.compare(pos_low.eff_lev, pos_high.eff_lev) == :lt
      end
    end

    property "higher ui_lev → higher effective leverage" do
      check all(
              sub_eq <- positive_decimal(),
              im_pct <- percentage_decimal(),
              entry <- price_decimal(),
              ui_lev_low <- float(min: 1.0, max: 3.0),
              ui_lev_high <- float(min: 5.0, max: 10.0)
            ) do
        pos_low =
          Calc.position(
            sub_eq,
            im_pct,
            Decimal.from_float(ui_lev_low),
            entry,
            :long
          )

        pos_high =
          Calc.position(
            sub_eq,
            im_pct,
            Decimal.from_float(ui_lev_high),
            entry,
            :long
          )

        # Higher UI leverage should result in higher effective leverage
        assert Decimal.compare(pos_low.eff_lev, pos_high.eff_lev) == :lt
      end
    end

    property "DCA ladder never exceeds reserve" do
      check all(
              reserve <- positive_decimal(min: 100, max: 10_000),
              entry <- price_decimal(),
              ui_lev <- leverage_decimal(),
              ladder_steps <- ladder_preset_generator(),
              max: 100
            ) do
        position = %{
          # Position twice the reserve
          notional: Decimal.mult(reserve, Decimal.new(2)),
          eff_lev: Decimal.new("2.0")
        }

        mmr_rate = Decimal.new("0.005")

        result =
          Calc.dca_ladder(
            position,
            reserve,
            entry,
            ui_lev,
            ladder_steps,
            :long,
            mmr_rate
          )

        # Calculate total spend
        total_spend =
          Enum.reduce(result.steps, Decimal.new(0), fn step, acc ->
            Decimal.add(acc, step.spend)
          end)

        # Total spend should never exceed reserve
        # Account for quantization: each spend is rounded to 8 decimals
        # Maximum rounding error per step is 0.000000005
        # With max 5 steps, total error could be 0.000000025
        max_rounding_error =
          Decimal.mult(Decimal.new("0.000000005"), Decimal.new(length(result.steps)))

        max_allowed = Decimal.add(reserve, max_rounding_error)
        assert Decimal.compare(total_spend, max_allowed) in [:lt, :eq]
      end
    end

    property "cross-margin DCA increases leverage when underwater" do
      check all(
              initial_equity <- positive_decimal(min: 50, max: 1000),
              entry_price <- price_decimal(),
              # 1-15% drop
              price_drop_pct <- float(min: 0.01, max: 0.15),
              # Notional as multiple of equity
              notional_pct <- float(min: 1.5, max: 3.0)
            ) do
        # First leg
        leg1_notional = Decimal.mult(initial_equity, Decimal.from_float(notional_pct))
        single_lev = Calc.effective_leverage(leg1_notional, initial_equity)

        # Price after drop
        drop_mult = Decimal.sub(Decimal.new(1), Decimal.from_float(price_drop_pct))
        current_price = Decimal.mult(entry_price, drop_mult)

        # Add second leg at lower price
        legs = [
          %{entry: entry_price, notional: leg1_notional},
          %{entry: current_price, notional: leg1_notional}
        ]

        multi_pos = Calc.multi_leg_position(legs, current_price, initial_equity)

        # Leverage should increase after DCA while underwater
        assert Decimal.compare(multi_pos.effective_leverage, single_lev) == :gt
      end
    end

    property "liquidation moves adversely after underwater DCA" do
      check all(
              initial_equity <- positive_decimal(min: 50, max: 1000),
              entry_price <- price_decimal(),
              price_drop_pct <- float(min: 0.05, max: 0.15),
              notional_mult <- float(min: 1.5, max: 2.5)
            ) do
        mmr = Decimal.new("0.005")

        # Single leg
        leg1_notional = Decimal.mult(initial_equity, Decimal.from_float(notional_mult))
        single_lev = Calc.effective_leverage(leg1_notional, initial_equity)
        single_liq = Calc.liquidation(entry_price, single_lev, mmr, :long)

        # Price drops
        drop_mult = Decimal.sub(Decimal.new(1), Decimal.from_float(price_drop_pct))
        current_price = Decimal.mult(entry_price, drop_mult)

        # Add second leg
        legs = [
          %{entry: entry_price, notional: leg1_notional},
          %{entry: current_price, notional: leg1_notional}
        ]

        multi_pos = Calc.multi_leg_position(legs, current_price, initial_equity)

        multi_liq =
          Calc.liquidation(multi_pos.avg_entry, multi_pos.effective_leverage, mmr, :long)

        # For longs, liquidation should move higher (worse) after underwater DCA
        assert Decimal.compare(multi_liq, single_liq) == :gt
      end
    end

    property "allocation respects cap and percentage limits" do
      check all(
              aum <- positive_decimal(min: 1000, max: 100_000),
              pct <- float(min: 0.001, max: 0.1),
              cap <- float(min: 0.001, max: 0.1),
              im_pct <- float(min: 0.1, max: 0.9)
            ) do
        mode_cfg = %{
          pct: Decimal.from_float(pct),
          cap: Decimal.from_float(cap)
        }

        result =
          Calc.allocate(
            aum,
            mode_cfg,
            [:BTC],
            %{BTC: Decimal.new(100)},
            Decimal.from_float(im_pct)
          )

        # Sub equity should be min(pct * aum, cap * aum)
        expected_sub_eq =
          Decimal.min(
            Decimal.mult(aum, Decimal.from_float(pct)),
            Decimal.mult(aum, Decimal.from_float(cap))
          )

        assert_in_delta(
          Decimal.to_float(result.sub_eq),
          Decimal.to_float(expected_sub_eq),
          0.0001
        )

        # Initial margin + reserve should equal sub equity
        total = Decimal.add(result.init_margin, result.reserve)

        assert_in_delta(
          Decimal.to_float(total),
          Decimal.to_float(result.sub_eq),
          0.0001
        )

        # Sub equity + leftover should equal AUM
        grand_total = Decimal.add(result.sub_eq, result.leftover)

        assert_in_delta(
          Decimal.to_float(grand_total),
          Decimal.to_float(aum),
          0.0001
        )
      end
    end

    property "effective leverage formula invariant" do
      check all(
              notional <- positive_decimal(min: 100, max: 100_000),
              equity <- positive_decimal(min: 10, max: 10_000)
            ) do
        eff_lev = Calc.effective_leverage(notional, equity)

        # Verify: effective_leverage = notional / equity
        expected = Decimal.div(notional, equity)

        assert_in_delta(
          Decimal.to_float(eff_lev),
          Decimal.to_float(expected),
          0.0001
        )
      end
    end

    property "safety verdict consistency" do
      check all(
              liq_distance_pct <- float(min: 0.0, max: 50.0),
              swan_pct <- float(min: 5.0, max: 30.0),
              threshold_mult <- float(min: 0.3, max: 0.7),
              safe_mult <- float(min: 0.8, max: 1.2)
            ) do
        entry = Decimal.new(3000)
        # Calculate liquidation price based on distance percentage
        liq_mult =
          Decimal.sub(
            Decimal.new(1),
            Decimal.div(Decimal.from_float(liq_distance_pct), Decimal.new(100))
          )

        liq = Decimal.mult(entry, liq_mult)

        safety =
          Calc.safety(
            liq,
            entry,
            Decimal.from_float(swan_pct),
            :long,
            %{
              threshold_multiplier: Decimal.from_float(threshold_mult),
              safe_multiplier: Decimal.from_float(safe_mult)
            }
          )

        # Verify verdict consistency with thresholds
        threshold = swan_pct * threshold_mult
        safe_threshold = swan_pct * safe_mult

        case safety.verdict do
          :unsafe ->
            assert liq_distance_pct < threshold

          :tight ->
            assert liq_distance_pct >= threshold && liq_distance_pct < safe_threshold

          :safe ->
            assert liq_distance_pct >= safe_threshold
        end
      end
    end
  end

  # Generator helpers for property tests
  defp positive_decimal(opts \\ []) do
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 10_000)

    map(float(min: min, max: max), &Decimal.from_float/1)
  end

  defp price_decimal do
    map(float(min: 100.0, max: 100_000.0), &Decimal.from_float/1)
  end

  defp leverage_decimal do
    map(float(min: 1.0, max: 10.0), &Decimal.from_float/1)
  end

  defp percentage_decimal do
    map(float(min: 0.1, max: 0.9), &Decimal.from_float/1)
  end

  defp ladder_preset_generator do
    bind(integer(0..5), fn
      0 -> constant([])
      num_steps -> bind_ladder_preset(num_steps)
    end)
  end

  defp bind_ladder_preset(num_steps) do
    bind(list_of(integer(5..40), length: num_steps), fn int_percentages ->
      normalized = normalize_ladder_percentages(int_percentages)
      bind_ladder_multipliers(num_steps, normalized)
    end)
  end

  defp bind_ladder_multipliers(num_steps, normalized_percentages) do
    bind(list_of(integer(70..95), length: num_steps), fn int_multipliers ->
      decimal_multipliers =
        Enum.map(int_multipliers, fn mult ->
          Decimal.div(Decimal.new(mult), Decimal.new(100))
        end)

      sorted_multipliers = Enum.sort_by(decimal_multipliers, & &1, {:desc, Decimal})
      constant(Enum.zip(sorted_multipliers, normalized_percentages))
    end)
  end

  defp normalize_ladder_percentages(int_percentages) do
    decimal_percentages =
      Enum.map(int_percentages, fn pct ->
        Decimal.div(Decimal.new(pct), Decimal.new(100))
      end)

    sum = Enum.reduce(decimal_percentages, Decimal.new(0), &Decimal.add/2)

    if Decimal.compare(sum, Decimal.new(1)) == :gt do
      Enum.map(decimal_percentages, fn pct -> Decimal.div(pct, sum) end)
    else
      decimal_percentages
    end
  end
end
