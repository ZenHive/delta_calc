defmodule DeltaCalc.LiquidationTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.Liquidation

  describe "liquidation/4 venue formula" do
    # Sources fetched 2026-09-16:
    # Hyperliquid: https://hyperliquid.gitbook.io/hyperliquid-docs/trading/liquidations
    #   P_liq = P - side * margin_available / Q / (1 - l * side),
    #   margin_available = E - l*N, side=1 long/-1 short.
    # Binance USD-M: https://www.binance.com/en/support/faq/detail/b3c689c1f50a44cabb3a84e663b81d93
    #   With one isolated position, maintenance amount=0 and wallet balance=E,
    #   its long/short equations reduce to the same expressions below.
    #
    # Hand fixture: P=2279, E=1, Q=N/P=3/2279, N=3, l=0.021.
    # Hyperliquid long: margin_available=1-(.021*3)=.937;
    #   2279 - .937/(3/2279)/(1-.021) = 1551.923731...
    # Binance long: (Q*P-E)/(Q*(1-l)) = 1551.923731...
    # Hyperliquid short: 2279 + .937/(3/2279)/(1+.021) = 2976.167156...
    # Binance short: (Q*P+E)/(Q*(1+l)) = 2976.167156...
    test "matches hand-derived Hyperliquid and Binance goldens" do
      assert Liquidation.liquidation(D.new(2279), D.new(3), D.new("0.021"), :long)
             |> D.round(2) == D.new("1551.92")

      assert Liquidation.liquidation(D.new(2279), D.new(3), D.new("0.021"), :short)
             |> D.round(2) == D.new("2976.17")
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
