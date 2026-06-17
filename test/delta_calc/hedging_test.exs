defmodule DeltaCalc.HedgingTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Hedging

  # Shared DateTime fixtures — offsets kept realistic (1h apart).
  @t0 ~U[2024-01-01 00:00:00Z]
  @t1 ~U[2024-01-01 01:00:00Z]

  defp snap(total_spot, cex_spot, cold_wallet, hedge_coverage_pct, captured_at) do
    %{
      total_spot: Decimal.new(total_spot),
      cex_spot: Decimal.new(cex_spot),
      cold_wallet: Decimal.new(cold_wallet),
      hedge_coverage_pct: Decimal.new(hedge_coverage_pct),
      captured_at: captured_at
    }
  end

  describe "calculate_required_cex_balance/2" do
    test "60% hedge of 100_000 USD spot" do
      result = Hedging.calculate_required_cex_balance(Decimal.new("100000"), Decimal.new("60"))
      assert Decimal.equal?(result, Decimal.new("60000"))
    end

    test "100% hedge equals total spot" do
      total = Decimal.new("50000")
      result = Hedging.calculate_required_cex_balance(total, Decimal.new("100"))
      assert Decimal.equal?(result, total)
    end

    test "0% hedge returns zero" do
      result = Hedging.calculate_required_cex_balance(Decimal.new("50000"), Decimal.new("0"))
      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "fractional percentage" do
      result = Hedging.calculate_required_cex_balance(Decimal.new("1000"), Decimal.new("33.5"))
      assert Decimal.equal?(result, Decimal.new("335"))
    end

    test "120% hedge exceeds total spot (portfolio margin ceiling)" do
      result = Hedging.calculate_required_cex_balance(Decimal.new("100000"), Decimal.new("120"))
      assert Decimal.equal?(result, Decimal.new("120000"))
    end
  end

  describe "check_hedge_coverage/3" do
    test "coverage meets target returns :ok with coverage percent" do
      assert {:ok, cov} =
               Hedging.check_hedge_coverage(
                 Decimal.new("60000"),
                 Decimal.new("100000"),
                 Decimal.new("60")
               )

      assert Decimal.equal?(cov, Decimal.new("60.00"))
    end

    test "coverage exceeds target also returns :ok" do
      assert {:ok, cov} =
               Hedging.check_hedge_coverage(
                 Decimal.new("75000"),
                 Decimal.new("100000"),
                 Decimal.new("60")
               )

      assert Decimal.equal?(cov, Decimal.new("75.00"))
    end

    test "coverage below target returns :needs_rebalancing" do
      assert {:needs_rebalancing, current, target} =
               Hedging.check_hedge_coverage(
                 Decimal.new("40000"),
                 Decimal.new("100000"),
                 Decimal.new("60")
               )

      assert Decimal.equal?(current, Decimal.new("40.00"))
      assert Decimal.equal?(target, Decimal.new("60"))
    end

    test "zero total_spot yields zero coverage and triggers rebalancing" do
      assert {:needs_rebalancing, cov, target} =
               Hedging.check_hedge_coverage(
                 Decimal.new("0"),
                 Decimal.new("0"),
                 Decimal.new("60")
               )

      assert Decimal.equal?(cov, Decimal.new("0"))
      assert Decimal.equal?(target, Decimal.new("60"))
    end

    test "coverage percent is rounded to 2 decimal places" do
      # 1/3 of 100 = 33.333... → 33.33
      assert {:needs_rebalancing, cov, _} =
               Hedging.check_hedge_coverage(
                 Decimal.new("1"),
                 Decimal.new("3"),
                 Decimal.new("60")
               )

      assert Decimal.equal?(cov, Decimal.new("33.33"))
    end

    test "120% target passes when CEX covers full spot and more" do
      assert {:ok, cov} =
               Hedging.check_hedge_coverage(
                 Decimal.new("120000"),
                 Decimal.new("100000"),
                 Decimal.new("120")
               )

      assert Decimal.equal?(cov, Decimal.new("120.00"))
    end

    test "120% target triggers rebalancing when under-hedged" do
      assert {:needs_rebalancing, current, target} =
               Hedging.check_hedge_coverage(
                 Decimal.new("100000"),
                 Decimal.new("100000"),
                 Decimal.new("120")
               )

      assert Decimal.equal?(current, Decimal.new("100.00"))
      assert Decimal.equal?(target, Decimal.new("120"))
    end
  end

  describe "needs_rebalancing?/2" do
    test "below default 60% target returns true" do
      assert Hedging.needs_rebalancing?(Decimal.new("55"))
    end

    test "at default 60% target returns false" do
      refute Hedging.needs_rebalancing?(Decimal.new("60"))
    end

    test "above default target returns false" do
      refute Hedging.needs_rebalancing?(Decimal.new("75"))
    end

    test "custom target respected" do
      assert Hedging.needs_rebalancing?(Decimal.new("70"), Decimal.new("80"))
      refute Hedging.needs_rebalancing?(Decimal.new("85"), Decimal.new("80"))
    end

    test "zero coverage always needs rebalancing" do
      assert Hedging.needs_rebalancing?(Decimal.new("0"))
    end

    test "120% custom target respected" do
      assert Hedging.needs_rebalancing?(Decimal.new("110"), Decimal.new("120"))
      refute Hedging.needs_rebalancing?(Decimal.new("120"), Decimal.new("120"))
      refute Hedging.needs_rebalancing?(Decimal.new("150"), Decimal.new("120"))
    end
  end

  describe "calculate_change/2" do
    test "positive gains in all dimensions" do
      prior = snap("100000", "50000", "30000", "50.00", @t0)
      current = snap("120000", "65000", "35000", "54.17", @t1)

      result = Hedging.calculate_change(prior, current)

      assert Decimal.equal?(result.total_change, Decimal.new("20000"))
      assert Decimal.equal?(result.cex_change, Decimal.new("15000"))
      assert Decimal.equal?(result.cold_change, Decimal.new("5000"))
      assert Decimal.equal?(result.hedge_change, Decimal.new("4.17"))
      assert_in_delta result.duration_hours, 1.0, 0.001
    end

    test "losses produce negative deltas" do
      prior = snap("100000", "60000", "40000", "60.00", @t0)
      current = snap("80000", "45000", "35000", "56.25", @t1)

      result = Hedging.calculate_change(prior, current)

      assert Decimal.compare(result.total_change, Decimal.new(0)) == :lt
      assert Decimal.compare(result.cex_change, Decimal.new(0)) == :lt
      assert Decimal.compare(result.cold_change, Decimal.new(0)) == :lt
    end

    test "no change between identical snapshots" do
      snap_val = snap("100000", "60000", "40000", "60.00", @t0)
      same = %{snap_val | captured_at: @t1}

      result = Hedging.calculate_change(snap_val, same)

      assert Decimal.equal?(result.total_change, Decimal.new(0))
      assert Decimal.equal?(result.cex_change, Decimal.new(0))
      assert Decimal.equal?(result.cold_change, Decimal.new(0))
      assert Decimal.equal?(result.hedge_change, Decimal.new(0))
      assert_in_delta result.duration_hours, 1.0, 0.001
    end

    test "duration_hours reflects elapsed time" do
      prior = snap("100000", "60000", "40000", "60.00", @t0)
      t2h = DateTime.add(@t0, 7200, :second)
      current = snap("100000", "60000", "40000", "60.00", t2h)

      result = Hedging.calculate_change(prior, current)
      assert_in_delta result.duration_hours, 2.0, 0.001
    end
  end

  describe "calculate_percentage_change/2" do
    test "10% growth in total spot" do
      prior = snap("100000", "60000", "40000", "60.00", @t0)
      current = snap("110000", "60000", "40000", "60.00", @t1)

      result = Hedging.calculate_percentage_change(prior, current)

      assert Decimal.equal?(result.total_pct, Decimal.new("10.00"))
      assert Decimal.equal?(result.cex_pct, Decimal.new("0.00"))
      assert Decimal.equal?(result.cold_pct, Decimal.new("0.00"))
    end

    test "zero prior values produce zero pct to avoid division by zero" do
      prior = snap("0", "0", "0", "0", @t0)
      current = snap("100000", "60000", "40000", "60.00", @t1)

      result = Hedging.calculate_percentage_change(prior, current)

      assert Decimal.equal?(result.total_pct, Decimal.new("0"))
      assert Decimal.equal?(result.cex_pct, Decimal.new("0"))
      assert Decimal.equal?(result.cold_pct, Decimal.new("0"))
      assert Decimal.equal?(result.hedge_pct, Decimal.new("0"))
    end

    test "50% decline in cex" do
      prior = snap("100000", "60000", "40000", "60.00", @t0)
      current = snap("100000", "30000", "40000", "60.00", @t1)

      result = Hedging.calculate_percentage_change(prior, current)

      assert Decimal.equal?(result.cex_pct, Decimal.new("-50.00"))
    end

    test "duration_hours matches calculate_change" do
      prior = snap("100000", "60000", "40000", "60.00", @t0)
      current = snap("105000", "63000", "42000", "60.00", @t1)

      pct_result = Hedging.calculate_percentage_change(prior, current)
      abs_result = Hedging.calculate_change(prior, current)

      assert_in_delta pct_result.duration_hours, abs_result.duration_hours, 0.001
    end

    test "percentage is rounded to 2 decimal places" do
      prior = snap("3", "3", "3", "3", @t0)
      current = snap("4", "4", "4", "4", @t1)

      result = Hedging.calculate_percentage_change(prior, current)

      # 1/3 * 100 = 33.33...
      assert Decimal.equal?(result.total_pct, Decimal.new("33.33"))
    end
  end

  describe "calculate_hedge_requirements/2" do
    test "60% hedge of 180k total with sufficient CEX" do
      result =
        Hedging.calculate_hedge_requirements(
          Decimal.new("180000"),
          %{cex_spot: Decimal.new("108000"), target_hedge_percent: Decimal.new("60")}
        )

      assert Decimal.equal?(result.required_hedge, Decimal.new("108000"))
      assert Decimal.equal?(result.required_cex_balance, Decimal.new("108000"))
      assert Decimal.equal?(result.effective_target_percent, Decimal.new("60"))
      refute result.capped_at_max
      assert result.cex_sufficient
      refute result.needs_transfer
    end

    test "caps 120% target at 100% for portfolio margin 1:1 max" do
      result =
        Hedging.calculate_hedge_requirements(
          Decimal.new("100000"),
          %{cex_spot: Decimal.new("100000"), target_hedge_percent: Decimal.new("120")}
        )

      assert Decimal.equal?(result.required_hedge, Decimal.new("100000"))
      assert Decimal.equal?(result.effective_target_percent, Decimal.new("100"))
      assert result.capped_at_max
      assert result.cex_sufficient
    end

    test "zero spot yields zero requirements" do
      result =
        Hedging.calculate_hedge_requirements(
          Decimal.new("0"),
          %{cex_spot: Decimal.new("0"), target_hedge_percent: Decimal.new("60")}
        )

      assert Decimal.equal?(result.required_hedge, Decimal.new("0"))
      assert Decimal.equal?(result.required_cex_balance, Decimal.new("0"))
      assert result.cex_sufficient
      refute result.needs_transfer
    end

    test "full 100% hedge equals total spot" do
      total = Decimal.new("50000")

      result =
        Hedging.calculate_hedge_requirements(
          total,
          %{cex_spot: Decimal.new("30000"), target_hedge_percent: Decimal.new("100")}
        )

      assert Decimal.equal?(result.required_hedge, total)
      refute result.cex_sufficient
      assert result.needs_transfer
    end

    test "insufficient CEX triggers transfer flag" do
      result =
        Hedging.calculate_hedge_requirements(
          Decimal.new("150000"),
          %{cex_spot: Decimal.new("80000"), target_hedge_percent: Decimal.new("60")}
        )

      refute result.cex_sufficient
      assert result.needs_transfer
      assert Decimal.equal?(result.required_cex_balance, Decimal.new("90000"))
    end
  end

  describe "calculate_funding_cost/3" do
    test "daily cost from 8h funding rate with 3 periods per day" do
      # $54k position at 0.01% per 8h -> $54k * 0.0001 * 3 = $16.20/day
      result =
        Hedging.calculate_funding_cost(
          Decimal.new("54000"),
          Decimal.new("0.0001"),
          3
        )

      assert Decimal.equal?(result, Decimal.new("16.2"))
    end

    test "negative funding rate produces negative cost (payment received)" do
      result =
        Hedging.calculate_funding_cost(
          Decimal.new("100000"),
          Decimal.new("-0.00005"),
          3
        )

      assert Decimal.compare(result, Decimal.new(0)) == :lt
    end

    test "zero position size yields zero cost" do
      result =
        Hedging.calculate_funding_cost(
          Decimal.new("0"),
          Decimal.new("0.0001"),
          3
        )

      assert Decimal.equal?(result, Decimal.new("0"))
    end
  end

  describe "needs_cex_transfer?/2" do
    test "returns true when CEX is below requirement" do
      assert Hedging.needs_cex_transfer?(Decimal.new("50000"), Decimal.new("60000"))
    end

    test "returns false when CEX meets requirement" do
      refute Hedging.needs_cex_transfer?(Decimal.new("60000"), Decimal.new("60000"))
      refute Hedging.needs_cex_transfer?(Decimal.new("70000"), Decimal.new("60000"))
    end
  end

  describe "get_basis_spread/2" do
    test "contango when perp trades above spot" do
      result = Hedging.get_basis_spread(Decimal.new("45000"), Decimal.new("45100"))

      assert Decimal.equal?(result.spread, Decimal.new("100"))
      assert Decimal.equal?(result.spread_pct, Decimal.new("0.2222"))
      assert result.direction == :contango
    end

    test "backwardation when perp trades below spot" do
      result = Hedging.get_basis_spread(Decimal.new("45000"), Decimal.new("44900"))

      assert result.direction == :backwardation
      assert Decimal.compare(result.spread_pct, Decimal.new(0)) == :lt
    end

    test "flat when prices are equal" do
      price = Decimal.new("30000")
      result = Hedging.get_basis_spread(price, price)

      assert result.direction == :flat
      assert Decimal.equal?(result.spread_pct, Decimal.new("0"))
    end

    test "zero spot price yields zero spread percent" do
      result = Hedging.get_basis_spread(Decimal.new("0"), Decimal.new("100"))

      assert Decimal.equal?(result.spread_pct, Decimal.new("0"))
    end
  end

  describe "enforce_max_hedge/2" do
    test "caps requested hedge at spot value" do
      result = Hedging.enforce_max_hedge(Decimal.new("100000"), Decimal.new("120000"))
      assert Decimal.equal?(result, Decimal.new("100000"))
    end

    test "passes through hedge below spot" do
      result = Hedging.enforce_max_hedge(Decimal.new("100000"), Decimal.new("60000"))
      assert Decimal.equal?(result, Decimal.new("60000"))
    end

    test "zero spot yields zero hedge" do
      result = Hedging.enforce_max_hedge(Decimal.new("0"), Decimal.new("50000"))
      assert Decimal.equal?(result, Decimal.new("0"))
    end
  end

  describe "calculate_110_percent_hedge/1" do
    test "returns 110% of spot value" do
      result = Hedging.calculate_110_percent_hedge(Decimal.new("45000"))
      assert Decimal.equal?(result, Decimal.new("49500"))
    end

    test "zero spot yields zero hedge" do
      assert Decimal.equal?(
               Hedging.calculate_110_percent_hedge(Decimal.new("0")),
               Decimal.new("0")
             )
    end
  end

  describe "cex_sufficient?/2" do
    test "returns true when CEX meets or exceeds requirement" do
      assert Hedging.cex_sufficient?(Decimal.new("108000"), Decimal.new("108000"))
      assert Hedging.cex_sufficient?(Decimal.new("120000"), Decimal.new("108000"))
    end

    test "returns false when CEX is below requirement" do
      refute Hedging.cex_sufficient?(Decimal.new("90000"), Decimal.new("108000"))
    end
  end

  describe "suggest_hedge_distribution/1" do
    test "prioritizes Deribit and caps per-exchange allocation" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("-108000"),
          available_exchanges: [:deribit, :binance, :bybit],
          preferences: %{deribit_priority: true, max_per_exchange: Decimal.new("0.8")}
        })

      assert Decimal.equal?(result.allocations.deribit, Decimal.new("-86400"))
      assert Decimal.equal?(result.allocations.binance, Decimal.new("-10800"))
      assert Decimal.equal?(result.allocations.bybit, Decimal.new("-10800"))

      total =
        result.allocations
        |> Map.values()
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert Decimal.equal?(total, Decimal.new("-108000"))
      assert result.notes != []
    end

    test "splits evenly across exchanges without Deribit priority" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("-90000"),
          available_exchanges: [:binance, :bybit]
        })

      assert Decimal.equal?(result.allocations.binance, Decimal.new("-45000"))
      assert Decimal.equal?(result.allocations.bybit, Decimal.new("-45000"))
      assert result.notes == []
    end

    test "single exchange receives full allocation" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("-50000"),
          available_exchanges: [:binance]
        })

      assert Decimal.equal?(result.allocations.binance, Decimal.new("-50000"))
    end

    test "zero target yields empty allocations" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("0"),
          available_exchanges: [:deribit, :binance]
        })

      assert result.allocations == %{}
    end

    test "positive hedge target allocates long notional" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("60000"),
          available_exchanges: [:binance, :bybit]
        })

      assert Decimal.compare(result.allocations.binance, Decimal.new(0)) == :gt
      assert Decimal.compare(result.allocations.bybit, Decimal.new(0)) == :gt
    end

    test "three-way split absorbs rounding remainder on first venue" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("-10001"),
          available_exchanges: [:binance, :bybit, :okx]
        })

      total =
        result.allocations
        |> Map.values()
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      assert Decimal.equal?(total, Decimal.new("-10001"))
    end

    test "deribit-only venue receives full target despite max cap preference" do
      result =
        Hedging.suggest_hedge_distribution(%{
          total_hedge_target: Decimal.new("-100000"),
          available_exchanges: [:deribit],
          preferences: %{deribit_priority: true, max_per_exchange: Decimal.new("0.8")}
        })

      assert Decimal.equal?(result.allocations.deribit, Decimal.new("-100000"))
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      fns = [
        calculate_required_cex_balance: 2,
        check_hedge_coverage: 3,
        needs_rebalancing?: 2,
        calculate_change: 2,
        calculate_percentage_change: 2,
        calculate_hedge_requirements: 2,
        calculate_funding_cost: 3,
        needs_cex_transfer?: 2,
        get_basis_spread: 2,
        enforce_max_hedge: 2,
        calculate_110_percent_hedge: 1,
        cex_sufficient?: 2,
        suggest_hedge_distribution: 1
      ]

      {:docs_v1, _, :elixir, _, _, _, fn_docs} = Code.fetch_docs(Hedging)

      for {name, arity} <- fns do
        doc =
          Enum.find(fn_docs, fn
            {{:function, ^name, ^arity}, _, _, _, _} -> true
            _ -> false
          end)

        assert doc, "Missing doc entry for #{name}/#{arity}"
        {{:function, ^name, ^arity}, _, _, _doc_body, meta} = doc
        assert Map.has_key?(meta, :hints), "Missing api() hints for #{name}/#{arity}"
      end
    end
  end
end
