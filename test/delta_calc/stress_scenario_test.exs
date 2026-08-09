defmodule DeltaCalc.StressScenarioTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.{PortfolioMargin, StressScenario}

  @net_long_account %{
    equity: Decimal.new("1000"),
    positions: [
      %{
        id: :btc_long,
        side: :long,
        quantity: Decimal.new("3"),
        mark_price: Decimal.new("3000"),
        mmr: Decimal.new("0.005")
      },
      %{
        id: :btc_short,
        side: :short,
        quantity: Decimal.new("1"),
        mark_price: Decimal.new("3000"),
        mmr: Decimal.new("0.005")
      }
    ]
  }

  describe "apply_shock/2" do
    test "applies signed shock to mark prices and recomputes equity from PnL" do
      result = StressScenario.apply_shock(@net_long_account, Decimal.new("-10"))

      assert Decimal.equal?(result.shock_pct, Decimal.new("-10"))
      assert Decimal.equal?(result.equity, Decimal.new("400.00000000"))

      [long, short] = result.positions
      assert long.id == :btc_long
      assert Decimal.equal?(long.mark_price, Decimal.new("2700.00000000"))
      assert Decimal.equal?(long.margin, Decimal.new("40.50000000"))
      assert short.id == :btc_short
      assert Decimal.equal?(short.mark_price, Decimal.new("2700.00000000"))
      assert Decimal.equal?(short.margin, Decimal.new("13.50000000"))
    end

    test "reports portfolio_liquidated? when shocked equity is below portfolio maintenance margin" do
      result = StressScenario.apply_shock(@net_long_account, Decimal.new("-20"))

      assert Decimal.equal?(result.equity, Decimal.new("-200.00000000"))
      assert Decimal.equal?(result.portfolio_margin, Decimal.new("24.00000000"))
      assert result.portfolio_liquidated? == true
      assert Enum.all?(result.positions, &(not Map.has_key?(&1, :liquidated?)))
    end

    test "reports portfolio_liquidated? false when shocked equity covers portfolio maintenance margin" do
      result = StressScenario.apply_shock(@net_long_account, Decimal.new("-10"))

      assert Decimal.equal?(result.portfolio_margin, Decimal.new("27.00000000"))
      assert result.portfolio_liquidated? == false
      assert Enum.all?(result.positions, &(not Map.has_key?(&1, :liquidated?)))
    end

    test "does not mark profitable hedge legs with a per-position liquidated? when the book survives" do
      account = %{
        equity: Decimal.new("20"),
        positions: [
          %{
            id: :losing_long,
            side: :long,
            quantity: Decimal.new("5"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          },
          %{
            id: :hedge_short,
            side: :short,
            quantity: Decimal.new("4"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          }
        ]
      }

      result = StressScenario.apply_shock(account, Decimal.new("-15"))

      assert result.portfolio_liquidated? == false
      assert Decimal.equal?(result.equity, Decimal.new("5.00000000"))

      short = Enum.find(result.positions, &(&1.id == :hedge_short))
      assert short.side == :short
      assert not Map.has_key?(short, :liquidated?)
    end

    test "uses PortfolioMargin for netted liquidation price and maintenance margin" do
      shocked_account = %{
        equity: Decimal.new("400"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("2700"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("2700"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = StressScenario.apply_shock(@net_long_account, Decimal.new("-10"))

      assert Decimal.equal?(
               result.portfolio_margin,
               PortfolioMargin.combined_maintenance_margin(shocked_account)
             )

      assert Decimal.equal?(
               result.liquidation_price,
               PortfolioMargin.portfolio_liquidation_price(shocked_account)
             )
    end

    test "falls back to position index when no id or symbol is present" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          }
        ]
      }

      [position] = StressScenario.apply_shock(account, 0).positions

      assert position.id == 0
    end

    test "accepts Decimal-compatible shock and account inputs" do
      account = %{
        equity: 1000,
        positions: [
          %{side: :long, quantity: "1", mark_price: 100, mmr: "0.01"}
        ]
      }

      result = StressScenario.apply_shock(account, "-5")

      assert Decimal.equal?(result.shock_pct, Decimal.new("-5"))
      assert Decimal.equal?(result.equity, Decimal.new("995.00000000"))
    end
  end

  describe "cascade/2" do
    test "reports no liquidations when the shocked portfolio survives" do
      result = StressScenario.cascade(@net_long_account, Decimal.new("-10"))

      assert result.liquidated_positions == []
      assert Decimal.equal?(result.margin_call, Decimal.new("0"))
      assert result.survives? == true
    end

    test "keeps realized losses debited while cascading liquidations" do
      result = StressScenario.cascade(@net_long_account, Decimal.new("-20"))

      assert result.liquidated_positions == [:btc_long, :btc_short]
      assert Decimal.equal?(result.margin_call, Decimal.new("224.00000000"))
      assert result.survives? == false
    end

    test "reports survival false when equity remains negative after all positions are liquidated" do
      account = %{
        equity: Decimal.new("-50"),
        positions: [
          %{
            id: :underwater_long,
            side: :long,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          }
        ]
      }

      result = StressScenario.cascade(account, Decimal.new("-50"))

      assert result.liquidated_positions == [:underwater_long]
      assert Decimal.equal?(result.margin_call, Decimal.new("100.50000000"))
      assert result.survives? == false
    end

    test "uses PortfolioMargin maintenance margin for margin call and survival checks" do
      shocked = %{
        equity: Decimal.new("-200"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("2400"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("2400"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      maintenance = PortfolioMargin.combined_maintenance_margin(shocked)
      shortfall = Decimal.sub(maintenance, shocked.equity)

      result = StressScenario.cascade(@net_long_account, Decimal.new("-20"))

      assert Decimal.equal?(result.margin_call, shortfall)
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(StressScenario) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for StressScenario, got: #{inspect(other)}")
        end

      public_functions =
        StressScenario.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert StressScenario.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
