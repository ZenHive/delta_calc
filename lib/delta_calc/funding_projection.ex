defmodule DeltaCalc.FundingProjection do
  @moduledoc """
  Pure funding-income projections for margin payback timelines.

  Computes best-, expected-, and worst-case payback horizons from remaining debt,
  average daily funding income, and funding-rate volatility. Income tracking and
  persistence live in the dashboard — this module is projection math only.
  """

  use Descripex, namespace: "/funding_projection"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @one Decimal.new(1)

  @type payback_days :: non_neg_integer() | nil

  @type payback_params :: %{
          required(:remaining_debt) => DecimalInput.input(),
          required(:daily_funding) => DecimalInput.input(),
          required(:funding_volatility) => DecimalInput.input()
        }

  @type payback_timeline :: %{
          best_case: payback_days(),
          expected: payback_days(),
          worst_case: payback_days()
        }

  api(
    :project_payback_timeline,
    "Project best-, expected-, and worst-case payback days under funding income volatility (not single-scenario payoff dates — see MarginBridge.payback_timeline/3).",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :remaining_debt, :daily_funding, and :funding_volatility (0-1 fraction) as canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          remaining_debt: String.t(),
          daily_funding: String.t(),
          funding_volatility: String.t()
        }
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :best_case, :expected, and :worst_case day counts (nil when payback is impossible)."
    }
  )

  @doc """
  Projects payback days under high-, current-, and low-funding scenarios.

  Volatility scales daily income by `±funding_volatility`:
  - **best_case** — debt divided by `daily_funding * (1 + volatility)` (funding stays high)
  - **expected** — debt divided by `daily_funding` (current rate continues)
  - **worst_case** — debt divided by `daily_funding * (1 - volatility)` (funding stays low)

  Returns `nil` for scenarios where effective daily income is zero or negative.
  Zero remaining debt yields `0` for all cases.

  ## Examples

      iex> DeltaCalc.FundingProjection.project_payback_timeline(%{
      ...>   remaining_debt: 2700,
      ...>   daily_funding: 90,
      ...>   funding_volatility: "0.2"
      ...> })
      %{best_case: 25, expected: 30, worst_case: 38}

      iex> DeltaCalc.FundingProjection.project_payback_timeline(%{
      ...>   remaining_debt: 0,
      ...>   daily_funding: 90,
      ...>   funding_volatility: "0.2"
      ...> })
      %{best_case: 0, expected: 0, worst_case: 0}
  """
  @spec project_payback_timeline(payback_params()) :: payback_timeline()
  def project_payback_timeline(params) do
    debt = DecimalInput.cast!(params.remaining_debt)
    daily_funding = DecimalInput.cast!(params.daily_funding)
    volatility = DecimalInput.cast!(params.funding_volatility)

    if Decimal.compare(debt, @zero) != :gt do
      %{best_case: 0, expected: 0, worst_case: 0}
    else
      high_income = scale_income(daily_funding, volatility, :high)
      low_income = scale_income(daily_funding, volatility, :low)

      %{
        best_case: payback_days(debt, high_income),
        expected: payback_days(debt, daily_funding),
        worst_case: payback_days(debt, low_income)
      }
    end
  end

  @spec scale_income(Decimal.t(), Decimal.t(), :high | :low) :: Decimal.t()
  defp scale_income(daily_funding, volatility, :high) do
    factor = Decimal.add(@one, volatility)
    Decimal.mult(daily_funding, factor)
  end

  defp scale_income(daily_funding, volatility, :low) do
    factor = Decimal.sub(@one, volatility)
    Decimal.mult(daily_funding, factor)
  end

  @spec payback_days(Decimal.t(), Decimal.t()) :: payback_days()
  defp payback_days(debt, income) do
    case Decimal.compare(income, @zero) do
      :gt ->
        debt
        |> Decimal.div(income)
        |> days_from_ratio()

      _ ->
        nil
    end
  end

  @spec days_from_ratio(Decimal.t()) :: non_neg_integer()
  defp days_from_ratio(ratio) do
    ratio
    |> Decimal.round(0, :up)
    |> Decimal.to_integer()
  end
end
