defmodule DeltaCalc.MarginBridge do
  @moduledoc """
  Pure margin-bridge formulas for perp-funded option financing.

  Computes margin usage ratios, runway, payback timelines, negative-funding stress,
  and funding kill-switch conditions using Decimal arithmetic throughout.
  """

  use Descripex, namespace: "/margin_bridge"

  @zero Decimal.new(0)
  @hundred Decimal.new(100)
  @funding_periods_per_day Decimal.new(3)
  @kill_switch_margin_threshold Decimal.new("0.25")
  @default_kill_switch_funding_threshold Decimal.new("-0.02")

  @typedoc "Payback projection from remaining debt and daily funding income."
  @type payback_timeline :: %{
          remaining_debt: Decimal.t(),
          daily_funding: Decimal.t(),
          days_to_payoff: Decimal.t() | nil,
          projected_payoff_date: Date.t() | nil
        }

  @typedoc "Negative-funding stress scenario over a duration."
  @type stress_test_result :: %{
          negative_rate: Decimal.t(),
          position_size: Decimal.t(),
          duration_days: pos_integer(),
          daily_cost: Decimal.t(),
          total_cost: Decimal.t(),
          kill_switch_day: pos_integer() | nil
        }

  @typedoc "Kill-switch evaluation for margin bridge safety."
  @type kill_switch_result :: %{
          avg_funding_24h: Decimal.t(),
          margin_ratio: Decimal.t(),
          funding_threshold: Decimal.t(),
          margin_threshold: Decimal.t(),
          kill_switch_triggered: boolean()
        }

  api(
    :margin_ratio,
    "Compute margin usage as (initial_margin + option_premium) / capital.",
    params: [
      initial_margin: [
        kind: :value,
        description: "Initial margin required for the perp hedge.",
        schema: float()
      ],
      option_premium: [
        kind: :value,
        description: "Option premium financed via portfolio margin.",
        schema: float()
      ],
      capital: [
        kind: :value,
        description: "Total collateral capital backing the strategy.",
        schema: float()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Fraction of capital consumed by margin (0–1)."
    }
  )

  @doc "Return `(initial_margin + option_premium) / capital`, or zero when capital is non-positive."
  @spec margin_ratio(Decimal.t(), Decimal.t(), Decimal.t()) :: Decimal.t()
  def margin_ratio(initial_margin, option_premium, capital) do
    initial_margin = to_decimal(initial_margin)
    option_premium = to_decimal(option_premium)
    capital = to_decimal(capital)

    case Decimal.compare(capital, @zero) do
      :gt ->
        initial_margin
        |> Decimal.add(option_premium)
        |> Decimal.div(capital)

      _ ->
        @zero
    end
  end

  api(
    :margin_runway_days,
    "Estimate days until margin is exhausted at the current daily burn rate.",
    params: [
      available_margin: [
        kind: :value,
        description: "Remaining margin buffer before a margin call.",
        schema: float()
      ],
      daily_burn: [
        kind: :value,
        description: "Daily margin consumption (e.g. negative funding drain).",
        schema: float()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Runway in days, or nil when daily burn is non-positive."
    }
  )

  @doc "Return `available_margin / daily_burn`, or nil when burn is non-positive."
  @spec margin_runway_days(Decimal.t(), Decimal.t()) :: Decimal.t() | nil
  def margin_runway_days(available_margin, daily_burn) do
    available_margin = to_decimal(available_margin)
    daily_burn = to_decimal(daily_burn)

    case Decimal.compare(daily_burn, @zero) do
      :gt -> Decimal.div(available_margin, daily_burn)
      _ -> nil
    end
  end

  api(
    :project_payback_timeline,
    "Project days and optional payoff date from remaining debt and daily funding.",
    params: [
      remaining_debt: [
        kind: :value,
        description: "Outstanding option premium still to be repaid.",
        schema: float()
      ],
      daily_funding: [
        kind: :value,
        description: "Expected daily funding income applied to payback.",
        schema: float()
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Optional `:from_date` (Date) for projected payoff date."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with remaining_debt, daily_funding, days_to_payoff (nil when funding non-positive), " <>
          "and projected_payoff_date when from_date is supplied."
    }
  )

  @doc """
  Project payback timeline from `remaining_debt` and `daily_funding`.

  Pass `from_date:` in opts to include `projected_payoff_date`.
  """
  @spec project_payback_timeline(Decimal.t(), Decimal.t(), keyword()) :: payback_timeline()
  def project_payback_timeline(remaining_debt, daily_funding, opts \\ []) do
    remaining_debt = to_decimal(remaining_debt)
    daily_funding = to_decimal(daily_funding)
    from_date = Keyword.get(opts, :from_date)

    days_to_payoff = payoff_days(remaining_debt, daily_funding)

    %{
      remaining_debt: remaining_debt,
      daily_funding: daily_funding,
      days_to_payoff: days_to_payoff,
      projected_payoff_date: projected_payoff_date(from_date, days_to_payoff)
    }
  end

  api(
    :stress_test_prolonged_negative,
    "Stress-test prolonged negative funding: rate × position × days.",
    params: [
      negative_rate: [
        kind: :value,
        description: "Negative funding rate as percent per 8h period (e.g. -0.025).",
        schema: float()
      ],
      position_size: [
        kind: :value,
        description: "Short perp notional in quote currency.",
        schema: float()
      ],
      duration_days: [
        kind: :value,
        description: "Stress horizon in calendar days.",
        schema: pos_integer()
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Optional `:capital` and `:initial_margin_ratio` to compute kill_switch_day."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with negative_rate, position_size, duration_days, daily_cost, total_cost, " <>
          "and optional kill_switch_day."
    }
  )

  @doc """
  Compute daily and total funding cost under prolonged negative rates.

  Rate is percent per 8h funding period; daily cost assumes three periods per day.
  """
  @spec stress_test_prolonged_negative(Decimal.t(), Decimal.t(), pos_integer(), keyword()) ::
          stress_test_result()
  def stress_test_prolonged_negative(negative_rate, position_size, duration_days, opts \\ [])
      when is_integer(duration_days) and duration_days > 0 do
    negative_rate = to_decimal(negative_rate)
    position_size = to_decimal(position_size)

    daily_cost = negative_funding_daily_cost(negative_rate, position_size)
    total_cost = Decimal.mult(daily_cost, Decimal.new(duration_days))

    %{
      negative_rate: negative_rate,
      position_size: position_size,
      duration_days: duration_days,
      daily_cost: daily_cost,
      total_cost: total_cost,
      kill_switch_day:
        kill_switch_day(
          daily_cost,
          Keyword.get(opts, :capital),
          Keyword.get(opts, :initial_margin_ratio)
        )
    }
  end

  api(
    :check_kill_switch,
    "Evaluate whether negative funding plus high margin usage triggers the kill switch.",
    params: [
      avg_funding_24h: [
        kind: :value,
        description: "24h average funding rate as percent per 8h period.",
        schema: float()
      ],
      margin_ratio: [
        kind: :value,
        description: "Current margin usage ratio (0–1).",
        schema: float()
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Optional `:funding_threshold` (default -0.02 percent per 8h)."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with avg_funding_24h, margin_ratio, thresholds, and kill_switch_triggered " <>
          "(true when avg funding below threshold AND margin ratio above 25%)."
    }
  )

  @doc """
  Return kill-switch status when `avg_funding_24h` is below threshold and margin exceeds 25%.
  """
  @spec check_kill_switch(Decimal.t(), Decimal.t(), keyword()) :: kill_switch_result()
  def check_kill_switch(avg_funding_24h, margin_ratio, opts \\ []) do
    avg_funding_24h = to_decimal(avg_funding_24h)
    margin_ratio = to_decimal(margin_ratio)

    funding_threshold =
      opts
      |> Keyword.get(:funding_threshold, @default_kill_switch_funding_threshold)
      |> to_decimal()

    kill_switch_triggered =
      Decimal.compare(avg_funding_24h, funding_threshold) == :lt and
        Decimal.compare(margin_ratio, @kill_switch_margin_threshold) == :gt

    %{
      avg_funding_24h: avg_funding_24h,
      margin_ratio: margin_ratio,
      funding_threshold: funding_threshold,
      margin_threshold: @kill_switch_margin_threshold,
      kill_switch_triggered: kill_switch_triggered
    }
  end

  defp payoff_days(remaining_debt, daily_funding) do
    case Decimal.compare(daily_funding, @zero) do
      :gt ->
        remaining_debt
        |> Decimal.div(daily_funding)
        |> Decimal.round(2)

      _ ->
        nil
    end
  end

  defp projected_payoff_date(nil, _days_to_payoff), do: nil
  defp projected_payoff_date(_from_date, nil), do: nil

  defp projected_payoff_date(from_date, days_to_payoff) do
    days =
      days_to_payoff
      |> Decimal.round(0, :ceiling)
      |> Decimal.to_integer()

    Date.add(from_date, days)
  end

  defp negative_funding_daily_cost(negative_rate, position_size) do
    negative_rate
    |> Decimal.abs()
    |> Decimal.div(@hundred)
    |> Decimal.mult(position_size)
    |> Decimal.mult(@funding_periods_per_day)
  end

  defp kill_switch_day(_daily_cost, capital, initial_margin_ratio)
       when is_nil(capital) or is_nil(initial_margin_ratio),
       do: nil

  defp kill_switch_day(daily_cost, capital, initial_margin_ratio) do
    capital = to_decimal(capital)
    initial_margin_ratio = to_decimal(initial_margin_ratio)

    margin_headroom =
      @kill_switch_margin_threshold
      |> Decimal.sub(initial_margin_ratio)
      |> Decimal.max(@zero)

    case {Decimal.compare(daily_cost, @zero), Decimal.compare(margin_headroom, @zero)} do
      {:gt, :gt} ->
        capital
        |> Decimal.mult(margin_headroom)
        |> Decimal.div(daily_cost)
        |> Decimal.round(0, :ceiling)
        |> Decimal.to_integer()

      _ ->
        nil
    end
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
