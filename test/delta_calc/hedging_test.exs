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

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      fns = [
        calculate_required_cex_balance: 2,
        check_hedge_coverage: 3,
        needs_rebalancing?: 2,
        calculate_change: 2,
        calculate_percentage_change: 2
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
