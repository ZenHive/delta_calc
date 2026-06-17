defmodule DeltaCalc.FundingTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Funding

  describe "funding_apr/2" do
    test "annualises an 8-hour funding rate" do
      assert {:ok, apr} = Funding.funding_apr(Decimal.new("0.0001"), 8)

      assert Decimal.equal?(apr.hourly, Decimal.new("0.0013"))
      assert Decimal.equal?(apr.daily, Decimal.new("0.03"))
      assert Decimal.equal?(apr.annual, Decimal.new("10.95"))
    end

    test "handles negative funding rates" do
      assert {:ok, apr} = Funding.funding_apr(Decimal.new("-0.0002"), 8)

      assert Decimal.compare(apr.hourly, Decimal.new(0)) == :lt
      assert Decimal.compare(apr.daily, Decimal.new(0)) == :lt
      assert Decimal.compare(apr.annual, Decimal.new(0)) == :lt
    end

    test "supports non-default funding intervals" do
      assert {:ok, apr} = Funding.funding_apr(Decimal.new("0.0001"), 4)

      assert Decimal.equal?(apr.daily, Decimal.new("0.06"))
      assert Decimal.equal?(apr.annual, Decimal.new("21.90"))
    end

    test "accepts numeric and string rate inputs" do
      assert {:ok, float_apr} = Funding.funding_apr(0.0001, 8)
      assert {:ok, int_apr} = Funding.funding_apr(1, 8)
      assert {:ok, string_apr} = Funding.funding_apr("0.0001", 8)

      assert Decimal.equal?(float_apr.annual, string_apr.annual)
      assert Decimal.compare(int_apr.annual, Decimal.new(0)) == :gt
    end

    test "uses default 8-hour period" do
      assert {:ok, explicit} = Funding.funding_apr(Decimal.new("0.0001"), 8)
      assert {:ok, default} = Funding.funding_apr(Decimal.new("0.0001"))
      assert Decimal.equal?(explicit.annual, default.annual)
    end

    test "returns error for invalid rate" do
      assert {:error, :invalid_rate} = Funding.funding_apr("not-a-rate", 8)
      assert {:error, :invalid_rate} = Funding.funding_apr(:invalid, 8)
      assert {:error, :invalid_rate} = Funding.funding_apr(Decimal.new("0.0001"), 0)
    end
  end

  describe "compare_funding_rates/1" do
    test "ranks venues and flags arbitrage for a single symbol" do
      result =
        Funding.compare_funding_rates(%{
          binance: Decimal.new("0.003"),
          bybit: Decimal.new("0.001")
        })

      assert result.arbitrage_opportunity == true
      assert result.max_exchange == :binance
      assert result.min_exchange == :bybit
      assert Decimal.equal?(result.delta, Decimal.new("0.002"))
      assert Decimal.equal?(result.annual_apr_delta, Decimal.new("219.00"))

      assert result.ranked == [
               {:binance, Decimal.new("0.003")},
               {:bybit, Decimal.new("0.001")}
             ]
    end

    test "returns insufficient_data for a single venue" do
      result = Funding.compare_funding_rates(%{binance: Decimal.new("0.001")})

      assert result.insufficient_data == true
      assert result.arbitrage_opportunity == false
      assert result.ranked == [{:binance, Decimal.new("0.001")}]
    end

    test "does not flag arbitrage when spread is below threshold" do
      result =
        Funding.compare_funding_rates(%{
          binance: Decimal.new("0.0001"),
          bybit: Decimal.new("0.00009")
        })

      assert result.arbitrage_opportunity == false
      assert Decimal.equal?(result.delta, Decimal.new("0.00001"))
      refute Map.has_key?(result, :annual_apr_delta)
    end

    test "compares multiple symbols" do
      result =
        Funding.compare_funding_rates(%{
          "BTCUSDT" => %{binance: Decimal.new("0.003"), bybit: Decimal.new("0.001")},
          "ETHUSDT" => %{binance: Decimal.new("0.0001"), bybit: Decimal.new("0.00009")}
        })

      assert result["BTCUSDT"].arbitrage_opportunity == true
      assert result["ETHUSDT"].arbitrage_opportunity == false
    end

    test "coerces numeric venue rates" do
      result = Funding.compare_funding_rates(%{binance: 0.003, bybit: 0.001})

      assert result.arbitrage_opportunity == true
      assert Decimal.equal?(result.delta, Decimal.new("0.002"))
    end

    test "treats unparseable venue rates as zero" do
      result = Funding.compare_funding_rates(%{binance: "bad", bybit: 0.001})

      assert result.max_exchange == :bybit
      assert result.min_exchange == :binance
    end
  end

  describe "find_arbitrage_opportunities/2" do
    test "returns sorted opportunities from a multi-symbol comparison" do
      comparison =
        Funding.compare_funding_rates(%{
          "BTCUSDT" => %{binance: Decimal.new("0.003"), bybit: Decimal.new("0.001")},
          "ETHUSDT" => %{binance: Decimal.new("0.0001"), bybit: Decimal.new("0.00009")}
        })

      [btc | _] = Funding.find_arbitrage_opportunities(comparison, 0.001)

      assert btc.symbol == "BTCUSDT"
      assert btc.long_exchange == :bybit
      assert btc.short_exchange == :binance
      assert Decimal.equal?(btc.delta, Decimal.new("0.002"))
      assert Decimal.equal?(btc.annual_apr_delta, Decimal.new("219.00"))
    end

    test "respects min_delta filter" do
      comparison =
        Funding.compare_funding_rates(%{
          binance: Decimal.new("0.003"),
          bybit: Decimal.new("0.001")
        })

      assert Funding.find_arbitrage_opportunities(comparison, 0.01) == []
    end

    test "works for a single-symbol comparison map" do
      comparison =
        Funding.compare_funding_rates(%{
          binance: Decimal.new("0.003"),
          bybit: Decimal.new("0.001")
        })

      [opp] = Funding.find_arbitrage_opportunities(comparison, 0.001)

      assert opp.symbol == :unknown
      assert opp.long_exchange == :bybit
      assert opp.short_exchange == :binance
    end

    test "uses default min_delta when omitted" do
      comparison =
        Funding.compare_funding_rates(%{
          binance: Decimal.new("0.003"),
          bybit: Decimal.new("0.001")
        })

      assert [_opp] = Funding.find_arbitrage_opportunities(comparison)
    end
  end

  describe "funding_trend/1" do
    test "detects increasing trend and slope" do
      series = [
        Decimal.new("0.0001"),
        Decimal.new("0.0001"),
        Decimal.new("0.00012"),
        Decimal.new("0.00013"),
        Decimal.new("0.00015"),
        Decimal.new("0.00016")
      ]

      assert {:ok, trend} = Funding.funding_trend(series)

      assert trend.trend == :increasing
      assert Decimal.compare(trend.slope, Decimal.new(0)) == :gt
      assert Decimal.equal?(trend.max_rate, Decimal.new("0.00016"))
      assert Decimal.equal?(trend.min_rate, Decimal.new("0.0001"))
      assert trend.data_points == 6
    end

    test "accepts maps with :rate keys" do
      series = [
        %{rate: Decimal.new("0.0002")},
        %{rate: Decimal.new("0.00018")},
        %{rate: Decimal.new("0.00015")},
        %{rate: Decimal.new("0.00012")}
      ]

      assert {:ok, trend} = Funding.funding_trend(series)
      assert trend.trend == :decreasing
      assert Decimal.compare(trend.slope, Decimal.new(0)) == :lt
    end

    test "detects flat trend when change is below threshold" do
      series = [
        Decimal.new("0.0001"),
        Decimal.new("0.00011"),
        Decimal.new("0.0001"),
        Decimal.new("0.00011")
      ]

      assert {:ok, trend} = Funding.funding_trend(series)
      assert trend.trend == :flat
    end

    test "returns error for insufficient data" do
      assert {:error, :insufficient_data} = Funding.funding_trend([])
      assert {:error, :insufficient_data} = Funding.funding_trend(nil)
    end

    test "single-point series is flat with zero slope" do
      assert {:ok, trend} = Funding.funding_trend([Decimal.new("0.0001")])

      assert trend.trend == :flat
      assert Decimal.equal?(trend.slope, Decimal.new(0))
      assert trend.data_points == 1
    end
  end
end
