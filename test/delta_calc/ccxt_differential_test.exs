defmodule DeltaCalc.CcxtDifferentialTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Calc
  alias DeltaCalc.Funding
  alias DeltaCalc.Hedging
  alias DeltaCalc.MarginBridge
  alias DeltaCalc.OptionsRisk
  alias DeltaCalc.PortfolioMargin

  @fixtures_path Path.expand("../support/ccxt_fixtures/funding_and_liquidation.json", __DIR__)
  @hours_per_day Decimal.new(24)
  @days_per_year Decimal.new(365)
  @hundred Decimal.new(100)

  describe "recorded ccxt funding specs" do
    test "fixtures cover venues with different funding intervals" do
      intervals =
        @fixtures_path
        |> load_fixture!()
        |> Map.fetch!("funding")
        |> Enum.map(&decimal_at!(&1, "interval_hours"))
        |> Enum.uniq_by(&Decimal.to_string(&1, :normal))

      assert length(intervals) >= 2
      assert Enum.any?(intervals, &Decimal.equal?(&1, Decimal.new(8)))
      assert Enum.any?(intervals, &Decimal.equal?(&1, Decimal.new(1)))
    end

    test "daily and annual funding cost use the recorded venue interval" do
      fixture = load_fixture!(@fixtures_path)

      for row <- Map.fetch!(fixture, "funding") do
        periods_per_day = periods_per_day(row)
        notional = decimal_at!(row, "notional")
        rate = decimal_at!(row, "funding_rate")

        daily_cost =
          Hedging.calculate_funding_cost(notional, rate, Decimal.to_integer(periods_per_day))

        annual_cost = Decimal.mult(daily_cost, @days_per_year)

        assert_decimal_close(
          daily_cost,
          decimal_at!(row, "venue_daily_funding_cost"),
          "daily cost"
        )

        assert_decimal_close(
          annual_cost,
          decimal_at!(row, "venue_annual_funding_cost"),
          "annual cost"
        )

        assert {:ok, apr} =
                 Funding.funding_apr(
                   rate,
                   row |> decimal_at!("interval_hours") |> Decimal.to_integer()
                 )

        assert_decimal_close(
          apr.daily,
          decimal_at!(row, "venue_daily_rate_pct"),
          "daily rate pct"
        )

        assert_decimal_close(
          apr.annual,
          decimal_at!(row, "venue_annual_rate_pct"),
          "annual rate pct"
        )
      end
    end

    test "hourly fixture fails the old implicit 8h cadence for stress modules" do
      row = funding_row!("hyperliquid", "BTC/USDC:USDC")
      periods_per_day = row |> periods_per_day() |> Decimal.to_integer()
      notional = decimal_at!(row, "notional")
      rate_pct = row |> decimal_at!("funding_rate") |> Decimal.mult(@hundred)
      expected_daily_cost = row |> decimal_at!("venue_daily_funding_cost") |> Decimal.abs()

      margin_bridge =
        MarginBridge.stress_test_prolonged_negative(
          rate_pct,
          notional,
          1,
          periods_per_day: periods_per_day
        )

      options_risk =
        OptionsRisk.calculate_negative_funding_impact(%{
          negative_rate: rate_pct,
          position_size: notional,
          periods_per_day: periods_per_day
        })

      assert_decimal_close(
        margin_bridge.daily_cost,
        expected_daily_cost,
        "margin bridge daily cost"
      )

      assert_decimal_close(
        options_risk.daily_cost,
        expected_daily_cost,
        "options risk daily cost"
      )

      old_implicit_8h =
        MarginBridge.stress_test_prolonged_negative(rate_pct, notional, 1, periods_per_day: 3)

      refute Decimal.equal?(old_implicit_8h.daily_cost, expected_daily_cost)
    end
  end

  describe "recorded ccxt liquidation spec" do
    test "portfolio-margin liquidation reproduces the venue liquidation price" do
      row = load_fixture!(@fixtures_path) |> Map.fetch!("liquidation")
      account = account_from_liquidation(row)

      liquidation_price = PortfolioMargin.portfolio_liquidation_price(account)

      assert_decimal_close(
        liquidation_price,
        decimal_at!(row, "venue_liquidation_price"),
        "portfolio liquidation",
        Decimal.new("0.01")
      )
    end

    test "Calc.liquidation approximation stays within the documented loose bound" do
      row = load_fixture!(@fixtures_path) |> Map.fetch!("liquidation")
      position = Map.fetch!(row, "position")
      venue_liquidation = decimal_at!(row, "venue_liquidation_price")

      notional =
        Decimal.mult(decimal_at!(position, "contracts"), decimal_at!(position, "mark_price"))

      effective_leverage = Decimal.div(notional, decimal_at!(row, "equity"))

      approximate =
        Calc.liquidation(
          decimal_at!(position, "entry_price"),
          effective_leverage,
          decimal_at!(row, "maintenance_margin_rate"),
          position |> Map.fetch!("side") |> String.to_atom()
        )

      error_pct =
        approximate
        |> Decimal.sub(venue_liquidation)
        |> Decimal.abs()
        |> Decimal.div(venue_liquidation)
        |> Decimal.mult(@hundred)

      assert_decimal_close(
        error_pct,
        decimal_at!(row, "calc_approximation_error_pct"),
        "calc error pct"
      )

      assert Decimal.compare(error_pct, decimal_at!(row, "calc_approximation_error_bound_pct")) !=
               :gt,
             "Calc.liquidation/4 is documented as an exchange-specific approximation"
    end
  end

  defp load_fixture!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  defp funding_row!(venue, symbol) do
    @fixtures_path
    |> load_fixture!()
    |> Map.fetch!("funding")
    |> Enum.find(fn row ->
      Map.fetch!(row, "venue") == venue and Map.fetch!(row, "symbol") == symbol
    end)
  end

  defp periods_per_day(row) do
    Decimal.div(@hours_per_day, decimal_at!(row, "interval_hours"))
  end

  defp account_from_liquidation(row) do
    position = Map.fetch!(row, "position")

    %{
      equity: decimal_at!(row, "equity"),
      positions: [
        %{
          side: position |> Map.fetch!("side") |> String.to_atom(),
          quantity: decimal_at!(position, "contracts"),
          mark_price: decimal_at!(position, "mark_price"),
          mmr: decimal_at!(row, "maintenance_margin_rate")
        }
      ]
    }
  end

  defp decimal_at!(map, key) do
    map
    |> Map.fetch!(key)
    |> Decimal.new()
  end

  defp assert_decimal_close(actual, expected, label, tolerance \\ Decimal.new("0.00000001")) do
    diff =
      actual
      |> Decimal.sub(expected)
      |> Decimal.abs()

    assert Decimal.compare(diff, tolerance) != :gt,
           "#{label}: expected #{Decimal.to_string(actual)} within #{Decimal.to_string(tolerance)} of #{Decimal.to_string(expected)}"
  end
end
