defmodule DeltaCalc.OptionsRiskTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.OptionsRisk

  describe "max_loss/1" do
    test "frames long-option risk as premium-only max loss" do
      result = OptionsRisk.max_loss(Decimal.new("2700"))

      assert Decimal.equal?(result.max_loss, Decimal.new("2700"))
      assert result.risk_model == :premium_only
      assert result.limited_downside
    end

    test "sums multiple long-option premiums" do
      result = OptionsRisk.max_loss([800, 700, 500])

      assert Decimal.equal?(result.max_loss, Decimal.new("2000"))
    end

    test "accepts string and float premiums" do
      result = OptionsRisk.max_loss(["260", 100.0])

      assert Decimal.equal?(result.max_loss, Decimal.new("360.0"))
    end

    test "empty premium list yields zero max loss" do
      result = OptionsRisk.max_loss([])

      assert Decimal.equal?(result.max_loss, Decimal.new("0"))
      assert result.limited_downside
    end
  end

  describe "calculate_total_exposure/1" do
    test "sums absolute spot, perp, options, and margin debt" do
      result =
        OptionsRisk.calculate_total_exposure(%{
          spot_notional: Decimal.new("60000"),
          perp_notional: Decimal.new("-60000"),
          options_notional: Decimal.new("2700"),
          margin_debt: Decimal.new("1800")
        })

      assert Decimal.equal?(result.spot_notional, Decimal.new("60000"))
      assert Decimal.equal?(result.perp_notional, Decimal.new("60000"))
      assert Decimal.equal?(result.options_notional, Decimal.new("2700"))
      assert Decimal.equal?(result.margin_debt, Decimal.new("1800"))
      assert Decimal.equal?(result.total_exposure, Decimal.new("124500"))
    end

    test "treats negative margin debt as positive exposure" do
      result =
        OptionsRisk.calculate_total_exposure(%{
          spot_notional: 1000,
          perp_notional: -500,
          options_notional: 100,
          margin_debt: -50
        })

      assert Decimal.equal?(result.total_exposure, Decimal.new("1650"))
    end
  end

  describe "calculate_negative_funding_impact/1" do
    test "matches phase7 post-crash example at -0.03% on 60k" do
      result =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: Decimal.new("-0.03"),
          position_size: Decimal.new("60000"),
          market_context: :post_crash,
          capital_protected: true
        })

      assert Decimal.equal?(result.daily_cost, Decimal.new("54"))
      refute result.capital_at_risk
      assert result.cash_flow_risk
      assert result.market_setup == :bullish
      assert result.opportunity == :high
    end

    test "defaults to capital protected with neutral market context" do
      result =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: Decimal.new("-0.02"),
          position_size: Decimal.new("60000")
        })

      assert Decimal.equal?(result.daily_cost, Decimal.new("36"))
      refute result.capital_at_risk
      assert result.cash_flow_risk
      assert result.market_setup == :neutral
      assert result.opportunity == :moderate
    end

    test "marks capital at risk when not delta neutral" do
      result =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: Decimal.new("-0.02"),
          position_size: Decimal.new("60000"),
          capital_protected: false
        })

      assert result.capital_at_risk
    end

    test "bull market context maps to bearish setup and low opportunity" do
      result =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: Decimal.new("-0.02"),
          position_size: Decimal.new("60000"),
          market_context: :bull_market
        })

      assert result.market_setup == :bearish
      assert result.opportunity == :low
    end

    test "bear market and negative funding contexts map to bullish setup" do
      for context <- [:bear_market, :negative_funding] do
        result =
          OptionsRisk.calculate_negative_funding_impact(%{
            negative_rate: Decimal.new("-0.02"),
            position_size: Decimal.new("60000"),
            market_context: context
          })

        assert result.market_setup == :bullish
        assert result.opportunity == :high
      end
    end

    test "zero funding rate yields no cash-flow risk" do
      result =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: Decimal.new("0"),
          position_size: Decimal.new("60000")
        })

      assert Decimal.equal?(result.daily_cost, Decimal.new("0"))
      refute result.cash_flow_risk
    end
  end

  describe "stress_test_extended_negative/2" do
    test "matches phase7 bear_market_90d scenario table" do
      result =
        OptionsRisk.stress_test_extended_negative(
          %{
            scenario: :bear_market_90d,
            funding_rates: [Decimal.new("-0.02"), Decimal.new("-0.025"), Decimal.new("-0.03")],
            position_size: Decimal.new("60000")
          },
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.145")
        )

      assert result.scenario == :bear_market_90d
      assert [_low, _mid, _high] = result.scenarios

      [low, mid, high] = result.scenarios

      assert Decimal.equal?(low.rate, Decimal.new("-0.02"))
      assert Decimal.equal?(low.daily, Decimal.new("36"))
      assert Decimal.equal?(low.total_90d, Decimal.new("3240"))
      assert low.margin_impact == "+7%"

      assert Decimal.equal?(mid.rate, Decimal.new("-0.025"))
      assert Decimal.equal?(mid.daily, Decimal.new("45"))
      assert Decimal.equal?(mid.total_90d, Decimal.new("4050"))
      assert mid.margin_impact == "+9%"

      assert Decimal.equal?(high.rate, Decimal.new("-0.03"))
      assert Decimal.equal?(high.daily, Decimal.new("54"))
      assert Decimal.equal?(high.total_90d, Decimal.new("4860"))
      assert high.margin_impact == "+11%"

      assert result.kill_switch_trigger == "Day 117-175 depending on rate"
      assert result.recommendation =~ "cash buffer"
    end

    test "defaults scenario atom and capital to position size" do
      result =
        OptionsRisk.stress_test_extended_negative(%{
          funding_rates: [Decimal.new("-0.02")],
          position_size: Decimal.new("60000")
        })

      assert result.scenario == :bear_market_90d
      assert hd(result.scenarios).margin_impact == "+7%"
      assert result.kill_switch_trigger == "Not projected at current margin levels"
    end

    test "respects custom duration days" do
      result =
        OptionsRisk.stress_test_extended_negative(
          %{
            funding_rates: [Decimal.new("-0.02")],
            position_size: Decimal.new("60000")
          },
          duration_days: 30
        )

      scenario = hd(result.scenarios)
      assert Decimal.equal?(scenario.total_90d, Decimal.new("1080"))
    end

    test "single kill-switch day is formatted without a range" do
      result =
        OptionsRisk.stress_test_extended_negative(
          %{
            funding_rates: [Decimal.new("-0.025")],
            position_size: Decimal.new("60000")
          },
          capital: Decimal.new("60000"),
          initial_margin_ratio: Decimal.new("0.15")
        )

      assert result.kill_switch_trigger == "Day 134"
    end

    test "uses fallback denominator when margin threshold consumes all headroom" do
      result =
        OptionsRisk.stress_test_extended_negative(
          %{
            funding_rates: [Decimal.new("-0.02")],
            position_size: Decimal.new("60000")
          },
          capital: Decimal.new("60000"),
          margin_threshold: Decimal.new("1")
        )

      assert hd(result.scenarios).margin_impact == "+7%"
    end

    test "zero capital uses neutral margin impact denominator" do
      result =
        OptionsRisk.stress_test_extended_negative(
          %{
            funding_rates: [Decimal.new("-0.02")],
            position_size: Decimal.new("60000")
          },
          capital: Decimal.new("0"),
          margin_threshold: Decimal.new("1")
        )

      assert hd(result.scenarios).margin_impact == "+324000%"
    end
  end

  describe "monitor_margin_bridge_health/2" do
    test "matches phase7 healthy margin-bridge example" do
      result =
        OptionsRisk.monitor_margin_bridge_health(%{
          initial_margin: Decimal.new("6000"),
          option_premium: Decimal.new("2700"),
          capital: Decimal.new("60000"),
          available_margin: Decimal.new("2025"),
          daily_burn: Decimal.new("45")
        })

      assert Decimal.equal?(result.margin_ratio, Decimal.new("0.145"))
      assert Decimal.equal?(result.runway_days, Decimal.new("45"))
      assert result.health_status == :healthy
    end

    test "warning status between default warning and reduce thresholds" do
      result =
        OptionsRisk.monitor_margin_bridge_health(%{
          initial_margin: Decimal.new("9500"),
          option_premium: Decimal.new("6000"),
          capital: Decimal.new("60000"),
          available_margin: Decimal.new("1000"),
          daily_burn: Decimal.new("10")
        })

      assert result.health_status == :warning
    end

    test "critical status above reduce threshold" do
      result =
        OptionsRisk.monitor_margin_bridge_health(%{
          initial_margin: Decimal.new("13000"),
          option_premium: Decimal.new("9000"),
          capital: Decimal.new("60000"),
          available_margin: Decimal.new("500"),
          daily_burn: Decimal.new("10")
        })

      assert result.health_status == :critical
    end

    test "runway is nil when daily burn is non-positive" do
      result =
        OptionsRisk.monitor_margin_bridge_health(%{
          initial_margin: Decimal.new("6000"),
          option_premium: Decimal.new("2700"),
          capital: Decimal.new("60000"),
          available_margin: Decimal.new("2025"),
          daily_burn: Decimal.new("0")
        })

      assert result.runway_days == nil
    end

    test "respects custom threshold opts" do
      result =
        OptionsRisk.monitor_margin_bridge_health(
          %{
            initial_margin: Decimal.new("6000"),
            option_premium: Decimal.new("2700"),
            capital: Decimal.new("60000"),
            available_margin: Decimal.new("2025"),
            daily_burn: Decimal.new("45")
          },
          warning: Decimal.new("0.10"),
          reduce: Decimal.new("0.20")
        )

      assert result.health_status == :warning
    end
  end

  describe "api() hints" do
    test "every public function has Descripex hints" do
      for entry <- OptionsRisk.__api__() do
        assert function_exported?(OptionsRisk, entry.name, entry.arity)
        assert entry.hints.description != ""
      end
    end
  end
end
