defmodule DeltaCalc.PortfolioMarginTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.PortfolioMargin

  describe "combined_maintenance_margin/1" do
    test "nets offsetting long and short quantities before applying maintenance margin" do
      account = %{
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.combined_maintenance_margin(account)

      assert Decimal.equal?(result, Decimal.new("30.00000000"))
    end

    test "returns zero when positions fully offset" do
      account = %{
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("2"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("2"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.combined_maintenance_margin(account)

      assert Decimal.equal?(result, Decimal.new("0.00000000"))
    end

    test "returns zero for an empty portfolio" do
      result = PortfolioMargin.combined_maintenance_margin(%{positions: []})

      assert Decimal.equal?(result, Decimal.new("0.00000000"))
    end

    test "accepts integer and string inputs" do
      account = %{
        positions: [
          %{side: :long, quantity: 3, mark_price: 3000, mmr: "0.005"},
          %{side: :short, quantity: "1", mark_price: 3000, mmr: "0.005"}
        ]
      }

      result = PortfolioMargin.combined_maintenance_margin(account)

      assert Decimal.equal?(result, Decimal.new("30.00000000"))
    end

    test "rejects raw float position inputs" do
      account = %{
        positions: [%{side: :long, quantity: 3.0, mark_price: 3000, mmr: "0.005"}]
      }

      assert_raise ArgumentError, fn -> PortfolioMargin.combined_maintenance_margin(account) end
    end

    test "uses signed-notional net mark when offsetting legs have different marks" do
      # Long 3 @ 3000, short 1 @ 3100 → net long 2 @ 2950 (not gross-blended 3025).
      account = %{
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3100"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.combined_maintenance_margin(account)

      # |2| × 2950 × 0.005 = 29.50
      assert Decimal.equal?(result, Decimal.new("29.50000000"))
    end
  end

  describe "portfolio_liquidation_price/1" do
    test "returns liquidation price for a netted long book" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.portfolio_liquidation_price(account)

      assert result == Decimal.new("2512.562814070351758793969849246231")
    end

    test "returns liquidation price for a netted short book" do
      account = %{
        equity: Decimal.new("900"),
        positions: [
          %{
            side: :short,
            quantity: Decimal.new("4"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          },
          %{
            side: :long,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("100"),
            mmr: Decimal.new("0.01")
          }
        ]
      }

      result = PortfolioMargin.portfolio_liquidation_price(account)

      assert result == Decimal.new("396.0396039603960396039603960396040")
    end

    test "returns nil for a flat netted book" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      assert PortfolioMargin.portfolio_liquidation_price(account) == nil
    end

    test "returns nil when margin requirement leaves no liquidation denominator" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("1")
          }
        ]
      }

      assert PortfolioMargin.portfolio_liquidation_price(account) == nil
    end

    test "uses signed-notional net mark for liquidation when offsetting legs differ" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3100"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.portfolio_liquidation_price(account)

      # Net long 2 @ 2950: (2×2950 − 1000) / (2×0.995) = 2462.3115577889…
      assert result == Decimal.new("2462.311557788944723618090452261307")
    end
  end

  describe "margin_usage/1" do
    test "returns used, available, and usage percentage under the portfolio model" do
      account = %{
        equity: Decimal.new("1000"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.margin_usage(account)

      assert Decimal.equal?(result.used, Decimal.new("30.00000000"))
      assert Decimal.equal?(result.available, Decimal.new("970.00000000"))
      assert Decimal.equal?(result.usage_pct, Decimal.new("3.00000000"))
    end

    test "floors available margin at zero when used exceeds equity" do
      account = %{
        equity: Decimal.new("10"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          },
          %{
            side: :short,
            quantity: Decimal.new("1"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.margin_usage(account)

      assert Decimal.equal?(result.used, Decimal.new("30.00000000"))
      assert Decimal.equal?(result.available, Decimal.new("0.00000000"))
      assert Decimal.equal?(result.usage_pct, Decimal.new("300.00000000"))
    end

    test "returns zero usage percentage when equity is not positive" do
      account = %{
        equity: Decimal.new("0"),
        positions: [
          %{
            side: :long,
            quantity: Decimal.new("3"),
            mark_price: Decimal.new("3000"),
            mmr: Decimal.new("0.005")
          }
        ]
      }

      result = PortfolioMargin.margin_usage(account)

      assert Decimal.equal?(result.used, Decimal.new("45.00000000"))
      assert Decimal.equal?(result.available, Decimal.new("0.00000000"))
      assert Decimal.equal?(result.usage_pct, Decimal.new("0"))
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(PortfolioMargin) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for PortfolioMargin, got: #{inspect(other)}")
        end

      public_functions =
        PortfolioMargin.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert PortfolioMargin.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
