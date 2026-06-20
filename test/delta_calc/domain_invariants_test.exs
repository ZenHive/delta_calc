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

  alias DeltaCalc.Funding
  alias DeltaCalc.Hedging
  alias DeltaCalc.MarginBridge

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
    @tag :domain_pending
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
    @tag :domain_pending
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
    #   24 periods (Deribit hourly): 0.0001 * 10_000 * 24 = 24.0
    test "funding cadence flows through as a caller param, not a fixed 8h default" do
      base = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 3)
      hourly = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 24)

      assert_close(base, Decimal.new("3.0"))
      assert_close(hourly, Decimal.new("24.0"))
    end

    # TODO(Task 41): once Calc.dca_ladder accepts a caller-supplied MMR tier
    # schedule, assert a NON-default schedule changes the liquidation result.
    # Tag :domain_pending until the tier schedule is a :value param.
    @tag :domain_pending
    test "Calc.dca_ladder accepts a caller-supplied MMR tier schedule" do
      flunk("""
      TODO(Task 41): wire this once dca_ladder/_ exposes a tier-schedule param.
      Construct two ladders differing only in the MMR tier schedule and assert
      the liquidation prices differ — proving the 50k/250k/1M ladder is not
      hardcoded into the generic engine.
      """)
    end
  end

  describe "golden values are independently sourced (task 45)" do
    # Invariant: the highest-risk domain formulas (liquidation, sizing, DCA,
    # fees, funding) have at least one fixture whose expected value was computed
    # OUTSIDE the code under test — hand-computed, from a spec, or an external
    # reference — and compared as Decimals with explicit tolerances. A fixture
    # derived from the same formula proves consistency, not correctness.
    #
    # Provenance: hand-computed. Funding cost over N days =
    #   position * rate * periods_per_day * days.
    #   10_000 * 0.0001 * 3 * 5 = 15.0
    test "funding cost matches a hand-computed fixture (provenance: dimensional)" do
      daily = Hedging.calculate_funding_cost(Decimal.new("10000"), Decimal.new("0.0001"), 3)
      five_day = Decimal.mult(daily, Decimal.new(5))
      assert_close(five_day, Decimal.new("15.0"))
    end

    # TODO(Task 45): add independently-sourced fixtures for liquidation price
    # and position sizing. Each must document its provenance (hand-computed
    # worked example or external reference) and compare Decimals with a stated
    # tolerance — never to_float. Tag :domain_pending until the fixtures exist.
    @tag :domain_pending
    test "liquidation price matches an independently-sourced fixture" do
      flunk("""
      TODO(Task 45): add a liquidation-price fixture from a hand-worked example
      or venue spec (NOT recomputed from Calc's own formula), with documented
      provenance and a Decimal tolerance.
      """)
    end
  end
end
