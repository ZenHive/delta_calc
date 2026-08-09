defmodule DeltaCalc.MarginBridge do
  @moduledoc """
  Pure margin-bridge formulas for perp-funded option financing.

  Computes margin usage ratios, runway, payback timelines, negative-funding stress,
  and funding kill-switch conditions using Decimal arithmetic throughout.
  """

  use Descripex, namespace: "/margin_bridge"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @default_periods_per_day 3
  @default_kill_switch_margin_threshold Decimal.new("0.25")
  @default_kill_switch_daily_funding_threshold Decimal.new("-0.0006")

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
          per_period_funding_rate: Decimal.t(),
          periods_per_day: Decimal.t(),
          daily_funding_rate: Decimal.t(),
          margin_ratio: Decimal.t(),
          daily_funding_threshold: Decimal.t(),
          margin_threshold: Decimal.t(),
          kill_switch_triggered: boolean()
        }

  api(
    :margin_ratio,
    "Compute margin usage as (initial_margin + option_premium) / capital.",
    params: [
      initial_margin: [
        kind: :value,
        description:
          "Initial margin required for the perp hedge as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      option_premium: [
        kind: :value,
        description:
          "Option premium financed via portfolio margin as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      capital: [
        kind: :value,
        description:
          "Total collateral capital backing the strategy as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Fraction of capital consumed by margin (0–1)."
    }
  )

  @doc "Return `(initial_margin + option_premium) / capital`, or zero when capital is non-positive."
  @spec margin_ratio(DecimalInput.input(), DecimalInput.input(), DecimalInput.input()) ::
          Decimal.t()
  def margin_ratio(initial_margin, option_premium, capital) do
    initial_margin = DecimalInput.cast!(initial_margin)
    option_premium = DecimalInput.cast!(option_premium)
    capital = DecimalInput.cast!(capital)

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
        description:
          "Remaining margin buffer before a margin call as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      daily_burn: [
        kind: :value,
        description:
          "Daily margin consumption as a canonical decimal string (e.g. negative funding drain); native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Runway in days, or nil when daily burn is non-positive."
    }
  )

  @doc "Return `available_margin / daily_burn`, or nil when burn is non-positive."
  @spec margin_runway_days(DecimalInput.input(), DecimalInput.input()) :: Decimal.t() | nil
  def margin_runway_days(available_margin, daily_burn) do
    available_margin = DecimalInput.cast!(available_margin)
    daily_burn = DecimalInput.cast!(daily_burn)

    case Decimal.compare(daily_burn, @zero) do
      :gt -> Decimal.div(available_margin, daily_burn)
      _ -> nil
    end
  end

  api(
    :payback_timeline,
    "Single-scenario payback: days to payoff and optional projected payoff date from daily funding.",
    params: [
      remaining_debt: [
        kind: :value,
        description:
          "Outstanding option premium still to be repaid as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      daily_funding: [
        kind: :value,
        description:
          "Expected daily funding income applied to payback as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
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
  Compute single-scenario payback days from `remaining_debt` and `daily_funding`.

  Pass `from_date:` in opts to include `projected_payoff_date`.
  `days_to_payoff` preserves Decimal precision; date projection alone rounds up
  because a `Date` is an intrinsic whole-day boundary.
  For best/expected/worst cases under funding volatility, use
  `DeltaCalc.FundingProjection.project_payback_timeline/1`.
  """
  @spec payback_timeline(DecimalInput.input(), DecimalInput.input(), keyword()) ::
          payback_timeline()
  def payback_timeline(remaining_debt, daily_funding, opts \\ []) do
    remaining_debt = DecimalInput.cast!(remaining_debt)
    daily_funding = DecimalInput.cast!(daily_funding)
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
        description:
          "Negative funding rate as a decimal fraction per funding period " <>
            "as a canonical decimal string (e.g. \"-0.00025\" for -0.025%); native Elixir callers " <>
            "may also pass Decimal or integer. Scale to daily cost via `:periods_per_day` in opts.",
        schema: String.t()
      ],
      position_size: [
        kind: :value,
        description:
          "Short perp notional in quote currency as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      duration_days: [
        kind: :value,
        description: "Stress horizon in calendar days.",
        schema: pos_integer()
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional keyword list. `:periods_per_day` — positive-integer funding periods per calendar day " <>
            "(default convention: 3; override for the caller's cadence). " <>
            "`:capital`, `:initial_margin_ratio`, and optional `:margin_threshold` use canonical decimal strings " <>
            "and compute kill_switch_day; native Elixir callers may also pass Decimal or integer for exact fields."
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

  `negative_rate` is a decimal fraction per funding period (e.g. `-0.00025` for
  `-0.025%`), matching `Funding`/`Hedging` — not a percent number. Scale to daily
  cost with `periods_per_day`. Its default of 3 is an overridable cadence convention.
  `kill_switch_day`, when requested, rounds up because it identifies the first
  whole calendar day on which the threshold is crossed.
  """
  @spec stress_test_prolonged_negative(
          DecimalInput.input(),
          DecimalInput.input(),
          pos_integer(),
          keyword()
        ) ::
          stress_test_result()
  def stress_test_prolonged_negative(negative_rate, position_size, duration_days, opts \\ [])
      when is_integer(duration_days) and duration_days > 0 do
    negative_rate = DecimalInput.cast!(negative_rate)
    position_size = DecimalInput.cast!(position_size)
    periods_per_day = periods_per_day(opts)
    margin_threshold = margin_threshold(opts)

    daily_cost = negative_funding_daily_cost(negative_rate, position_size, periods_per_day)
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
          Keyword.get(opts, :initial_margin_ratio),
          margin_threshold
        )
    }
  end

  api(
    :check_kill_switch,
    "Evaluate daily-normalized negative funding plus high margin usage.",
    params: [
      per_period_funding_rate: [
        kind: :value,
        description:
          "Funding rate as a canonical decimal string representing a per-period fraction (e.g. \"-0.00022\" for -0.022%); native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      margin_ratio: [
        kind: :value,
        description:
          "Current margin usage ratio (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional positive-integer `:periods_per_day` plus `:daily_funding_threshold` and `:margin_threshold` " <>
            "as canonical decimal strings. Native Elixir callers may also pass Decimal or integer for exact fields; " <>
            "defaults are overridable risk conventions."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with per-period and daily funding rates, cadence, thresholds, margin ratio, " <>
          "and kill_switch_triggered."
    }
  )

  @doc """
  Return kill-switch status after normalizing per-period funding to a daily fraction.

  The comparison is `per_period_funding_rate * periods_per_day < daily_funding_threshold`.
  The default cadence of 3, daily threshold of `-0.0006`, and margin threshold of
  `0.25` are conventions; each is overridable through `opts`.
  """
  @spec check_kill_switch(DecimalInput.input(), DecimalInput.input(), keyword()) ::
          kill_switch_result()
  def check_kill_switch(per_period_funding_rate, margin_ratio, opts \\ []) do
    per_period_funding_rate = DecimalInput.cast!(per_period_funding_rate)
    margin_ratio = DecimalInput.cast!(margin_ratio)
    periods_per_day = periods_per_day(opts)
    daily_funding_rate = Decimal.mult(per_period_funding_rate, periods_per_day)
    daily_funding_threshold = daily_funding_threshold(opts)
    margin_threshold = margin_threshold(opts)

    kill_switch_triggered =
      Decimal.compare(daily_funding_rate, daily_funding_threshold) == :lt and
        Decimal.compare(margin_ratio, margin_threshold) == :gt

    %{
      per_period_funding_rate: per_period_funding_rate,
      periods_per_day: periods_per_day,
      daily_funding_rate: daily_funding_rate,
      margin_ratio: margin_ratio,
      daily_funding_threshold: daily_funding_threshold,
      margin_threshold: margin_threshold,
      kill_switch_triggered: kill_switch_triggered
    }
  end

  defp payoff_days(remaining_debt, daily_funding) do
    case Decimal.compare(daily_funding, @zero) do
      :gt ->
        remaining_debt
        |> Decimal.div(daily_funding)

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

  defp periods_per_day(opts) do
    opts
    |> Keyword.get(:periods_per_day, @default_periods_per_day)
    |> DecimalInput.cast!()
  end

  defp daily_funding_threshold(opts) do
    opts
    |> Keyword.get(:daily_funding_threshold, @default_kill_switch_daily_funding_threshold)
    |> DecimalInput.cast!()
  end

  defp margin_threshold(opts) do
    opts
    |> Keyword.get(:margin_threshold, @default_kill_switch_margin_threshold)
    |> DecimalInput.cast!()
  end

  defp negative_funding_daily_cost(negative_rate, position_size, periods_per_day) do
    # Fraction unit: abs(rate) * position * periods_per_day (no /100).
    negative_rate
    |> Decimal.abs()
    |> Decimal.mult(position_size)
    |> Decimal.mult(periods_per_day)
  end

  defp kill_switch_day(_daily_cost, capital, initial_margin_ratio, _margin_threshold)
       when is_nil(capital) or is_nil(initial_margin_ratio),
       do: nil

  defp kill_switch_day(daily_cost, capital, initial_margin_ratio, margin_threshold) do
    capital = DecimalInput.cast!(capital)
    initial_margin_ratio = DecimalInput.cast!(initial_margin_ratio)

    margin_headroom =
      margin_threshold
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
end
