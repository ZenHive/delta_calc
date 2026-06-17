defmodule DeltaCalc.FundingProjectionTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.FundingProjection

  describe "project_payback_timeline/1" do
    test "phase7 example: 2700 debt at 90/day with 20% volatility" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 2700,
          daily_funding: 90,
          funding_volatility: 0.2
        })

      assert result == %{best_case: 25, expected: 30, worst_case: 38}
    end

    test "zero volatility collapses all scenarios to expected" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 1000,
          daily_funding: 50,
          funding_volatility: 0
        })

      assert result == %{best_case: 20, expected: 20, worst_case: 20}
    end

    test "zero remaining debt returns zero days for all cases" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 0,
          daily_funding: 90,
          funding_volatility: 0.2
        })

      assert result == %{best_case: 0, expected: 0, worst_case: 0}
    end

    test "negative remaining debt is treated as already paid" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: -100,
          daily_funding: 90,
          funding_volatility: 0.2
        })

      assert result == %{best_case: 0, expected: 0, worst_case: 0}
    end

    test "zero daily funding makes all scenarios impossible" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 1000,
          daily_funding: 0,
          funding_volatility: 0.2
        })

      assert result == %{best_case: nil, expected: nil, worst_case: nil}
    end

    test "negative daily funding makes all scenarios impossible" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 1000,
          daily_funding: -10,
          funding_volatility: 0.2
        })

      assert result == %{best_case: nil, expected: nil, worst_case: nil}
    end

    test "high volatility can zero out worst-case income" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 1000,
          daily_funding: 10,
          funding_volatility: 1
        })

      assert result.best_case == 50
      assert result.expected == 100
      assert result.worst_case == nil
    end

    test "ceil partial days for conservative payback estimates" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: 100,
          daily_funding: 33,
          funding_volatility: 0
        })

      assert result.expected == 4
    end

    test "accepts Decimal inputs" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: Decimal.new("2700"),
          daily_funding: Decimal.new("90"),
          funding_volatility: Decimal.new("0.2")
        })

      assert result == %{best_case: 25, expected: 30, worst_case: 38}
    end

    test "accepts string inputs" do
      result =
        FundingProjection.project_payback_timeline(%{
          remaining_debt: "1000",
          daily_funding: "40",
          funding_volatility: "0.25"
        })

      assert result.best_case == 20
      assert result.expected == 25
      assert result.worst_case == 34
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      fns = [project_payback_timeline: 1]

      {:docs_v1, _, :elixir, _, _, _, fn_docs} = Code.fetch_docs(FundingProjection)

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
