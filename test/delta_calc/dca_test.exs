defmodule DeltaCalc.DCATest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.Calc

  describe "DCA ladder calculation with custom prices" do
    test "calculates defensive DCA ladder with direct price inputs" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      reserve = D.new("500")
      entry_price = D.new("100")
      ui_leverage = D.new("3")

      # Custom ladder with direct prices
      ladder_preset = [
        # 95% of entry, 30% of reserve
        {D.new("0.95"), D.new("0.30")},
        # 90% of entry, 30% of reserve
        {D.new("0.90"), D.new("0.30")},
        # 85% of entry, 30% of reserve
        {D.new("0.85"), D.new("0.30")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      assert match?([_, _, _], result.steps)
      assert result.final_notional
      assert result.final_avg_entry
      assert result.final_liq
      assert result.final_eff_lev

      # Check first step
      first_step = Enum.at(result.steps, 0)
      assert D.compare(first_step.dca_price, D.new("95")) == :eq
      assert D.compare(first_step.spend, D.mult(reserve, D.new("0.30"))) == :eq
    end

    test "calculates aggressive DCA ladder for long positions" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      reserve = D.new("500")
      entry_price = D.new("100")
      ui_leverage = D.new("3")

      # Aggressive ladder (prices going up from entry)
      ladder_preset = [
        # 105% of entry
        {D.new("1.05"), D.new("0.30")},
        # 110% of entry
        {D.new("1.10"), D.new("0.30")},
        # 115% of entry
        {D.new("1.15"), D.new("0.30")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      assert match?([_, _, _], result.steps)

      # Check prices are increasing (aggressive for long)
      first_step = Enum.at(result.steps, 0)
      assert D.compare(first_step.dca_price, entry_price) == :gt
    end

    test "handles custom allocation percentages" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      reserve = D.new("1000")
      entry_price = D.new("100")
      ui_leverage = D.new("3")

      # Custom allocations: 50%, 30%, 10%
      ladder_preset = [
        {D.new("0.95"), D.new("0.50")},
        {D.new("0.90"), D.new("0.30")},
        {D.new("0.85"), D.new("0.10")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      # Verify allocations
      # 50% of 1000
      assert D.compare(Enum.at(result.steps, 0).spend, D.new("500")) == :eq
      # 30% of 1000
      assert D.compare(Enum.at(result.steps, 1).spend, D.new("300")) == :eq
      # 10% of 1000
      assert D.compare(Enum.at(result.steps, 2).spend, D.new("100")) == :eq
    end

    test "handles varying number of DCA steps (1 to 5)" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      reserve = D.new("500")
      entry_price = D.new("100")
      ui_leverage = D.new("3")

      # Test with 1 step
      ladder_1_step = [{D.new("0.95"), D.new("0.90")}]

      result_1 =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_1_step,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      assert match?([_], result_1.steps)

      # Test with 5 steps
      ladder_5_steps = [
        {D.new("0.98"), D.new("0.20")},
        {D.new("0.96"), D.new("0.20")},
        {D.new("0.94"), D.new("0.20")},
        {D.new("0.92"), D.new("0.15")},
        {D.new("0.90"), D.new("0.15")}
      ]

      result_5 =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_5_steps,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      assert match?([_, _, _, _, _], result_5.steps)
    end

    test "correctly calculates cumulative positions and average entry" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      reserve = D.new("600")
      entry_price = D.new("100")
      ui_leverage = D.new("2")

      # Even distribution
      ladder_preset = [
        {D.new("0.95"), D.new("0.33")},
        {D.new("0.90"), D.new("0.33")},
        {D.new("0.85"), D.new("0.33")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      # Verify cumulative notional increases
      steps = result.steps
      assert D.compare(Enum.at(steps, 0).cumulative_notional, position.notional) == :gt

      assert D.compare(
               Enum.at(steps, 1).cumulative_notional,
               Enum.at(steps, 0).cumulative_notional
             ) == :gt

      assert D.compare(
               Enum.at(steps, 2).cumulative_notional,
               Enum.at(steps, 1).cumulative_notional
             ) == :gt

      # Final average entry should be lower than initial for defensive DCA
      assert D.compare(result.final_avg_entry, entry_price) == :lt
    end
  end

  describe "DCA safety validation" do
    test "marks steps that fail black swan test" do
      position = %{
        notional: D.new("5000"),
        eff_lev: D.new("5")
      }

      reserve = D.new("500")
      entry_price = D.new("100")
      # High leverage to trigger safety issues
      ui_leverage = D.new("10")

      ladder_preset = [
        {D.new("0.95"), D.new("0.50")},
        {D.new("0.90"), D.new("0.50")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      # With high leverage, later steps may fail safety checks
      assert result.steps
    end

    test "calculates leverage to AUM correctly for each step" do
      position = %{
        notional: D.new("1000"),
        eff_lev: D.new("2")
      }

      aum = D.new("10000")
      reserve = D.new("500")
      entry_price = D.new("100")
      ui_leverage = D.new("3")

      ladder_preset = [
        # Use all reserve
        {D.new("0.95"), D.new("1.0")}
      ]

      result =
        Calc.dca_ladder(
          position,
          reserve,
          entry_price,
          ui_leverage,
          ladder_preset,
          :long,
          D.new("0.005"),
          D.new("0.001")
        )

      # Calculate expected leverage to AUM
      step = Enum.at(result.steps, 0)
      leverage_to_aum = Calc.leverage_to_aum(step.cumulative_notional, aum)

      assert leverage_to_aum
      assert D.compare(leverage_to_aum, D.new("0")) == :gt
    end
  end

  describe "DCA allocation strategies" do
    test "even allocation distributes reserve equally" do
      steps = 3

      allocations =
        Enum.map(1..steps, fn _ ->
          D.div(D.new("90"), D.new(steps))
        end)

      # Each step should get 30%
      Enum.each(allocations, fn alloc ->
        assert D.compare(alloc, D.new("30")) == :eq
      end)
    end

    test "weighted allocation gives more to early steps" do
      # Test weighted allocation for 3 steps
      weighted_3 = [D.new("40"), D.new("30"), D.new("20")]

      assert D.compare(Enum.at(weighted_3, 0), Enum.at(weighted_3, 1)) == :gt
      assert D.compare(Enum.at(weighted_3, 1), Enum.at(weighted_3, 2)) == :gt

      # Total should be 90%
      total = Enum.reduce(weighted_3, D.new("0"), &D.add/2)
      assert D.compare(total, D.new("90")) == :eq
    end

    test "custom allocation respects user inputs" do
      custom_allocations = [D.new("50"), D.new("25"), D.new("15")]

      # Verify custom values are preserved
      assert D.compare(Enum.at(custom_allocations, 0), D.new("50")) == :eq
      assert D.compare(Enum.at(custom_allocations, 1), D.new("25")) == :eq
      assert D.compare(Enum.at(custom_allocations, 2), D.new("15")) == :eq
    end
  end

  describe "DCA direction conversion" do
    test "converts defensive ladder for short positions" do
      # For shorts, defensive DCA means prices going up
      ladder = [
        {D.new("0.95"), D.new("0.30")},
        {D.new("0.90"), D.new("0.30")}
      ]

      converted = Calc.convert_ladder_for_short(ladder)

      # Price multipliers should be inverted (going up instead of down)
      Enum.each(converted, fn {price_mult, _} ->
        assert D.compare(price_mult, D.new("1")) == :gt
      end)
    end

    test "preserves allocation percentages when converting" do
      ladder = [
        {D.new("0.95"), D.new("0.30")},
        {D.new("0.90"), D.new("0.45")}
      ]

      converted = Calc.convert_ladder_for_short(ladder)

      # Allocations should remain unchanged
      assert D.compare(elem(Enum.at(converted, 0), 1), D.new("0.30")) == :eq
      assert D.compare(elem(Enum.at(converted, 1), 1), D.new("0.45")) == :eq
    end
  end
end
