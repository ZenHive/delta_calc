defmodule DeltaCalc.DCAPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Decimal, as: D
  alias DeltaCalc.Calc

  describe "DCA ladder property tests" do
    property "DCA ladder always produces valid results for any valid inputs" do
      check all(
              # Generate valid position parameters
              initial_notional <- float(min: 100.0, max: 100_000.0),
              initial_leverage <- float(min: 1.0, max: 20.0),
              reserve <- float(min: 10.0, max: 50_000.0),
              entry_price <- float(min: 0.01, max: 100_000.0),
              ui_leverage <- float(min: 1.0, max: 50.0),
              mmr_rate <- float(min: 0.001, max: 0.1),
              mark_buffer <- float(min: 0.0, max: 0.01),
              side <- member_of([:long, :short]),
              num_steps <- integer(1..5)
            ) do
        position = %{
          notional: D.new(to_string(initial_notional)),
          eff_lev: D.new(to_string(initial_leverage))
        }

        # Generate a valid ladder preset
        ladder_preset = generate_valid_ladder(num_steps)

        result =
          Calc.dca_ladder(
            position,
            D.new(to_string(reserve)),
            D.new(to_string(entry_price)),
            D.new(to_string(ui_leverage)),
            ladder_preset,
            side,
            D.new(to_string(mmr_rate)),
            mark_buffer: D.new(to_string(mark_buffer))
          )

        # Property assertions
        assert result.steps
        assert length(result.steps) <= num_steps
        assert result.final_notional
        assert result.final_avg_entry
        assert result.final_liq
        assert result.final_eff_lev

        # Final notional should be greater than or equal to initial
        assert D.compare(result.final_notional, position.notional) in [:gt, :eq]

        # Each step should have valid fields
        Enum.each(result.steps, fn step ->
          assert step.dca_price
          assert step.spend
          assert step.cumulative_notional
          assert step.new_avg_entry
          assert step.new_liq
          assert D.compare(step.spend, D.new("0")) == :gt
        end)
      end
    end

    property "cumulative notional always increases with each DCA step" do
      check all(
              initial_notional <- float(min: 100.0, max: 10_000.0),
              reserve <- float(min: 100.0, max: 5_000.0),
              entry_price <- float(min: 1.0, max: 10_000.0),
              ui_leverage <- float(min: 1.0, max: 10.0),
              num_steps <- integer(2..5)
            ) do
        position = %{
          notional: D.new(to_string(initial_notional)),
          eff_lev: D.new("2")
        }

        ladder_preset = generate_valid_ladder(num_steps)

        result =
          Calc.dca_ladder(
            position,
            D.new(to_string(reserve)),
            D.new(to_string(entry_price)),
            D.new(to_string(ui_leverage)),
            ladder_preset,
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        # Check that cumulative notional increases monotonically
        if match?([_, _ | _], result.steps) do
          result.steps
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.each(fn [step1, step2] ->
            assert D.compare(step2.cumulative_notional, step1.cumulative_notional) == :gt
          end)
        end
      end
    end

    property "DCA never uses more than available reserve" do
      check all(
              reserve <- float(min: 100.0, max: 10_000.0),
              entry_price <- float(min: 1.0, max: 10_000.0),
              num_steps <- integer(1..5)
            ) do
        position = %{
          notional: D.new("1000"),
          eff_lev: D.new("2")
        }

        reserve_decimal = D.new(to_string(reserve))
        ladder_preset = generate_valid_ladder(num_steps)

        result =
          Calc.dca_ladder(
            position,
            reserve_decimal,
            D.new(to_string(entry_price)),
            D.new("3"),
            ladder_preset,
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        # Total spent should not exceed reserve
        total_spent =
          result.steps
          |> Enum.map(& &1.spend)
          |> Enum.reduce(D.new("0"), &D.add/2)

        assert D.compare(total_spent, reserve_decimal) in [:lt, :eq]
      end
    end

    property "defensive DCA for long produces decreasing prices" do
      check all(
              entry_price <- float(min: 1.0, max: 10_000.0),
              num_steps <- integer(2..5)
            ) do
        position = %{
          notional: D.new("1000"),
          eff_lev: D.new("2")
        }

        # Generate defensive ladder (prices below entry)
        ladder_preset = generate_defensive_ladder(num_steps)

        result =
          Calc.dca_ladder(
            position,
            D.new("500"),
            D.new(to_string(entry_price)),
            D.new("3"),
            ladder_preset,
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        # For defensive long, prices should be below entry
        Enum.each(result.steps, fn step ->
          assert D.compare(step.dca_price, D.new(to_string(entry_price))) == :lt
        end)

        # Prices should decrease with each step
        if match?([_, _ | _], result.steps) do
          result.steps
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.each(fn [step1, step2] ->
            assert D.compare(step2.dca_price, step1.dca_price) == :lt
          end)
        end
      end
    end

    property "average entry price moves in expected direction" do
      check all(
              entry_price <- float(min: 10.0, max: 1000.0),
              num_steps <- integer(1..3)
            ) do
        entry_decimal = D.new(to_string(entry_price))

        position = %{
          notional: D.new("1000"),
          eff_lev: D.new("2")
        }

        # Create defensive ladder (prices below entry)
        ladder_preset = generate_defensive_ladder(num_steps)

        result =
          Calc.dca_ladder(
            position,
            D.new("500"),
            entry_decimal,
            D.new("3"),
            ladder_preset,
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        if result.steps != [] do
          # For defensive DCA on long, average entry should be lower than initial
          assert D.compare(result.final_avg_entry, entry_decimal) == :lt
        end
      end
    end
  end

  describe "edge cases" do
    property "handles zero reserve gracefully" do
      check all(entry_price <- float(min: 1.0, max: 10_000.0)) do
        position = %{
          notional: D.new("1000"),
          eff_lev: D.new("2")
        }

        result =
          Calc.dca_ladder(
            position,
            D.new("0"),
            D.new(to_string(entry_price)),
            D.new("3"),
            [{D.new("0.95"), D.new("0.30")}],
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        # Should have no steps with zero reserve
        assert result.steps == []
        assert D.compare(result.final_notional, position.notional) == :eq
      end
    end

    property "handles extreme leverage values" do
      check all(leverage <- float(min: 0.1, max: 100.0)) do
        position = %{
          notional: D.new("1000"),
          eff_lev: D.new(to_string(leverage))
        }

        result =
          Calc.dca_ladder(
            position,
            D.new("500"),
            D.new("100"),
            D.new(to_string(leverage)),
            [{D.new("0.95"), D.new("0.30")}],
            :long,
            D.new("0.005"),
            mark_buffer: D.new("0.001")
          )

        # Should always produce valid results
        assert result.final_notional
        assert result.final_liq
      end
    end

    property "handles extreme price movements" do
      check all(
              entry_price <- float(min: 1.0, max: 100_000.0),
              price_change_pct <- float(min: -99.0, max: 1000.0)
            ) do
        position = %{
          notional: D.new("1000"),
          eff_lev: D.new("2")
        }

        # Create ladder with extreme price movement
        price_mult = D.add(D.new("1"), D.div(D.new(to_string(price_change_pct)), D.new("100")))

        # Skip invalid price multipliers
        if D.compare(price_mult, D.new("0.01")) == :gt do
          ladder_preset = [{price_mult, D.new("0.30")}]

          result =
            Calc.dca_ladder(
              position,
              D.new("500"),
              D.new(to_string(entry_price)),
              D.new("3"),
              ladder_preset,
              :long,
              D.new("0.005"),
              mark_buffer: D.new("0.001")
            )

          assert result.final_notional
        end
      end
    end
  end

  # Helper functions for generating test data

  defp generate_valid_ladder(num_steps) do
    Enum.map(1..num_steps, fn i ->
      # Generate decreasing price multipliers for defensive DCA
      price_mult = D.sub(D.new("1"), D.mult(D.new("0.05"), D.new(to_string(i))))
      # Even allocation across steps (leaving 10% reserve)
      alloc = D.div(D.new("0.90"), D.new(to_string(num_steps)))
      {price_mult, alloc}
    end)
  end

  defp generate_defensive_ladder(num_steps) do
    Enum.map(1..num_steps, fn i ->
      # Defensive: prices decrease from entry
      price_mult = D.sub(D.new("1"), D.mult(D.new("0.03"), D.new(to_string(i))))
      alloc = D.div(D.new("0.90"), D.new(to_string(num_steps)))
      {price_mult, alloc}
    end)
  end
end
