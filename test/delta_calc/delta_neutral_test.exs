defmodule DeltaCalc.DeltaNeutralTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.{DeltaNeutral, Hedging}

  describe "net_delta/1" do
    test "aggregates spot, perp, and exchange-supplied option deltas" do
      positions = [
        %{kind: :spot, size: Decimal.new("1.5"), side: :long},
        %{kind: :perp, size: Decimal.new("1.0"), side: :short},
        %{kind: :option, delta: Decimal.new("0.35")}
      ]

      assert Decimal.equal?(DeltaNeutral.net_delta(positions), Decimal.new("0.85000000"))
    end

    test "uses explicit delta for spot and perp when provided" do
      positions = [
        %{kind: :spot, size: Decimal.new("2"), side: :long, delta: Decimal.new("1.25")},
        %{kind: :perp, size: Decimal.new("3"), side: :long, delta: Decimal.new("-0.75")}
      ]

      assert Decimal.equal?(DeltaNeutral.net_delta(positions), Decimal.new("0.50000000"))
    end

    test "accepts notional instead of size" do
      positions = [
        %{kind: :spot, notional: "2.5", side: :long},
        %{kind: :perp, notional: 1, side: :short}
      ]

      assert Decimal.equal?(DeltaNeutral.net_delta(positions), Decimal.new("1.50000000"))
    end

    test "defaults spot/perp side to long" do
      positions = [%{kind: :spot, size: Decimal.new("0.5")}]

      assert Decimal.equal?(DeltaNeutral.net_delta(positions), Decimal.new("0.50000000"))
    end

    test "empty positions return zero" do
      assert Decimal.equal?(DeltaNeutral.net_delta([]), Decimal.new("0"))
    end

    test "negative option delta from exchange reduces net exposure" do
      positions = [
        %{kind: :spot, size: Decimal.new("1"), side: :long},
        %{kind: :option, delta: Decimal.new("-0.4")}
      ]

      assert Decimal.equal?(DeltaNeutral.net_delta(positions), Decimal.new("0.60000000"))
    end

    test "raises when spot/perp position lacks size and notional" do
      assert_raise ArgumentError, ~r/requires :size or :notional/, fn ->
        DeltaNeutral.net_delta([%{kind: :spot, side: :long}])
      end
    end

    test "raises when option position lacks exchange delta" do
      assert_raise KeyError, fn ->
        DeltaNeutral.net_delta([%{kind: :option, size: Decimal.new("1")}])
      end
    end
  end

  describe "rebalance_to_neutral/1" do
    test "returns short perp hedge when net delta is long" do
      positions = [
        %{kind: :spot, size: Decimal.new("2"), side: :long},
        %{kind: :perp, size: Decimal.new("0.5"), side: :short}
      ]

      result = DeltaNeutral.rebalance_to_neutral(positions)

      assert result.within_tolerance == false
      assert result.side == :short
      assert Decimal.equal?(result.size, Decimal.new("1.50000000"))
      assert result.instrument == :perp
      assert Decimal.equal?(result.net_delta, Decimal.new("1.50000000"))
      assert Decimal.equal?(result.signed_hedge, Decimal.new("-1.50000000"))
    end

    test "returns long perp hedge when net delta is short" do
      positions = [
        %{kind: :spot, size: Decimal.new("1"), side: :long},
        %{kind: :perp, size: Decimal.new("2"), side: :short}
      ]

      result = DeltaNeutral.rebalance_to_neutral(positions)

      assert result.within_tolerance == false
      assert result.side == :long
      assert Decimal.equal?(result.size, Decimal.new("1.00000000"))
      assert Decimal.equal?(result.signed_hedge, Decimal.new("1.00000000"))
    end

    test "returns no hedge when net delta is within default tolerance" do
      positions = [%{kind: :spot, size: Decimal.new("0.00005"), side: :long}]

      result = DeltaNeutral.rebalance_to_neutral(positions)

      assert result.within_tolerance == true
      assert result.side == :none
      assert Decimal.equal?(result.size, Decimal.new("0"))
      assert Decimal.equal?(result.signed_hedge, Decimal.new("0"))
    end

    test "respects custom tolerance from params map" do
      positions = [%{kind: :spot, size: Decimal.new("0.05"), side: :long}]

      within =
        DeltaNeutral.rebalance_to_neutral(%{
          positions: positions,
          tolerance: Decimal.new("0.1")
        })

      outside =
        DeltaNeutral.rebalance_to_neutral(%{
          positions: positions,
          tolerance: Decimal.new("0.01")
        })

      assert within.within_tolerance == true
      assert outside.within_tolerance == false
      assert outside.side == :short
    end

    test "supports spot hedge instrument override" do
      result =
        DeltaNeutral.rebalance_to_neutral(%{
          positions: [%{kind: :spot, size: Decimal.new("1"), side: :long}],
          instrument: :spot
        })

      assert result.instrument == :spot
      assert result.side == :short
    end

    test "returns balanced result for empty portfolio" do
      result = DeltaNeutral.rebalance_to_neutral([])

      assert result.within_tolerance == true
      assert result.side == :none
      assert Decimal.equal?(result.net_delta, Decimal.new("0"))
    end

    test "composes with Hedging.suggest_hedge_distribution/1" do
      positions = [
        %{kind: :spot, size: Decimal.new("3"), side: :long},
        %{kind: :option, delta: Decimal.new("0.5")}
      ]

      rebalance = DeltaNeutral.rebalance_to_neutral(positions)

      distribution =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: rebalance.signed_hedge,
          available_exchanges: [:deribit, :binance]
        })

      total_allocated =
        distribution.allocations
        |> Map.values()
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert map_size(distribution.allocations) == 2
      assert Decimal.equal?(total_allocated, rebalance.signed_hedge)
    end

    test "accepts canonical string tolerance and delta inputs" do
      positions = [%{kind: :option, delta: "0.05"}]

      result =
        DeltaNeutral.rebalance_to_neutral(%{
          positions: positions,
          tolerance: "0.1"
        })

      assert result.within_tolerance == true
      assert Decimal.equal?(result.net_delta, Decimal.new("0.05000000"))
    end

    test "rejects raw float tolerance and delta inputs" do
      assert_raise ArgumentError, fn ->
        DeltaNeutral.rebalance_to_neutral(%{
          positions: [%{kind: :option, delta: 0.05}],
          tolerance: "0.1"
        })
      end

      assert_raise ArgumentError, fn ->
        DeltaNeutral.rebalance_to_neutral(%{
          positions: [%{kind: :option, delta: "0.05"}],
          tolerance: 0.1
        })
      end
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(DeltaNeutral) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for DeltaNeutral, got: #{inspect(other)}")
        end

      public_functions =
        DeltaNeutral.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert DeltaNeutral.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
