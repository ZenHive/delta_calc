defmodule DeltaCalc.LiquidationTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.Liquidation

  defp assert_close(actual, expected, tolerance) do
    diff = actual |> D.sub(expected) |> D.abs()

    assert D.compare(diff, D.new(tolerance)) != :gt,
           "expected #{D.to_string(expected)} ± #{tolerance}, got #{D.to_string(actual)}"
  end

  # Hyperliquid published formula (fetched 2026-09-16):
  #   https://hyperliquid.gitbook.io/hyperliquid-docs/trading/liquidations
  #   liq_price = price - side * margin_available / position_size / (1 - l * side)
  #   l = 1/MAINTENANCE_LEVERAGE; side = 1 long / -1 short
  #   margin_available (cross) = account_value - maintenance_margin_required
  defp hyperliquid_liq(price, equity, notional, mmr, side) do
    quantity = D.div(notional, price)
    margin_available = D.sub(equity, D.mult(mmr, notional))
    side_sign = side_sign(side)
    denom = D.sub(D.new(1), D.mult(mmr, side_sign))

    price
    |> D.sub(D.div(D.div(D.mult(side_sign, margin_available), quantity), denom))
  end

  # Binance USDⓈ-M isolated one-way (fetched 2026-09-16):
  #   https://www.binance.com/en/support/faq/b3c689c1f50a44cabb3a84e663b81d93
  #   https://www.binance.info/en/support/faq/detail/b3c689c1f50a44cabb3a84e663b81d93
  # Isolated: TMM=0, UPNL=0; WB is isolatedWalletBalance. With cumB=0:
  #   liq = (WB - Side1BOTH * Position1BOTH * EP1BOTH)
  #         / (Position1BOTH * MMRB - Side1BOTH * Position1BOTH)
  #   Side1BOTH = 1 long / -1 short
  defp binance_isolated_one_way(price, equity, quantity, mmr, side) do
    side_sign = side_sign(side)
    numer = D.sub(equity, D.mult(side_sign, D.mult(quantity, price)))
    denom = D.sub(D.mult(quantity, mmr), D.mult(side_sign, quantity))
    D.div(numer, denom)
  end

  defp side_sign(:long), do: D.new(1)
  defp side_sign(:short), do: D.new(-1)

  describe "liquidation/4 venue formula" do
    # Same inputs on both venues: P=2279, E=1, N=leff*E=3, Q=N/P=3/2279,
    # l=0.021, leff=3. Both published formulas reduce to
    #   long  = P * (1 - 1/leff) / (1 - l)
    #   short = P * (1 + 1/leff) / (1 + l)
    #
    # Hyperliquid long: margin_available = 1 - 0.021*3 = 0.937
    #   2279 - 0.937/(3/2279)/(1-0.021) = 4_558_000/2937 = 1551.923731...
    # Binance long (Side=1, cumB=0):
    #   (1 - 3) / ((3/2279)*(0.021-1)) = 4_558_000/2937 = 1551.923731...
    # Hyperliquid short: 2279 + 0.937/(3/2279)/(1+0.021) = 9_116_000/3063 = 2976.167156...
    # Binance short (Side=-1):
    #   (1 + 3) / ((3/2279)*(0.021+1)) = 9_116_000/3063 = 2976.167156...
    #
    # Nearest cent is 1551.92 / 2976.17 (3rd decimal 3 and 6). Task text
    # 1551.93 / 2976.16 is a 1-cent transcription of these same unrounded values.
    test "matches hand-derived Hyperliquid and Binance goldens" do
      price = D.new(2279)
      equity = D.new(1)
      notional = D.new(3)
      mmr = D.new("0.021")
      quantity = D.div(notional, price)
      leff = D.new(3)

      long = Liquidation.liquidation(price, leff, mmr, :long)
      short = Liquidation.liquidation(price, leff, mmr, :short)

      assert_close(long, hyperliquid_liq(price, equity, notional, mmr, :long), "0.00000001")
      assert_close(short, hyperliquid_liq(price, equity, notional, mmr, :short), "0.00000001")

      assert_close(
        long,
        binance_isolated_one_way(price, equity, quantity, mmr, :long),
        "0.00000001"
      )

      assert_close(
        short,
        binance_isolated_one_way(price, equity, quantity, mmr, :short),
        "0.00000001"
      )

      assert D.equal?(D.round(long, 2), D.new("1551.92"))
      assert D.equal?(D.round(short, 2), D.new("2976.17"))
    end

    test "returns zero when a long liquidation is unreachable at leverage at or below one" do
      for leverage <- [D.new(0), D.new("0.5"), D.new(1)] do
        assert D.equal?(
                 Liquidation.liquidation(D.new(2279), leverage, D.new("0.021"), :long),
                 D.new(0)
               )
      end
    end
  end
end
