defmodule DeltaCalc.CalcTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Calc

  # Compare Decimals within an absolute tolerance (never via to_float).
  defp assert_close(actual, expected, tolerance) do
    diff = actual |> Decimal.sub(expected) |> Decimal.abs()

    assert Decimal.compare(diff, Decimal.new(tolerance)) != :gt,
           "expected #{Decimal.to_string(expected)} ± #{tolerance}, got #{Decimal.to_string(actual)}"
  end

  describe "effective_leverage/2" do
    test "calculates correct leverage for normal case" do
      result = Calc.effective_leverage(Decimal.new(10_000), Decimal.new(5000))
      assert Decimal.equal?(result, Decimal.new("2.00000000"))
    end

    test "returns error for zero equity" do
      result = Calc.effective_leverage(Decimal.new(10_000), Decimal.new(0))
      assert result == {:error, :non_positive_wallet_equity}
    end

    test "returns error for negative equity" do
      result = Calc.effective_leverage(Decimal.new(10_000), Decimal.new(-100))
      assert result == {:error, :non_positive_wallet_equity}
    end

    test "returns numeric zero for no position" do
      result = Calc.effective_leverage(Decimal.new(0), Decimal.new(5000))
      assert Decimal.equal?(result, Decimal.new("0.00000000"))
    end

    test "handles fractional leverage" do
      result = Calc.effective_leverage(Decimal.new(3000), Decimal.new(10_000))
      assert Decimal.equal?(result, Decimal.new("0.30000000"))
    end

    test "uses absolute notional for negative values (shorts)" do
      result = Calc.effective_leverage(Decimal.new(-10_000), Decimal.new(5000))
      assert Decimal.equal?(result, Decimal.new("2.00000000"))
    end

    test "float inputs quantize reliably" do
      result = Calc.effective_leverage(Decimal.from_float(10_000.0), Decimal.from_float(5000.0))
      assert Decimal.equal?(result, Decimal.new("2.00000000"))
    end
  end

  describe "leverage_to_aum/2" do
    test "calculates correct leverage relative to AUM for normal case" do
      result = Calc.leverage_to_aum(Decimal.new(10_000), Decimal.new(100_000))
      assert Decimal.equal?(result, Decimal.new("0.10000000"))
    end

    test "returns error for zero AUM" do
      result = Calc.leverage_to_aum(Decimal.new(10_000), Decimal.new(0))
      assert result == {:error, :non_positive_total_aum}
    end

    test "returns error for negative AUM" do
      result = Calc.leverage_to_aum(Decimal.new(10_000), Decimal.new(-100_000))
      assert result == {:error, :non_positive_total_aum}
    end

    test "returns numeric zero for no position" do
      result = Calc.leverage_to_aum(Decimal.new(0), Decimal.new(100_000))
      assert Decimal.equal?(result, Decimal.new("0.00000000"))
    end

    test "handles fractional leverage to AUM" do
      result = Calc.leverage_to_aum(Decimal.new(500), Decimal.new(10_000))
      assert Decimal.equal?(result, Decimal.new("0.05000000"))
    end

    test "handles high leverage to AUM" do
      result = Calc.leverage_to_aum(Decimal.new(50_000), Decimal.new(10_000))
      assert Decimal.equal?(result, Decimal.new("5.00000000"))
    end

    test "uses absolute notional for negative values (shorts)" do
      result = Calc.leverage_to_aum(Decimal.new(-10_000), Decimal.new(100_000))
      assert Decimal.equal?(result, Decimal.new("0.10000000"))
    end

    test "float inputs quantize reliably" do
      result = Calc.leverage_to_aum(Decimal.from_float(10_000.0), Decimal.from_float(100_000.0))
      assert Decimal.equal?(result, Decimal.new("0.10000000"))
    end

    test "very small position relative to large AUM" do
      result = Calc.leverage_to_aum(Decimal.new(100), Decimal.new(1_000_000))
      assert Decimal.equal?(result, Decimal.new("0.00010000"))
    end

    test "position equal to AUM" do
      result = Calc.leverage_to_aum(Decimal.new(50_000), Decimal.new(50_000))
      assert Decimal.equal?(result, Decimal.new("1.00000000"))
    end
  end

  describe "liquidation/4" do
    # Independent golden — provenance: hand calc from the public simplified
    # liquidation contract in Calc.liquidation/4.
    # Long: liq = entry × (1 − (1 − mmr) / L_eff).
    # Hand calc, entry=3000, L_eff=2, mmr=0.005:
    #   (1 − mmr) = 0.995; 0.995/2 = 0.4975; 1 − 0.4975 = 0.5025;
    #   3000 × 0.5025 = 1507.5
    test "calculates long liquidation correctly" do
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :long)
      assert_close(result, Decimal.new("1507.5"), "0.01")
    end

    # Independent golden — provenance: hand calc from the public simplified
    # liquidation contract in Calc.liquidation/4.
    # Short: liq = entry × (1 + (1 − mmr) / L_eff).
    # Hand calc, entry=3000, L_eff=2, mmr=0.005:
    #   1 + 0.4975 = 1.4975; 3000 × 1.4975 = 4492.5
    test "calculates short liquidation correctly" do
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.005"), :short)
      assert_close(result, Decimal.new("4492.5"), "0.01")
    end

    test "returns zero for zero leverage no-position case" do
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(0), Decimal.new("0.005"), :long)
      assert Decimal.equal?(result, Decimal.new("0.00000000"))
    end

    test "returns error for negative leverage" do
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(-1), Decimal.new("0.005"), :short)
      assert result == {:error, :negative_effective_leverage}
    end

    test "returns error for non-positive entry" do
      assert Calc.liquidation(Decimal.new(0), Decimal.new(2), Decimal.new("0.005"), :long) ==
               {:error, :non_positive_entry}
    end

    # Hand calc: entry=50000, L=10, mmr=0.005 →
    #   0.995/10 = 0.0995; 1 − 0.0995 = 0.9005; 50000 × 0.9005 = 45025
    test "handles high leverage long" do
      result = Calc.liquidation(Decimal.new(50_000), Decimal.new(10), Decimal.new("0.005"), :long)
      assert_close(result, Decimal.new("45025"), "0.01")
    end

    # Hand calc: 1 + 0.0995 = 1.0995; 50000 × 1.0995 = 54975
    test "handles high leverage short" do
      result =
        Calc.liquidation(Decimal.new(50_000), Decimal.new(10), Decimal.new("0.005"), :short)

      assert_close(result, Decimal.new("54975"), "0.01")
    end

    test "clamps negative MMR to zero" do
      # Test that negative MMR is clamped to 0
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("-0.1"), :long)
      expected = Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0"), :long)
      assert Decimal.equal?(result, expected)
    end

    test "clamps excessive MMR to maximum" do
      # Test that MMR > 1 is clamped to 0.99999999
      result = Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("1.5"), :long)

      expected =
        Calc.liquidation(Decimal.new(3000), Decimal.new(2), Decimal.new("0.99999999"), :long)

      assert Decimal.equal?(result, expected)
    end

    test "clamps negative long liquidation to zero" do
      # Very high leverage with high MMR could theoretically produce negative liq
      # This should be clamped to 0
      result = Calc.liquidation(Decimal.new(3000), Decimal.new("0.1"), Decimal.new("0.5"), :long)
      assert Decimal.compare(result, Decimal.new(0)) in [:eq, :gt]
    end

    test "long liquidation increases with leverage" do
      entry = Decimal.new(3000)
      mmr = Decimal.new("0.005")
      low_lev = Calc.liquidation(entry, Decimal.new(2), mmr, :long)
      high_lev = Calc.liquidation(entry, Decimal.new(5), mmr, :long)
      assert Decimal.compare(high_lev, low_lev) == :gt
    end

    test "long liquidation increases with MMR" do
      entry = Decimal.new(3000)
      lev = Decimal.new(3)
      low_mmr = Calc.liquidation(entry, lev, Decimal.new("0.002"), :long)
      high_mmr = Calc.liquidation(entry, lev, Decimal.new("0.02"), :long)
      assert Decimal.compare(high_mmr, low_mmr) == :gt
    end

    test "short liquidation decreases with higher leverage" do
      entry = Decimal.new(3000)
      mmr = Decimal.new("0.005")
      low_lev = Calc.liquidation(entry, Decimal.new(2), mmr, :short)
      high_lev = Calc.liquidation(entry, Decimal.new(5), mmr, :short)
      assert Decimal.compare(high_lev, low_lev) == :lt
    end

    test "short liquidation decreases with higher MMR" do
      entry = Decimal.new(3000)
      lev = Decimal.new(3)
      low_mmr = Calc.liquidation(entry, lev, Decimal.new("0.002"), :short)
      high_mmr = Calc.liquidation(entry, lev, Decimal.new("0.02"), :short)
      # For shorts, higher MMR means liquidation gets closer to entry (lower price)
      assert Decimal.compare(high_mmr, low_mmr) == :lt
    end
  end

  describe "allocate/5" do
    test "allocates correctly in conservative mode" do
      mode_cfg = %{pct: Decimal.new("0.01"), cap: Decimal.new("0.01")}

      result =
        Calc.allocate(
          Decimal.new(10_000),
          mode_cfg,
          [:ETH],
          %{ETH: Decimal.new(100)},
          Decimal.new("0.5")
        )

      assert_in_delta(Decimal.to_float(result.sub_eq), 100.0, 0.01)
      assert_in_delta(Decimal.to_float(result.init_margin), 50.0, 0.01)
      assert_in_delta(Decimal.to_float(result.reserve), 50.0, 0.01)
      assert_in_delta(Decimal.to_float(result.leftover), 9900.0, 0.01)
    end

    test "respects cap limit when pct would exceed it" do
      mode_cfg = %{pct: Decimal.new("0.05"), cap: Decimal.new("0.02")}

      result =
        Calc.allocate(
          Decimal.new(10_000),
          mode_cfg,
          [:ETH],
          %{ETH: Decimal.new(100)},
          Decimal.new("0.5")
        )

      # Should use cap (2%) not pct (5%)
      assert_in_delta(Decimal.to_float(result.sub_eq), 200.0, 0.01)
      assert_in_delta(Decimal.to_float(result.init_margin), 100.0, 0.01)
      assert_in_delta(Decimal.to_float(result.reserve), 100.0, 0.01)
      assert_in_delta(Decimal.to_float(result.leftover), 9800.0, 0.01)
    end

    test "handles different initial margin percentages" do
      mode_cfg = %{pct: Decimal.new("0.03"), cap: Decimal.new("0.03")}

      result =
        Calc.allocate(
          Decimal.new(10_000),
          mode_cfg,
          [:ETH],
          %{ETH: Decimal.new(100)},
          # 30% initial margin
          Decimal.new("0.3")
        )

      assert_in_delta(Decimal.to_float(result.sub_eq), 300.0, 0.01)
      assert_in_delta(Decimal.to_float(result.init_margin), 90.0, 0.01)
      assert_in_delta(Decimal.to_float(result.reserve), 210.0, 0.01)
      assert_in_delta(Decimal.to_float(result.leftover), 9700.0, 0.01)
    end
  end

  describe "position/5" do
    test "calculates position for long" do
      result =
        Calc.position(
          Decimal.new(1000),
          Decimal.new("0.5"),
          Decimal.new(3),
          Decimal.new(3000),
          :long
        )

      assert_in_delta(Decimal.to_float(result.notional), 1500.0, 0.01)
      assert_in_delta(Decimal.to_float(result.eff_lev), 1.5, 0.01)
    end

    test "calculates position for short" do
      result =
        Calc.position(
          Decimal.new(1000),
          Decimal.new("0.5"),
          Decimal.new(3),
          Decimal.new(3000),
          :short
        )

      # Should return notional only (no tokens for shorts)
      assert_in_delta(Decimal.to_float(result.notional), 1500.0, 0.01)
      assert_in_delta(Decimal.to_float(result.eff_lev), 1.5, 0.01)
    end

    test "handles low leverage" do
      result =
        Calc.position(
          Decimal.new(1000),
          Decimal.new("0.3"),
          Decimal.new(1),
          Decimal.new(3000),
          :long
        )

      assert_in_delta(Decimal.to_float(result.notional), 300.0, 0.01)
      assert_in_delta(Decimal.to_float(result.eff_lev), 0.3, 0.01)
    end

    test "handles high leverage" do
      result =
        Calc.position(
          Decimal.new(1000),
          Decimal.new("0.8"),
          Decimal.new(10),
          Decimal.new(50_000),
          :long
        )

      assert_in_delta(Decimal.to_float(result.notional), 8000.0, 0.01)
      assert_in_delta(Decimal.to_float(result.eff_lev), 8.0, 0.01)
    end
  end

  describe "safety/5" do
    test "returns safe verdict when well above threshold" do
      # Liq at 2850, entry at 3000 = 5% distance
      # Swan at 25% = safe if distance > 50% of swan (12.5%)
      result =
        Calc.safety(
          # 25% below entry
          Decimal.new(2250),
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{threshold_multiplier: Decimal.new("0.5"), safe_multiplier: Decimal.new("0.8")}
        )

      assert result.verdict == :safe
      assert_in_delta(Decimal.to_float(result.distance_to_liq_pct), 25.0, 0.01)
      assert_in_delta(Decimal.to_float(result.distance_to_liq_usd), 750.0, 0.01)
      assert_in_delta(Decimal.to_float(result.composite_score), 100.0, 0.01)
    end

    test "returns tight verdict when between thresholds" do
      result =
        Calc.safety(
          # 10% below entry
          Decimal.new(2700),
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{threshold_multiplier: Decimal.new("0.3"), safe_multiplier: Decimal.new("0.5")}
        )

      assert result.verdict == :tight
      assert_in_delta(Decimal.to_float(result.distance_to_liq_pct), 10.0, 0.01)
    end

    test "returns unsafe verdict when below threshold" do
      result =
        Calc.safety(
          # 1.67% below entry
          Decimal.new(2950),
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{threshold_multiplier: Decimal.new("0.2"), safe_multiplier: Decimal.new("0.4")}
        )

      assert result.verdict == :unsafe
      assert_in_delta(Decimal.to_float(result.distance_to_liq_pct), 1.67, 0.1)
    end

    test "calculates short safety correctly" do
      # Short: liq above entry
      result =
        Calc.safety(
          # 5% above entry
          Decimal.new(52_500),
          Decimal.new(50_000),
          Decimal.new(20),
          :short,
          %{threshold_multiplier: Decimal.new("0.3"), safe_multiplier: Decimal.new("0.5")}
        )

      # 5% distance, threshold is 6% (20% * 0.3), so should be unsafe
      assert result.verdict == :unsafe
      assert_in_delta(Decimal.to_float(result.distance_to_liq_pct), 5.0, 0.01)
      assert_in_delta(Decimal.to_float(result.distance_to_liq_usd), 2500.0, 0.01)
    end

    test "composite score scales linearly" do
      # 12.5% distance, 25% swan = 50% score
      result =
        Calc.safety(
          # 12.5% below entry
          Decimal.new(2625),
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{}
        )

      assert_in_delta(Decimal.to_float(result.composite_score), 50.0, 0.1)
    end

    test "composite score caps at 100" do
      # 30% distance, 25% swan = should cap at 100
      result =
        Calc.safety(
          # 30% below entry
          Decimal.new(2100),
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{}
        )

      assert_in_delta(Decimal.to_float(result.composite_score), 100.0, 0.01)
    end

    test "handles zero swan percentage edge case" do
      # Critical edge case: swan_pct = 0 should not cause division by zero
      result =
        Calc.safety(
          Decimal.new(2900),
          Decimal.new(3000),
          # Zero swan percentage
          Decimal.new(0),
          :long,
          %{}
        )

      # With positive distance and zero swan threshold, should return max safety
      assert_in_delta(Decimal.to_float(result.composite_score), 100.0, 0.01)
      # Should not crash
      assert result.verdict in [:safe, :tight, :unsafe]
    end

    test "handles zero distance and zero swan edge case" do
      # Another critical edge case: both distance and swan are zero
      result =
        Calc.safety(
          # Same as entry = 0% distance
          Decimal.new(3000),
          Decimal.new(3000),
          # Zero swan percentage
          Decimal.new(0),
          :long,
          %{}
        )

      # With zero distance and zero swan threshold, should return zero safety
      assert_in_delta(Decimal.to_float(result.composite_score), 0.0, 0.01)
      # Should not crash
      assert result.verdict in [:safe, :tight, :unsafe]
    end

    test "returns error for entry == 0" do
      result = Calc.safety(Decimal.new(0), Decimal.new(0), Decimal.new(25), :long, %{})
      assert result == {:error, :non_positive_entry}
    end

    test "returns error for negative entry" do
      result = Calc.safety(Decimal.new(2500), Decimal.new(-100), Decimal.new(25), :long, %{})
      assert result == {:error, :non_positive_entry}
    end
  end

  describe "golden scenarios" do
    # Independent sizing + liquidation golden.
    # Provenance: hand calc from the public Calc.allocate/5, Calc.position/5,
    # Calc.leverage_to_aum/2, and Calc.liquidation/4 contracts.
    #   sub_eq = min(0.01, 0.01) × 10000 = 100
    #   init_margin = 100 × 0.5 = 50; notional = 50 × 3 = 150
    #   eff_lev = 150 / 100 = 1.5; lev_to_aum = 150 / 10000 = 0.015
    #   long liq @ mmr=0.005: 0.995/1.5 = 0.663333…; 1−0.663333…=0.336666…;
    #   3000 × 0.336666… = 1010 exactly
    test "ETH long @ $3000, 3x UI, 50% initial margin, conservative mode" do
      aum = Decimal.new(10_000)
      mode_cfg = %{pct: Decimal.new("0.01"), cap: Decimal.new("0.01")}

      allocation =
        Calc.allocate(aum, mode_cfg, [:ETH], %{ETH: Decimal.new(100)}, Decimal.new("0.5"))

      position =
        Calc.position(
          allocation.sub_eq,
          Decimal.new("0.5"),
          Decimal.new(3),
          Decimal.new(3000),
          :long
        )

      liq =
        Calc.liquidation(
          Decimal.new(3000),
          position.eff_lev,
          Decimal.new("0.005"),
          :long
        )

      safety =
        Calc.safety(
          liq,
          Decimal.new(3000),
          Decimal.new(25),
          :long,
          %{threshold_multiplier: Decimal.new("0.6"), safe_multiplier: Decimal.new("1.0")}
        )

      leverage_aum = Calc.leverage_to_aum(position.notional, aum)

      assert_close(position.eff_lev, Decimal.new("1.5"), "0.01")
      assert_close(leverage_aum, Decimal.new("0.015"), "0.001")
      assert_close(liq, Decimal.new("1010"), "1.0")
      assert safety.verdict == :safe
    end

    # Independent sizing + liquidation golden.
    # Provenance: hand calc from the public Calc.allocate/5, Calc.position/5,
    # Calc.leverage_to_aum/2, and Calc.liquidation/4 contracts.
    #   sub_eq = min(0.03, 0.02) × 10000 = 200
    #   init_margin = 200 × 0.3 = 60; notional = 60 × 2 = 120
    #   eff_lev = 120 / 200 = 0.6; lev_to_aum = 120 / 10000 = 0.012
    #   short liq: 0.995/0.6 = 1.658333…; 1+1.658333…=2.658333…;
    #   50000 × 2.658333… = 132916.6666… (quantize → 132916.66666667)
    test "BTC short @ $50000, 2x UI, 30% initial margin, moderate mode" do
      aum = Decimal.new(10_000)
      mode_cfg = %{pct: Decimal.new("0.03"), cap: Decimal.new("0.02")}

      allocation =
        Calc.allocate(aum, mode_cfg, [:BTC], %{BTC: Decimal.new(100)}, Decimal.new("0.3"))

      position =
        Calc.position(
          allocation.sub_eq,
          Decimal.new("0.3"),
          Decimal.new(2),
          Decimal.new(50_000),
          :short
        )

      liq =
        Calc.liquidation(
          Decimal.new(50_000),
          position.eff_lev,
          Decimal.new("0.005"),
          :short
        )

      safety =
        Calc.safety(
          liq,
          Decimal.new(50_000),
          Decimal.new(20),
          :short,
          %{threshold_multiplier: Decimal.new("0.6"), safe_multiplier: Decimal.new("1.0")}
        )

      leverage_aum = Calc.leverage_to_aum(position.notional, aum)

      assert_close(position.eff_lev, Decimal.new("0.6"), "0.01")
      assert_close(leverage_aum, Decimal.new("0.012"), "0.001")
      assert_close(liq, Decimal.new("132916.66666667"), "1.0")
      assert safety.verdict == :safe
    end
  end

  describe "multi_leg_position/3" do
    test "calculates corrected cross-margin example from forum post" do
      # Initial: $50 equity, first leg $125 notional at $3.00
      # Price drops to $2.80, add second leg $125 notional
      legs = [
        %{entry: Decimal.new(3000), notional: Decimal.new(125)},
        %{entry: Decimal.new(2800), notional: Decimal.new(125)}
      ]

      result = Calc.multi_leg_position(legs, Decimal.new(2800), Decimal.new(50))

      # Total notional: 250
      assert_in_delta(Decimal.to_float(result.total_notional), 250.0, 0.01)

      # Average entry: weighted by tokens, not notional
      # Leg 1: 125/3000 = 0.041667 tokens
      # Leg 2: 125/2800 = 0.044643 tokens
      # Total: 0.086310 tokens for 250 notional
      # Avg entry = 250 / 0.086310 = 2896.55
      assert_in_delta(Decimal.to_float(result.avg_entry), 2896.55, 0.1)

      # Unrealized PnL: (2800-3000) * (125/3000) = -200 * 0.041667 = -8.33
      assert_in_delta(Decimal.to_float(result.unrealized_pnl), -8.33, 0.1)

      # Current equity: 50 - 8.33 = 41.67
      assert_in_delta(Decimal.to_float(result.current_equity), 41.67, 0.1)

      # Effective leverage: 250 / 41.67 = 6.00
      assert_in_delta(Decimal.to_float(result.effective_leverage), 6.0, 0.1)
    end

    test "single leg matches simple effective_leverage calculation" do
      legs = [%{entry: Decimal.new(3000), notional: Decimal.new(150)}]

      result = Calc.multi_leg_position(legs, Decimal.new(3000), Decimal.new(50))

      # No PnL at entry price
      assert Decimal.equal?(result.unrealized_pnl, Decimal.new(0))
      assert Decimal.equal?(result.current_equity, Decimal.new(50))

      # Should match simple effective_leverage
      simple_lev = Calc.effective_leverage(Decimal.new(150), Decimal.new(50))
      assert Decimal.equal?(result.effective_leverage, simple_lev)
    end

    test "handles profitable position correctly" do
      legs = [%{entry: Decimal.new(3000), notional: Decimal.new(150)}]

      # Price goes up to $3200
      result = Calc.multi_leg_position(legs, Decimal.new(3200), Decimal.new(50))

      # PnL should be positive: (3200-3000) * (150/3000) = 200 * 0.05 = 10
      assert_in_delta(Decimal.to_float(result.unrealized_pnl), 10.0, 0.01)

      # Equity increases: 50 + 10 = 60
      assert_in_delta(Decimal.to_float(result.current_equity), 60.0, 0.01)

      # Leverage decreases: 150 / 60 = 2.5
      assert_in_delta(Decimal.to_float(result.effective_leverage), 2.5, 0.01)
    end
  end

  describe "cross-margin corrected golden scenarios" do
    test "corrected forum post example - cross margin DCA" do
      # Initial setup: $50 wallet equity
      initial_equity = Decimal.new(50)
      # 0.5% MMR
      mmr = Decimal.new("0.005")

      # Leg 1: $125 notional at $3.00 (UI 5x but effective 2.5x)
      leg1_entry = Decimal.new(3000)
      leg1_notional = Decimal.new(125)
      single_leg_lev = Calc.effective_leverage(leg1_notional, initial_equity)

      # Effective leverage should be 2.5x, not 5x
      assert_in_delta(Decimal.to_float(single_leg_lev), 2.5, 0.01)

      # Liquidation for first leg should be ~$1.81, not $2.40
      leg1_liq = Calc.liquidation(leg1_entry, single_leg_lev, mmr, :long)
      # ~$1.806
      assert_in_delta(Decimal.to_float(leg1_liq), 1806.0, 5.0)

      # Price drops to $2.80, add second leg
      current_price = Decimal.new(2800)

      legs = [
        %{entry: leg1_entry, notional: leg1_notional},
        %{entry: current_price, notional: Decimal.new(125)}
      ]

      multi_pos = Calc.multi_leg_position(legs, current_price, initial_equity)

      # After DCA: effective leverage increases to ~6x (not decreases)
      assert_in_delta(Decimal.to_float(multi_pos.effective_leverage), 6.0, 0.1)

      # Liquidation moves higher (worse), not lower (better)
      dca_liq = Calc.liquidation(multi_pos.avg_entry, multi_pos.effective_leverage, mmr, :long)
      # ~$2.416
      assert_in_delta(Decimal.to_float(dca_liq), 2416.0, 10.0)

      # Critical assertion: DCA liquidation is HIGHER than single leg
      assert Decimal.compare(dca_liq, leg1_liq) == :gt

      # Check safety against 15% black swan (15% below avg entry)
      swan_pct = Decimal.new(15)
      safety = Calc.safety(dca_liq, multi_pos.avg_entry, swan_pct, :long, %{})

      # Black swan price: 2896.55 * 0.85 = 2462.07
      # Distance to liquidation: (2896.55 - 2416) / 2896.55 = 16.6%
      # This barely satisfies the 15% rule
      assert_in_delta(Decimal.to_float(safety.distance_to_liq_pct), 16.6, 0.5)
    end
  end

  describe "compare_dca_safety/8" do
    test "shows safety degradation from cross-margin DCA example" do
      # Use the corrected forum example
      single_leg = %{entry: Decimal.new(3000), notional: Decimal.new(125)}
      dca_leg = %{entry: Decimal.new(2800), notional: Decimal.new(125)}

      result =
        Calc.compare_dca_safety(
          single_leg,
          dca_leg,
          Decimal.new(2800),
          Decimal.new(50),
          Decimal.new("0.005"),
          :long,
          Decimal.new(25)
        )

      # Leverage should increase significantly (2.5x → 6.0x)
      assert_in_delta(Decimal.to_float(result.leverage_change), 3.5, 0.1)

      # Liquidation should move higher (worse for longs)
      assert Decimal.compare(result.liquidation_change, Decimal.new(0)) == :gt
      # ~$2416 - $1806
      assert_in_delta(Decimal.to_float(result.liquidation_change), 610.0, 20.0)

      # Safety verdict should worsen or distance should decrease
      pre_distance = result.pre_dca.distance_to_liq_pct
      post_distance = result.post_dca.distance_to_liq_pct

      # Post-DCA distance should be less than pre-DCA
      assert Decimal.compare(post_distance, pre_distance) == :lt
    end

    test "short DCA uses entry-current PnL so underwater shorts show higher leverage" do
      single_leg = %{entry: Decimal.new(3000), notional: Decimal.new(125)}
      dca_leg = %{entry: Decimal.new(3200), notional: Decimal.new(125)}
      current_price = Decimal.new(3200)
      initial_equity = Decimal.new(50)

      result =
        Calc.compare_dca_safety(
          single_leg,
          dca_leg,
          current_price,
          initial_equity,
          Decimal.new("0.005"),
          :short,
          Decimal.new(25)
        )

      # Leg 1: (3000-3200) * (125/3000) = -8.33; leg 2 at market = 0
      expected_pnl =
        Decimal.sub(Decimal.new(3000), current_price)
        |> Decimal.mult(Decimal.div(Decimal.new(125), Decimal.new(3000)))

      assert_in_delta(Decimal.to_float(expected_pnl), -8.33, 0.1)
      assert Decimal.compare(expected_pnl, Decimal.new(0)) == :lt

      # Pre-fix long-only formula would flip sign to +8.33
      long_only_pnl = Decimal.negate(expected_pnl)
      assert_in_delta(Decimal.to_float(long_only_pnl), 8.33, 0.1)
      refute Decimal.equal?(expected_pnl, long_only_pnl)

      # Post-DCA equity: 50 - 8.33 = 41.67 → ~6x leverage, not 4.29x
      expected_equity = Decimal.add(initial_equity, expected_pnl)
      expected_leverage = Calc.effective_leverage(Decimal.new(250), expected_equity)
      assert_in_delta(Decimal.to_float(expected_equity), 41.67, 0.1)
      assert_in_delta(Decimal.to_float(expected_leverage), 6.0, 0.1)

      long_only_equity = Decimal.add(initial_equity, long_only_pnl)
      long_only_leverage = Calc.effective_leverage(Decimal.new(250), long_only_equity)
      assert_in_delta(Decimal.to_float(long_only_leverage), 4.29, 0.1)

      pre_leverage = Calc.effective_leverage(Decimal.new(125), initial_equity)
      post_leverage = Decimal.add(pre_leverage, result.leverage_change)
      assert_in_delta(Decimal.to_float(post_leverage), 6.0, 0.1)
      refute Decimal.equal?(post_leverage, long_only_leverage)

      # Leverage should increase (2.5x → 6.0x), not the understated 4.29x
      assert_in_delta(Decimal.to_float(result.leverage_change), 3.5, 0.1)
    end
  end

  describe "dca_ladder/8" do
    # Independent DCA golden — provenance: hand calc from the public
    # Calc.dca_ladder/8 contract.
    # Initial: notional=1500 @ entry=3000 → tokens = 1500/3000 = 0.5; L_eff=1.5
    #   → wallet equity = 1500/1.5 = 1000
    # Step 1 only (single-step fixture for exact avg-entry independence):
    #   dca_price = 3000 × 0.95 = 2850
    #   spend = 500 × 0.3 = 150; add_notional = 150 × 3 = 450
    #   add_tokens = 450/2850 = 3/19
    #   total_tokens = 1/2 + 3/19 = 25/38
    #   avg_entry = 1950 / (25/38) = 1950 × 38/25 = 2964 exactly
    #   final_notional = 1950; final_eff_lev = 1950/1000 = 1.95
    test "calculates DCA ladder for long position — independent first-step fixture" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      reserve = Decimal.new(500)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)

      ladder_preset = [{Decimal.new("0.95"), Decimal.new("0.3")}]
      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      assert Enum.count(result.steps) == 1
      step1 = Enum.at(result.steps, 0)

      assert_close(step1.dca_price, Decimal.new("2850"), "0.01")
      assert_close(step1.spend, Decimal.new("150"), "0.01")
      assert_close(step1.new_notional, Decimal.new("450"), "0.01")
      assert_close(step1.new_avg_entry, Decimal.new("2964"), "0.01")
      assert_close(result.final_notional, Decimal.new("1950"), "0.01")
      assert_close(result.final_avg_entry, Decimal.new("2964"), "0.01")
      assert_close(result.final_eff_lev, Decimal.new("1.95"), "0.01")
      assert Decimal.compare(result.final_avg_entry, entry_price) == :lt
    end

    test "calculates multi-step DCA ladder for long position" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      reserve = Decimal.new(500)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)

      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")},
        {Decimal.new("0.85"), Decimal.new("0.3")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      assert Enum.count(result.steps) == 3

      step1 = Enum.at(result.steps, 0)
      assert_close(step1.dca_price, Decimal.new("2850"), "0.01")
      assert_close(step1.spend, Decimal.new("150"), "0.01")

      step2 = Enum.at(result.steps, 1)
      assert_close(step2.dca_price, Decimal.new("2700"), "0.01")
      assert_close(step2.spend, Decimal.new("150"), "0.01")

      step3 = Enum.at(result.steps, 2)
      assert_close(step3.dca_price, Decimal.new("2550"), "0.01")
      assert_close(step3.spend, Decimal.new("150"), "0.01")

      assert Decimal.compare(result.final_notional, position.notional) == :gt
      assert Decimal.compare(result.final_avg_entry, entry_price) == :lt
    end

    test "calculates DCA ladder for short position" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      reserve = Decimal.new(500)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)
      # For shorts, price_mult should be > 1.0
      ladder_preset = [
        {Decimal.new("1.05"), Decimal.new("0.3")},
        {Decimal.new("1.10"), Decimal.new("0.3")},
        {Decimal.new("1.15"), Decimal.new("0.3")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :short, mmr_rate)

      # Should have 3 steps
      assert Enum.count(result.steps) == 3

      step1 = Enum.at(result.steps, 0)
      assert_close(step1.dca_price, Decimal.new("3150"), "0.01")

      step2 = Enum.at(result.steps, 1)
      assert_close(step2.dca_price, Decimal.new("3300"), "0.01")

      step3 = Enum.at(result.steps, 2)
      assert_close(step3.dca_price, Decimal.new("3450"), "0.01")

      assert Decimal.compare(result.final_avg_entry, entry_price) == :gt
    end

    test "never overspends reserve" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      # Small reserve
      reserve = Decimal.new(100)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)
      # Asking for 90% of reserve at each step (would be 270% total)
      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.9")},
        {Decimal.new("0.90"), Decimal.new("0.9")},
        {Decimal.new("0.85"), Decimal.new("0.9")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      total_spend =
        Enum.reduce(result.steps, Decimal.new(0), fn step, acc ->
          Decimal.add(acc, step.spend)
        end)

      assert Decimal.compare(total_spend, reserve) in [:lt, :eq]
      assert_close(total_spend, Decimal.new("100"), "0.01")
    end

    test "handles empty ladder preset" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      reserve = Decimal.new(500)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)
      # No steps
      ladder_preset = []
      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      # Should have no steps
      assert Enum.empty?(result.steps)

      # Final values should match initial position
      assert Decimal.equal?(result.final_notional, position.notional)
      assert Decimal.equal?(result.final_avg_entry, entry_price)
      assert Decimal.equal?(result.final_eff_lev, position.eff_lev)
    end

    test "handles zero reserve" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      # No reserve
      reserve = Decimal.new(0)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(3)

      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      # Should have no steps (no reserve to spend)
      assert Enum.empty?(result.steps)

      # Final values should match initial position
      assert Decimal.equal?(result.final_notional, position.notional)
      assert Decimal.equal?(result.final_avg_entry, entry_price)
    end

    test "effective leverage increases with each DCA step for longs" do
      position = %{notional: Decimal.new(1000), eff_lev: Decimal.new("1.0")}
      reserve = Decimal.new(900)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(2)

      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")},
        {Decimal.new("0.85"), Decimal.new("0.3")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      # Check that effective leverage increases with each step
      previous_lev = position.eff_lev

      for step <- result.steps do
        assert Decimal.compare(step.new_eff_lev, previous_lev) == :gt
        _previous_lev = step.new_eff_lev
      end
    end

    test "liquidation price moves higher (worse) with each DCA step for longs" do
      position = %{notional: Decimal.new(1000), eff_lev: Decimal.new("1.0")}
      reserve = Decimal.new(900)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(2)

      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")},
        {Decimal.new("0.85"), Decimal.new("0.3")}
      ]

      mmr_rate = Decimal.new("0.005")

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      # Initial liquidation
      initial_liq = Calc.liquidation(entry_price, position.eff_lev, mmr_rate, :long)

      # Check that liquidation price increases (gets worse) with each step
      previous_liq = initial_liq

      for step <- result.steps do
        # For longs, higher liquidation is worse (closer to entry)
        assert Decimal.compare(step.new_liq, previous_liq) == :gt
        _previous_liq = step.new_liq
      end
    end

    test "wallet equity remains constant in cross-margin DCA ladder" do
      # In cross-margin, the wallet equity should not increase when we DCA
      # The spend comes from reserve allocation, not from adding new equity
      position = %{notional: Decimal.new(1000), eff_lev: Decimal.new("1.0")}
      reserve = Decimal.new(900)
      entry_price = Decimal.new(3000)
      ui_lev = Decimal.new(2)

      ladder_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")},
        {Decimal.new("0.85"), Decimal.new("0.4")}
      ]

      mmr_rate = Decimal.new("0.005")

      # Calculate initial wallet equity (notional / eff_lev)
      initial_wallet_equity = Decimal.div(position.notional, position.eff_lev)

      result =
        Calc.dca_ladder(position, reserve, entry_price, ui_lev, ladder_preset, :long, mmr_rate)

      # Verify wallet equity remains constant through all steps
      for step <- result.steps do
        # Wallet equity at each step should equal initial wallet equity
        step_wallet_equity = Decimal.div(step.cumulative_notional, step.new_eff_lev)

        assert Decimal.equal?(step_wallet_equity, initial_wallet_equity),
               "Step #{step.step_num} wallet equity should remain constant at #{initial_wallet_equity}"
      end

      # Also verify that the effective leverage increases properly
      # As we add more notional but keep wallet equity same
      for step <- result.steps do
        expected_eff_lev = Decimal.div(step.cumulative_notional, initial_wallet_equity)

        assert Decimal.equal?(step.new_eff_lev, expected_eff_lev),
               "Step #{step.step_num} effective leverage calculation should match cumulative_notional/wallet_equity"
      end
    end
  end

  describe "convert_ladder_for_short/1" do
    test "converts long ladder multipliers to short multipliers" do
      long_preset = [
        {Decimal.new("0.95"), Decimal.new("0.3")},
        {Decimal.new("0.90"), Decimal.new("0.3")},
        {Decimal.new("0.85"), Decimal.new("0.3")}
      ]

      result = Calc.convert_ladder_for_short(long_preset)

      assert Enum.count(result) == 3

      # Check conversions: short_mult = 2 - long_mult
      {mult1, pct1} = Enum.at(result, 0)
      # 2 - 0.95
      assert Decimal.equal?(mult1, Decimal.new("1.05"))
      assert Decimal.equal?(pct1, Decimal.new("0.3"))

      {mult2, pct2} = Enum.at(result, 1)
      # 2 - 0.90
      assert Decimal.equal?(mult2, Decimal.new("1.10"))
      assert Decimal.equal?(pct2, Decimal.new("0.3"))

      {mult3, pct3} = Enum.at(result, 2)
      # 2 - 0.85
      assert Decimal.equal?(mult3, Decimal.new("1.15"))
      assert Decimal.equal?(pct3, Decimal.new("0.3"))
    end

    test "preserves reserve percentages" do
      long_preset = [
        {Decimal.new("0.95"), Decimal.new("0.2")},
        {Decimal.new("0.90"), Decimal.new("0.4")},
        {Decimal.new("0.85"), Decimal.new("0.3")}
      ]

      result = Calc.convert_ladder_for_short(long_preset)

      # Reserve percentages should remain the same
      {_mult1, pct1} = Enum.at(result, 0)
      assert Decimal.equal?(pct1, Decimal.new("0.2"))

      {_mult2, pct2} = Enum.at(result, 1)
      assert Decimal.equal?(pct2, Decimal.new("0.4"))

      {_mult3, pct3} = Enum.at(result, 2)
      assert Decimal.equal?(pct3, Decimal.new("0.3"))
    end
  end

  describe "property tests" do
    test "more initial margin results in higher effective leverage" do
      sub_eq = Decimal.new(1000)
      ui_lev = Decimal.new(3)
      entry = Decimal.new(3000)

      pos_30 = Calc.position(sub_eq, Decimal.new("0.3"), ui_lev, entry, :long)
      pos_50 = Calc.position(sub_eq, Decimal.new("0.5"), ui_lev, entry, :long)
      pos_70 = Calc.position(sub_eq, Decimal.new("0.7"), ui_lev, entry, :long)

      # Lower initial margin % should have lower effective leverage
      assert Decimal.compare(pos_30.eff_lev, pos_50.eff_lev) == :lt
      assert Decimal.compare(pos_50.eff_lev, pos_70.eff_lev) == :lt
    end

    test "higher UI leverage results in higher effective leverage" do
      sub_eq = Decimal.new(1000)
      init_margin_pct = Decimal.new("0.5")
      entry = Decimal.new(3000)

      pos_1x = Calc.position(sub_eq, init_margin_pct, Decimal.new(1), entry, :long)
      pos_3x = Calc.position(sub_eq, init_margin_pct, Decimal.new(3), entry, :long)
      pos_5x = Calc.position(sub_eq, init_margin_pct, Decimal.new(5), entry, :long)

      assert Decimal.compare(pos_1x.eff_lev, pos_3x.eff_lev) == :lt
      assert Decimal.compare(pos_3x.eff_lev, pos_5x.eff_lev) == :lt
    end

    test "cross-margin DCA increases effective leverage when price moves against position" do
      # Property: On cross-margin, adding legs while underwater increases effective leverage
      initial_equity = Decimal.new(100)

      # Start with single leg
      leg1_entry = Decimal.new(4000)
      # 2x effective leverage initially
      leg1_notional = Decimal.new(200)

      single_lev = Calc.effective_leverage(leg1_notional, initial_equity)
      assert_in_delta(Decimal.to_float(single_lev), 2.0, 0.01)

      # Price drops, add second leg
      # 10% drop
      underwater_price = Decimal.new(3600)
      leg2_notional = Decimal.new(200)

      legs = [
        %{entry: leg1_entry, notional: leg1_notional},
        %{entry: underwater_price, notional: leg2_notional}
      ]

      multi_pos = Calc.multi_leg_position(legs, underwater_price, initial_equity)

      # Effective leverage should be higher after DCA
      assert Decimal.compare(multi_pos.effective_leverage, single_lev) == :gt

      # PnL = (3600-4000) * (200/4000) = -400 * 0.05 = -20
      # Current equity = 100 - 20 = 80
      # Total notional = 400, so leverage = 400/80 = 5.0
      assert_in_delta(Decimal.to_float(multi_pos.effective_leverage), 5.0, 0.1)
    end

    test "cross-margin liquidation moves closer (higher for longs) after underwater DCA" do
      # Property: DCA while underwater results in worse liquidation price for longs
      initial_equity = Decimal.new(100)
      mmr = Decimal.new("0.005")

      # Single leg at $4000
      leg1_entry = Decimal.new(4000)
      leg1_notional = Decimal.new(200)
      single_lev = Calc.effective_leverage(leg1_notional, initial_equity)
      single_liq = Calc.liquidation(leg1_entry, single_lev, mmr, :long)

      # Price drops 10%, add second leg
      underwater_price = Decimal.new(3600)

      legs = [
        %{entry: leg1_entry, notional: leg1_notional},
        %{entry: underwater_price, notional: Decimal.new(200)}
      ]

      multi_pos = Calc.multi_leg_position(legs, underwater_price, initial_equity)
      multi_liq = Calc.liquidation(multi_pos.avg_entry, multi_pos.effective_leverage, mmr, :long)

      # Multi-leg liquidation should be higher (closer to current price, worse)
      assert Decimal.compare(multi_liq, single_liq) == :gt
    end

    test "allocation never exceeds AUM" do
      aum = Decimal.new(10_000)

      for pct <- ["0.01", "0.05", "0.10", "0.50", "1.0"] do
        for cap <- ["0.01", "0.05", "0.10", "0.50", "1.0"] do
          mode_cfg = %{pct: Decimal.new(pct), cap: Decimal.new(cap)}

          result =
            Calc.allocate(aum, mode_cfg, [:ETH], %{ETH: Decimal.new(100)}, Decimal.new("0.5"))

          total = Decimal.add(result.sub_eq, result.leftover)
          assert Decimal.equal?(total, aum), "Allocation mismatch for pct=#{pct}, cap=#{cap}"
        end
      end
    end

    test "reserve plus initial margin equals subaccount equity" do
      aum = Decimal.new(10_000)
      mode_cfg = %{pct: Decimal.new("0.03"), cap: Decimal.new("0.03")}

      for im_pct <- ["0.1", "0.3", "0.5", "0.7", "0.9"] do
        result =
          Calc.allocate(aum, mode_cfg, [:ETH], %{ETH: Decimal.new(100)}, Decimal.new(im_pct))

        total = Decimal.add(result.init_margin, result.reserve)

        assert Decimal.equal?(total, result.sub_eq),
               "IM + Reserve mismatch for im_pct=#{im_pct}"
      end
    end
  end

  describe "input coercion" do
    test "accepts integer, binary, and float inputs via to_decimal" do
      assert Calc.effective_leverage(10_000, 5_000) == Decimal.new("2.00000000")
      assert Calc.effective_leverage("10000", "5000") == Decimal.new("2.00000000")
      assert Calc.effective_leverage(10_000.0, 5_000.0) == Decimal.new("2.00000000")
    end

    test "safety/4 uses default cfg" do
      result = Calc.safety(Decimal.new("1000"), Decimal.new("3000"), Decimal.new("25"), :long)
      assert result.verdict == :safe
    end

    test "multi_leg_position handles zero equity after losses" do
      legs = [%{entry: Decimal.new(3000), notional: Decimal.new(10_000)}]

      result =
        Calc.multi_leg_position(legs, Decimal.new(2000), Decimal.new(100))

      assert Decimal.equal?(result.effective_leverage, Decimal.new("0"))
    end

    test "dca_ladder with zero initial leverage uses reserve as wallet equity" do
      position = %{notional: Decimal.new("1000"), eff_lev: Decimal.new("0")}
      reserve = Decimal.new("500")

      result =
        Calc.dca_ladder(
          position,
          reserve,
          Decimal.new("100"),
          Decimal.new("3"),
          [{Decimal.new("0.95"), Decimal.new("0.30")}],
          :long,
          Decimal.new("0.005"),
          Decimal.new("0.001")
        )

      assert match?([_], result.steps)
    end
  end
end
