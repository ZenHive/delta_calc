defmodule DeltaCalc.DomainInvariantsTest do
  @moduledoc """
  Cross-cutting DOMAIN invariants that per-task review cannot see.

  The harness reviewer grades one diff against one task: it checks mechanics
  (credo/dialyzer/coverage) and the task's own acceptance criteria, but it has
  no signal that a venue constant is wrong or that two modules disagree on a
  unit — that knowledge lives in the consumer's head, and a golden computed
  *with* the wrong constant ratifies the bug instead of catching it (CLAUDE.md
  § "Review Blind Spots"). This file is where those invariants become
  executable, computed independently of the formulas under test.

  ## Two groups

  - **Regression guards** (run by default): invariants that hold today. They
    fail loudly if a future change reintroduces a known class of bug.
  - **`@tag :domain_pending`** (excluded by default, see `test_helper.exs`):
    invariants that encode the *target* post-fix state for an open roadmap task.
    They are real assertions — red until the fix lands — not `assert true`
    placeholders. Run them with `mix test --include domain_pending` to watch
    each go green as its task lands. The fixing task's acceptance criteria
    include removing its `@tag :domain_pending`.

  Provenance for every numeric expectation is hand-computed from dimensional
  analysis in the comment above the assertion — never copied from the code
  under test (that is the failure mode task 45 exists to kill).
  """

  use ExUnit.Case, async: true

  alias DeltaCalc.Calc
  alias DeltaCalc.Fees
  alias DeltaCalc.Funding
  alias DeltaCalc.Hedging
  alias DeltaCalc.MarginBridge
  alias DeltaCalc.Pnl

  # Compare two Decimals within an absolute tolerance, failing loudly otherwise.
  defp assert_close(actual, expected, tolerance \\ "0.00000001") do
    diff = actual |> Decimal.sub(expected) |> Decimal.abs()

    assert Decimal.compare(diff, Decimal.new(tolerance)) != :gt,
           "expected #{Decimal.to_string(expected)} ± #{tolerance}, got #{Decimal.to_string(actual)}"
  end

  describe "funding-rate unit is a fraction everywhere (task 38)" do
    # Invariant: every funding-rate :value input across the library is a
    # FRACTION (0.0001 = 0.01%), matching Funding/Carry/Hedging — the canonical
    # convention. No module may treat the same numeric rate as a percent and
    # divide by 100 internally; a consumer who derives one rate and feeds it to
    # two modules must get dimensionally consistent results, not a silent 100x.
    #
    # Hand calc (rate = 0.0001 fraction, position = 10_000, periods = 3, 1 day):
    #   daily funding magnitude = 0.0001 * 10_000 * 3 = 3.0
    test "Hedging and MarginBridge agree on the funding-rate unit" do
      position = Decimal.new("10000")
      rate_fraction = Decimal.new("0.0001")
      periods = 3

      hedging_daily = Hedging.calculate_funding_cost(position, rate_fraction, periods)
      assert_close(hedging_daily, Decimal.new("3.0"))

      # MarginBridge must read the SAME fraction the same way (no /100).
      # negative_rate is the per-period rate; daily cost magnitude == 3.0.
      stress =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.0001"),
          position,
          1,
          periods_per_day: periods
        )

      assert_close(Decimal.abs(stress.daily_cost), Decimal.new("3.0"))
    end
  end

  describe "raw→daily scaling direction is consistent (task 37)" do
    # Invariant: daily = raw_per_period * periods_per_day, so a raw threshold
    # expressed on a DAILY basis is LARGER, not smaller. find_arbitrage_opportunities
    # must normalize min_delta for :daily_normalized entries by MULTIPLYING by
    # periods — matching the file's own @mixed_cadence_arbitrage_threshold
    # (= @arbitrage_threshold * periods), the one raw→daily conversion that is
    # already correct.
    #
    # Hand calc (min_delta = 0.001 raw per-period, default periods = 3):
    #   daily threshold = 0.001 * 3 = 0.003
    #   a daily delta of 0.002 is BELOW 0.003  -> excluded
    #   a daily delta of 0.004 is ABOVE 0.003  -> included
    test "a daily-normalized spread below the daily-scaled min_delta is excluded" do
      comparison = %{
        "BELOW" => daily_entry("0.002"),
        "ABOVE" => daily_entry("0.004")
      }

      symbols =
        comparison
        |> Funding.find_arbitrage_opportunities(Decimal.new("0.001"))
        |> Enum.map(& &1.symbol)

      assert "ABOVE" in symbols

      refute "BELOW" in symbols,
             "0.002 daily spread must not pass a 0.001 raw min_delta scaled to daily (0.003)"
    end

    # A :daily_normalized entry with delta tagged daily and flagged as an
    # arbitrage opportunity. Shape mirrors compare_funding_venues output.
    defp daily_entry(delta) do
      %{
        delta: Decimal.new(delta),
        delta_unit: :daily_normalized,
        arbitrage_opportunity: true,
        min_exchange: "venue_a",
        max_exchange: "venue_b"
      }
    end
  end

  describe "no baked-in venue constants in generic math (task 41)" do
    # Invariant: generic margin/liquidation math carries no venue-specific
    # constant that cannot be overridden by the caller. Funding cadence is a
    # caller-supplied :value param; the same call with a non-8h cadence must
    # produce a different result (proving the default is a convention, not a
    # hardcode).
    #
    # Hand calc: doubling periods_per_day doubles daily funding cost.
    #   3 periods: 0.0001 * 10_000 * 3 = 3.0
    #   24 periods: 0.0001 * 10_000 * 24 = 24.0
    test "funding cadence flows through as a caller param, not a fixed 8h default" do
      base = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 3)
      hourly = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 24)

      assert_close(base, Decimal.new("3.0"))
      assert_close(hourly, Decimal.new("24.0"))

      three_period =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00005"),
          Decimal.new("0.30"),
          periods_per_day: 3,
          daily_funding_threshold: Decimal.new("-0.0002")
        )

      twenty_four_period =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00005"),
          Decimal.new("0.30"),
          periods_per_day: 24,
          daily_funding_threshold: Decimal.new("-0.0002")
        )

      refute three_period.kill_switch_triggered
      assert twenty_four_period.kill_switch_triggered
    end

    # Independent setup: the single DCA step produces cumulative notional 1,950.
    # A caller tier beginning at 1,900 therefore applies its 0.02 MMR, while the
    # flat call uses 0.005. A higher long MMR produces a higher liquidation price.
    test "Calc.dca_ladder accepts a caller-supplied MMR tier schedule" do
      position = %{notional: Decimal.new(1500), eff_lev: Decimal.new("1.5")}
      ladder = [{Decimal.new("0.95"), Decimal.new("0.3")}]

      flat =
        Calc.dca_ladder(
          position,
          Decimal.new(500),
          Decimal.new(3000),
          Decimal.new(3),
          ladder,
          :long,
          Decimal.new("0.005")
        )

      tiered =
        Calc.dca_ladder(
          position,
          Decimal.new(500),
          Decimal.new(3000),
          Decimal.new(3),
          ladder,
          :long,
          Decimal.new("0.005"),
          mmr_schedule: [{Decimal.new(1900), Decimal.new("0.02")}]
        )

      assert_close(tiered.final_notional, Decimal.new("1950"))
      assert Decimal.compare(tiered.final_liq, flat.final_liq) == :gt
    end
  end

  describe "golden values are independently sourced (task 45)" do
    # Invariant: the highest-risk domain formulas (liquidation, sizing, DCA,
    # fees, funding) have at least one fixture whose expected value was computed
    # OUTSIDE the code under test — hand-computed, from a spec, or an external
    # reference — and compared as Decimals with explicit tolerances. A fixture
    # derived from the same formula proves consistency, not correctness.
    #
    # Companion fixtures for sizing / DCA / fees / funding live in the per-module
    # golden tests (calc_test, position_calculator_test, dca_planner_test,
    # fees_test, funding_test). This file pins the cross-cutting liquidation and
    # funding cost cases that ratify domain units, not implementation identity.
    #
    # Provenance: hand calc from the public Hedging.calculate_funding_cost/3
    # contract. Funding cost over N days =
    #   position * rate * periods_per_day * days.
    #   10_000 * 0.0001 * 3 * 5 = 15.0
    test "funding cost matches a hand-computed fixture (provenance: dimensional)" do
      daily = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 3)
      five_day = Decimal.mult(daily, Decimal.new(5))
      assert_close(five_day, Decimal.new("15.0"))
    end

    # Provenance: hand calc from the venue-equivalent reduced form of
    # Calc.liquidation/4 (Hyperliquid cross / Binance isolated one-way).
    # For a long: liq = entry × (1 − 1/L_eff) / (1 − mmr).
    # Hand calc, entry=3000, L_eff=2, mmr=0.005:
    #   1 − 1/2 = 0.5
    #   1 − mmr = 0.995
    #   3000 × 0.5 / 0.995 = 1_500_000/995 = 1507.53768844…
    # Expected literal is written here; it does not call Calc.liquidation or
    # reuse its internal constants beyond the public input contract.
    test "liquidation price matches an independently-sourced fixture" do
      actual =
        DeltaCalc.Calc.liquidation(
          Decimal.new(3000),
          Decimal.new(2),
          Decimal.new("0.005"),
          :long
        )

      assert_close(actual, Decimal.new("1507.53768844"), "0.00000001")
    end
  end

  describe "accrued funding is signed, negative when paid (audit 2a5d590)" do
    # Invariant: every `:accrued_funding` / accrued-funding :value input across
    # the surface is SIGNED net funding in quote currency — negative when paid,
    # positive when received — the convention `Fees.funding_adjusted_breakeven/3`
    # documents. No module may reinterpret the magnitude as a cost and subtract
    # it, because the sign is the only thing distinguishing "the long paid 15"
    # from "the long was paid 15", and both are ordinary states of a perp.
    #
    # Asserted by direction and by the gap between the two signs, not against a
    # formula output: flipping the sign of F must move net PnL by exactly 2F and
    # must move it the right way.
    @funding Decimal.new("15")

    # Hand calc (entry 50_000, exit 52_000, size 2, long, open 0.0004, close 0.0002):
    #   gross      = (52_000 - 50_000) * 2 = 4000
    #   open fee   = 50_000 * 2 * 0.0004   =   40
    #   close fee  = 52_000 * 2 * 0.0002   =   20.8
    #   net, F = 0                         = 3939.2
    #   received (+15) = 3954.2   paid (-15) = 3924.2   gap = 2 * 15 = 30
    test "realized PnL adds signed funding, so received beats paid by 2F" do
      params = %{
        entry_price: Decimal.new("50000"),
        exit_price: Decimal.new("52000"),
        size: Decimal.new("2"),
        side: :long,
        open_fee_rate: Decimal.new("0.0004"),
        close_fee_rate: Decimal.new("0.0002")
      }

      received = Pnl.realized_pnl(Map.put(params, :accrued_funding, @funding))
      paid = Pnl.realized_pnl(Map.put(params, :accrued_funding, Decimal.negate(@funding)))

      assert Decimal.compare(received, paid) == :gt
      assert_close(Decimal.sub(received, paid), Decimal.mult(@funding, Decimal.new(2)))
      assert_close(received, Decimal.new("3954.2"))
    end

    # Dimensional truth, no formula involved: funding the long PAID must be
    # earned back, so it raises the breakeven exit price; funding RECEIVED is a
    # credit, so it lowers it. A subtracted-magnitude bug inverts both.
    test "paying funding raises a long breakeven, receiving it lowers it" do
      params = %{
        entry_price: Decimal.new("50000"),
        size: Decimal.new("2"),
        open_fee_rate: Decimal.new("0.0004"),
        close_fee_rate: Decimal.new("0.0002"),
        side: :long
      }

      neutral = Pnl.breakeven(params)
      received = Pnl.breakeven(Map.put(params, :accrued_funding, @funding))
      paid = Pnl.breakeven(Map.put(params, :accrued_funding, Decimal.negate(@funding)))

      assert Decimal.compare(received, neutral) == :lt
      assert Decimal.compare(paid, neutral) == :gt

      # The two legs are symmetric around neutral, and the gap is fixed by the
      # documented two-leg fee model (close fees apply to the breakeven exit
      # notional), not by the breakeven formula's internals. Hand calc:
      #   gap = 2F / size / (1 - close_fee_rate) = 30 / 2 / 0.9998
      #       = 15 / 0.9998 = 15.0030006001200240048...
      assert_close(
        Decimal.sub(paid, received),
        Decimal.new("15.0030006001200240048"),
        "0.0000000001"
      )
    end

    # The Pnl facade must not reinterpret the sign on its way to Fees: the same
    # inputs through either entry point give the same price.
    test "Pnl.breakeven and Fees.funding_adjusted_breakeven agree on the sign" do
      fee_params = %{
        size: Decimal.new("2"),
        open_fee_rate: Decimal.new("0.0004"),
        close_fee_rate: Decimal.new("0.0002"),
        side: :long
      }

      paid = Decimal.negate(@funding)

      via_fees = Fees.funding_adjusted_breakeven(Decimal.new("50000"), fee_params, paid)

      via_pnl =
        Pnl.breakeven(
          fee_params
          |> Map.put(:entry_price, Decimal.new("50000"))
          |> Map.put(:accrued_funding, paid)
        )

      assert_close(via_pnl, via_fees)
    end
  end
end
