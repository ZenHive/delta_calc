defmodule DeltaCalc.MarginBridgeTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.MarginBridge

  describe "margin_ratio/3" do
    test "matches phase7 example: 6000 + 2700 over 60000 capital" do
      ratio =
        MarginBridge.margin_ratio(
          Decimal.new("6000"),
          Decimal.new("2700"),
          Decimal.new("60000")
        )

      assert Decimal.equal?(ratio, Decimal.new("0.145"))
    end

    test "returns zero when capital is zero" do
      assert Decimal.equal?(
               MarginBridge.margin_ratio(
                 Decimal.new("6000"),
                 Decimal.new("2700"),
                 Decimal.new("0")
               ),
               Decimal.new("0")
             )
    end

    test "returns zero when capital is negative" do
      assert Decimal.equal?(
               MarginBridge.margin_ratio(
                 Decimal.new("1000"),
                 Decimal.new("500"),
                 Decimal.new("-100")
               ),
               Decimal.new("0")
             )
    end

    test "option premium only when initial margin is zero" do
      ratio =
        MarginBridge.margin_ratio(Decimal.new("0"), Decimal.new("2700"), Decimal.new("60000"))

      assert Decimal.equal?(ratio, Decimal.new("0.045"))
    end

    test "accepts string and integer inputs" do
      ratio = MarginBridge.margin_ratio("6000", 2700, "60000")
      assert Decimal.equal?(ratio, Decimal.new("0.145"))
    end
  end

  describe "margin_runway_days/2" do
    test "available margin divided by daily burn" do
      runway =
        MarginBridge.margin_runway_days(
          Decimal.new("2025"),
          Decimal.new("45")
        )

      assert Decimal.equal?(runway, Decimal.new("45"))
    end

    test "returns nil when daily burn is zero" do
      assert MarginBridge.margin_runway_days(Decimal.new("1000"), Decimal.new("0")) == nil
    end

    test "returns nil when daily burn is negative" do
      assert MarginBridge.margin_runway_days(Decimal.new("1000"), Decimal.new("-10")) == nil
    end
  end

  describe "payback_timeline/2" do
    test "projects days from remaining debt and daily funding" do
      timeline =
        MarginBridge.payback_timeline(
          Decimal.new("2430"),
          Decimal.new("90")
        )

      assert Decimal.equal?(timeline.remaining_debt, Decimal.new("2430"))
      assert Decimal.equal?(timeline.daily_funding, Decimal.new("90"))
      assert Decimal.equal?(timeline.days_to_payoff, Decimal.new("27"))
      assert timeline.projected_payoff_date == nil
    end

    test "includes projected payoff date when from_date is supplied" do
      from = ~D[2025-01-14]

      timeline =
        MarginBridge.payback_timeline(
          Decimal.new("2430"),
          Decimal.new("90"),
          from_date: from
        )

      assert timeline.projected_payoff_date == ~D[2025-02-10]
    end

    test "returns nil days when daily funding is zero" do
      timeline =
        MarginBridge.payback_timeline(
          Decimal.new("2700"),
          Decimal.new("0")
        )

      assert timeline.days_to_payoff == nil
      assert timeline.projected_payoff_date == nil
    end

    test "returns nil projected date when payoff days are nil even with from_date" do
      timeline =
        MarginBridge.payback_timeline(
          Decimal.new("2700"),
          Decimal.new("0"),
          from_date: ~D[2025-01-14]
        )

      assert timeline.projected_payoff_date == nil
    end

    test "accepts numeric inputs via Decimal coercion" do
      timeline = MarginBridge.payback_timeline(2700, 90.0, from_date: ~D[2025-01-01])

      assert Decimal.equal?(timeline.remaining_debt, Decimal.new("2700"))
      assert Decimal.equal?(timeline.daily_funding, Decimal.new("90.0"))
      assert timeline.projected_payoff_date == ~D[2025-01-31]
    end

    test "full payback at 90/day matches phase7 high-funding scenario (~30 days)" do
      timeline =
        MarginBridge.payback_timeline(
          Decimal.new("2700"),
          Decimal.new("90")
        )

      assert Decimal.equal?(timeline.days_to_payoff, Decimal.new("30"))
    end
  end

  describe "stress_test_prolonged_negative/3" do
    # Rates are decimal fractions (e.g. -0.00025 = -0.025%), matching Funding/Hedging.
    test "matches phase7 prolonged negative example at -0.025% for 90 days" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90
        )

      assert Decimal.equal?(result.daily_cost, Decimal.new("45"))
      assert Decimal.equal?(result.total_cost, Decimal.new("4050"))
      assert result.duration_days == 90
    end

    test "matches -0.02% daily cost of 36 on 60k position" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.0002"),
          Decimal.new("60000"),
          30
        )

      assert Decimal.equal?(result.daily_cost, Decimal.new("36"))
      assert Decimal.equal?(result.total_cost, Decimal.new("1080"))
    end

    test "matches -0.03% daily cost of 54 on 60k position" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.0003"),
          Decimal.new("60000"),
          90
        )

      assert Decimal.equal?(result.daily_cost, Decimal.new("54"))
      assert Decimal.equal?(result.total_cost, Decimal.new("4860"))
    end

    test "computes kill_switch_day when capital and initial margin ratio supplied" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90,
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.15")
        )

      assert result.kill_switch_day == 134
    end

    test "kill_switch_day is nil without optional margin context" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90
        )

      assert result.kill_switch_day == nil
    end

    test "kill_switch_day is nil when already above kill-switch margin threshold" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90,
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.30")
        )

      assert result.kill_switch_day == nil
    end

    test "default periods_per_day is 3 (8h funding cadence)" do
      default =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          1
        )

      explicit =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          1,
          periods_per_day: 3
        )

      assert Decimal.equal?(default.daily_cost, explicit.daily_cost)
      assert Decimal.equal?(default.daily_cost, Decimal.new("45"))
    end

    test "Deribit hourly cadence (24 periods/day) scales daily cost 8x vs 8h default" do
      result =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90,
          periods_per_day: 24
        )

      assert Decimal.equal?(result.daily_cost, Decimal.new("360"))
      assert Decimal.equal?(result.total_cost, Decimal.new("32400"))
    end

    test "kill_switch_day shrinks with higher Deribit funding frequency" do
      eight_hour =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90,
          periods_per_day: 3,
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.15")
        )

      deribit =
        MarginBridge.stress_test_prolonged_negative(
          Decimal.new("-0.00025"),
          Decimal.new("60000"),
          90,
          periods_per_day: 24,
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.15")
        )

      assert eight_hour.kill_switch_day == 134
      assert deribit.kill_switch_day == 17
    end
  end

  describe "check_kill_switch/2" do
    test "triggers when avg funding below -0.02% and margin above 25%" do
      result =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00022"),
          Decimal.new("0.26")
        )

      assert result.kill_switch_triggered
      assert Decimal.equal?(result.avg_funding_24h, Decimal.new("-0.00022"))
      assert Decimal.equal?(result.margin_ratio, Decimal.new("0.26"))
      assert Decimal.equal?(result.funding_threshold, Decimal.new("-0.0002"))
      assert Decimal.equal?(result.margin_threshold, Decimal.new("0.25"))
    end

    test "does not trigger when margin is at or below 25%" do
      result =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00022"),
          Decimal.new("0.25")
        )

      refute result.kill_switch_triggered
    end

    test "does not trigger when funding is above threshold even with high margin" do
      result =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00015"),
          Decimal.new("0.30")
        )

      refute result.kill_switch_triggered
    end

    test "does not trigger under healthy conditions" do
      result =
        MarginBridge.check_kill_switch(
          Decimal.new("0.00015"),
          Decimal.new("0.145")
        )

      refute result.kill_switch_triggered
    end

    test "respects custom funding threshold" do
      result =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00015"),
          Decimal.new("0.30"),
          funding_threshold: Decimal.new("-0.0002")
        )

      refute result.kill_switch_triggered

      strict =
        MarginBridge.check_kill_switch(
          Decimal.new("-0.00015"),
          Decimal.new("0.30"),
          funding_threshold: Decimal.new("-0.0001")
        )

      assert strict.kill_switch_triggered
    end
  end

  describe "api() hints" do
    test "every public function has Descripex hints" do
      for entry <- MarginBridge.__api__() do
        assert function_exported?(MarginBridge, entry.name, entry.arity)
        assert entry.hints.description != ""
      end
    end
  end
end
