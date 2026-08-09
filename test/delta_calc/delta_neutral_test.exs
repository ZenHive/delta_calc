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

  describe "base_numeraire_exposure/1 options" do
    test "subtracts a base-denominated mark exactly once from Black-Scholes delta" do
      params = %{
        kind: :option,
        quantity: %{unit: :base_currency, value: "1"},
        delta: %{semantic: :black_scholes, value: "0.40"},
        mark: %{unit: :base_currency, value: "0.05"}
      }

      assert {:ok, long_exposure} = DeltaNeutral.base_numeraire_exposure(params)

      assert {:ok, short_exposure} =
               params
               |> put_in([:quantity, :value], "-1")
               |> DeltaNeutral.base_numeraire_exposure()

      assert Decimal.equal?(long_exposure, Decimal.new("0.35"))
      assert Decimal.equal?(short_exposure, Decimal.new("-0.35"))
    end

    test "converts a quote-denominated mark to base exactly once" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :base_currency, value: "1"},
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :quote_currency, value: "100", spot_price: "2000"}
               })

      assert Decimal.equal?(exposure, Decimal.new("0.35"))
    end

    test "uses provider Net Transaction Delta without another mark subtraction" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :base_currency, value: "1"},
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert Decimal.equal?(exposure, Decimal.new("0.35"))
    end

    test "multiplies contract count by base contract size exactly once" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :contracts, value: "-2", base_contract_size: "0.5"},
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert Decimal.equal?(exposure, Decimal.new("-0.35"))
    end

    test "accepts provider-adjusted settlement delta" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 period: :settlement,
                 quantity: %{unit: :base_currency, value: "2"},
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert Decimal.equal?(exposure, Decimal.new("0.70"))
    end

    test "accepts explicitly tagged decayed settlement components" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 period: :settlement,
                 quantity: %{unit: :base_currency, value: "1"},
                 delta: %{
                   semantic: :decayed_components,
                   decayed_delta: "0.50",
                   decayed_mark: %{unit: :base_currency, value: "0.15"}
                 }
               })

      assert Decimal.equal?(exposure, Decimal.new("0.35"))
    end

    test "rejects ambiguous settlement-period components" do
      assert {:error, :ambiguous_settlement_input} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 period: :settlement,
                 quantity: %{unit: :base_currency, value: "1"},
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :base_currency, value: "0.05"}
               })
    end
  end

  describe "base_numeraire_exposure/1 inverse perpetuals" do
    test "converts positive signed USD notional to long base exposure" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :usd_notional, value: "12000"},
                 mark: "3000"
               })

      assert Decimal.equal?(exposure, Decimal.new("4"))
    end

    test "converts negative signed USD notional to short base exposure" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :usd_notional, value: "-7500"},
                 mark: "2500"
               })

      assert Decimal.equal?(exposure, Decimal.new("-3"))
    end

    test "converts positive contract count through USD contract size to long base exposure" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :contracts, value: "20", usd_contract_size: "10"},
                 mark: "2000"
               })

      assert Decimal.equal?(exposure, Decimal.new("0.1"))
    end

    test "converts negative contract count through USD contract size to short base exposure" do
      assert {:ok, exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :contracts, value: "-30", usd_contract_size: "10"},
                 mark: "3000"
               })

      assert Decimal.equal?(exposure, Decimal.new("-0.1"))
    end
  end

  describe "base_numeraire_exposure/1 validation" do
    test "returns named errors for untagged, unsupported, and mixed quantity shapes" do
      assert {:error, :untagged_exposure_kind} = DeltaNeutral.base_numeraire_exposure(%{})

      assert {:error, :unsupported_exposure_kind} =
               DeltaNeutral.base_numeraire_exposure(%{kind: :future})

      assert {:error, :untagged_quantity_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{value: "1"},
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert {:error, :mixed_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :base_currency, value: "1", base_contract_size: "1"},
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert {:error, :mixed_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :usd_notional, value: "100", usd_contract_size: "10"},
                 mark: "2000"
               })
    end

    test "returns named errors for invalid delta, mark, period, and exact-value shapes" do
      quantity = %{unit: :base_currency, value: "1"}

      assert {:error, :untagged_delta_semantic} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{value: "0.35"}
               })

      assert {:error, :mixed_delta_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :net_transaction_delta, value: "0.35"},
                 mark: %{unit: :base_currency, value: "0.05"}
               })

      assert {:error, :untagged_mark_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{value: "0.05"}
               })

      assert {:error, :unsupported_exposure_period} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 period: :unknown,
                 quantity: quantity,
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert {:error, :non_positive_spot} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :quote_currency, value: "100", spot_price: "0"}
               })

      assert {:error, :invalid_decimal} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :usd_notional, value: 0.1},
                 mark: "2000"
               })
    end

    test "rejects missing and unsupported top-level and quantity tags" do
      net_delta = %{semantic: :net_transaction_delta, value: "0.35"}

      assert {:error, :invalid_mark_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :usd_notional, value: "100"}
               })

      assert {:error, :invalid_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{kind: :option})

      assert {:error, :unsupported_exposure_kind} =
               DeltaNeutral.base_numeraire_exposure(:option)

      assert {:error, :invalid_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :base_currency},
                 delta: net_delta
               })

      assert {:error, :unsupported_quantity_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :usd_notional, value: "1"},
                 delta: net_delta
               })

      assert {:error, :invalid_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: "1",
                 delta: net_delta
               })

      assert {:error, :invalid_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :contracts, value: "1"},
                 mark: "2000"
               })

      assert {:error, :unsupported_quantity_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{unit: :base_currency, value: "1"},
                 mark: "2000"
               })

      assert {:error, :untagged_quantity_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: %{value: "100"},
                 mark: "2000"
               })

      assert {:error, :invalid_quantity_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :inverse_perpetual,
                 quantity: "100",
                 mark: "2000"
               })
    end

    test "rejects incomplete or unsupported option delta and mark tags" do
      quantity = %{unit: :base_currency, value: "1"}

      assert {:ok, explicit_ordinary} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 period: :ordinary,
                 quantity: quantity,
                 delta: %{semantic: :net_transaction_delta, value: "0.35"}
               })

      assert Decimal.equal?(explicit_ordinary, Decimal.new("0.35"))

      assert {:error, :invalid_mark_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"}
               })

      assert {:error, :invalid_delta_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :net_transaction_delta}
               })

      assert {:error, :unsupported_delta_semantic} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :decayed_components}
               })

      assert {:error, :unsupported_delta_semantic} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :exchange_delta, value: "0.35"}
               })

      assert {:error, :invalid_mark_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :quote_currency, value: "100"}
               })

      assert {:error, :unsupported_mark_unit} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :percent, value: "5"}
               })

      assert {:error, :invalid_mark_shape} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: quantity,
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: "0.05"
               })
    end
  end

  describe "settlement_coverage/1" do
    test "reports disjoint reservations, remaining capacity, and uncovered amount" do
      assert {:ok, coverage} =
               DeltaNeutral.settlement_coverage(%{
                 eligible_base: "10",
                 existing_short_call_obligations: "2",
                 pending_sell_reservations: "1",
                 other_reservations: "0.5",
                 proposed_short_call_obligation: "7"
               })

      assert Decimal.equal?(coverage.eligible_base, Decimal.new("10"))
      assert Decimal.equal?(coverage.existing_reservations.total, Decimal.new("3.5"))
      assert Decimal.equal?(coverage.total_obligation, Decimal.new("10.5"))
      assert Decimal.equal?(coverage.remaining_capacity, Decimal.new("0"))
      assert Decimal.equal?(coverage.uncovered_amount, Decimal.new("0.5"))
      assert coverage.fully_covered == false
      refute Map.has_key?(coverage, :approved)
    end

    test "rejects missing and negative classified quantities" do
      assert {:error, :invalid_coverage_shape} = DeltaNeutral.settlement_coverage(%{})

      assert {:error, :negative_coverage_amount} =
               DeltaNeutral.settlement_coverage(%{
                 eligible_base: "1",
                 existing_short_call_obligations: "0",
                 pending_sell_reservations: "-0.1",
                 other_reservations: "0",
                 proposed_short_call_obligation: "0"
               })
    end
  end

  describe "risk_target/1" do
    test "reports signed residual exposure and absolute target tolerance" do
      assert {:ok, result} =
               DeltaNeutral.risk_target(%{
                 base_numeraire_exposure: "0.55",
                 target_exposure: "0.50",
                 tolerance: "-0.05"
               })

      assert Decimal.equal?(result.residual_exposure, Decimal.new("0.05"))
      assert Decimal.equal?(result.tolerance, Decimal.new("0.05"))
      assert result.within_target == true
      refute Map.has_key?(result, :approved)
    end

    test "keeps settlement coverage orthogonal to a neutral risk target" do
      assert {:ok, option_exposure} =
               DeltaNeutral.base_numeraire_exposure(%{
                 kind: :option,
                 quantity: %{unit: :base_currency, value: "-1"},
                 delta: %{semantic: :black_scholes, value: "0.40"},
                 mark: %{unit: :base_currency, value: "0.05"}
               })

      residual_exposure = Decimal.add(Decimal.new("1"), option_exposure)

      assert {:ok, coverage} =
               DeltaNeutral.settlement_coverage(%{
                 eligible_base: "1",
                 existing_short_call_obligations: "0",
                 pending_sell_reservations: "0",
                 other_reservations: "0",
                 proposed_short_call_obligation: "1"
               })

      assert {:ok, risk} =
               DeltaNeutral.risk_target(%{
                 base_numeraire_exposure: residual_exposure,
                 target_exposure: "0",
                 tolerance: "0.01"
               })

      assert coverage.fully_covered == true
      assert Decimal.equal?(coverage.uncovered_amount, Decimal.new("0"))
      assert Decimal.equal?(risk.residual_exposure, Decimal.new("0.65"))
      assert risk.within_target == false
    end

    test "rejects missing and inexact target inputs" do
      assert {:error, :invalid_risk_target_shape} = DeltaNeutral.risk_target(%{})

      assert {:error, :invalid_decimal} =
               DeltaNeutral.risk_target(%{
                 base_numeraire_exposure: 0.1,
                 target_exposure: "0",
                 tolerance: "0.01"
               })
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
