defmodule DeltaCalc.OptionsRisk do
  @moduledoc """
  Long-option risk framing and margin-bridge funding stress for option buyers.

  Long options have defined max loss equal to premium paid. Combined with perp-funded
  margin bridges, cash-flow risk from negative funding dominates — price risk is hedged.
  """

  use Descripex, namespace: "/options_risk"

  alias DeltaCalc.MarginBridge

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)
  @default_duration_days 90
  @default_warning_threshold Decimal.new("0.25")
  @default_reduce_threshold Decimal.new("0.35")
  @default_critical_threshold Decimal.new("0.45")
  @default_margin_impact_denominator Decimal.new("0.75")

  @type health_status :: :healthy | :warning | :critical

  @type max_loss_result :: %{
          max_loss: Decimal.t(),
          risk_model: :premium_only,
          limited_downside: true
        }

  @type exposure_result :: %{
          spot_notional: Decimal.t(),
          perp_notional: Decimal.t(),
          options_notional: Decimal.t(),
          margin_debt: Decimal.t(),
          total_exposure: Decimal.t()
        }

  @type negative_funding_impact :: %{
          daily_cost: Decimal.t(),
          capital_at_risk: boolean(),
          cash_flow_risk: boolean(),
          market_setup: :bullish | :neutral | :bearish,
          opportunity: :high | :moderate | :low
        }

  @type stress_scenario :: %{
          rate: Decimal.t(),
          daily: Decimal.t(),
          total_90d: Decimal.t(),
          margin_impact: String.t()
        }

  @type extended_stress_result :: %{
          scenario: atom(),
          scenarios: [stress_scenario()],
          kill_switch_trigger: String.t(),
          recommendation: String.t()
        }

  @type margin_health :: %{
          margin_ratio: Decimal.t(),
          runway_days: Decimal.t() | nil,
          health_status: health_status()
        }

  api(
    :max_loss,
    "Return defined max loss for long options (premium paid only).",
    params: [
      option_premiums: [
        kind: :value,
        description: "Single premium or list of long-option premiums paid.",
        schema: float()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with max_loss (sum of premiums), risk_model :premium_only, limited_downside true."
    }
  )

  @doc """
  Frame long-option risk as premium-only max loss.

  Accepts one premium or a list; returns the summed premium as `max_loss`.
  """
  @spec max_loss(Decimal.t() | number() | String.t() | [Decimal.t() | number() | String.t()]) ::
          max_loss_result()
  def max_loss(option_premiums) when is_list(option_premiums) do
    total =
      option_premiums
      |> Enum.map(&to_decimal/1)
      |> Enum.reduce(@zero, &Decimal.add/2)

    %{
      max_loss: total,
      risk_model: :premium_only,
      limited_downside: true
    }
  end

  def max_loss(option_premium) do
    max_loss([option_premium])
  end

  api(
    :calculate_total_exposure,
    "Sum gross exposure across spot, perp, options, and margin debt legs.",
    params: [
      legs: [
        kind: :value,
        description:
          "Map with :spot_notional, :perp_notional, :options_notional, and :margin_debt."
      ]
    ],
    returns: %{
      type: :map,
      description: "Per-leg notionals plus total_exposure (sum of absolute leg values)."
    }
  )

  @doc "Return per-leg notionals and `total_exposure` as the sum of absolute leg values."
  @spec calculate_total_exposure(map()) :: exposure_result()
  def calculate_total_exposure(legs) do
    spot = legs |> Map.fetch!(:spot_notional) |> to_decimal() |> Decimal.abs()
    perp = legs |> Map.fetch!(:perp_notional) |> to_decimal() |> Decimal.abs()
    options = legs |> Map.fetch!(:options_notional) |> to_decimal() |> Decimal.abs()
    margin_debt = legs |> Map.fetch!(:margin_debt) |> to_decimal() |> Decimal.abs()

    total =
      [spot, perp, options, margin_debt]
      |> Enum.reduce(@zero, &Decimal.add/2)

    %{
      spot_notional: spot,
      perp_notional: perp,
      options_notional: options,
      margin_debt: margin_debt,
      total_exposure: total
    }
  end

  api(
    :calculate_negative_funding_impact,
    "Estimate daily funding drain and cash-flow risk under negative rates.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :negative_rate, :position_size, optional :market_context and :capital_protected."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with daily_cost, capital_at_risk, cash_flow_risk, market_setup, and opportunity."
    }
  )

  @doc """
  Compute negative-funding cash-flow impact for a delta-neutral margin bridge.

  `:capital_protected` defaults to true (price risk hedged). `:market_context` adjusts
  qualitative setup/opportunity fields (`:post_crash`, `:bear_market`, etc.).
  """
  @spec calculate_negative_funding_impact(map()) :: negative_funding_impact()
  def calculate_negative_funding_impact(params) do
    negative_rate = params |> Map.fetch!(:negative_rate) |> to_decimal()
    position_size = params |> Map.fetch!(:position_size) |> to_decimal()
    capital_protected = Map.get(params, :capital_protected, true)
    market_context = Map.get(params, :market_context, :neutral)

    daily_cost =
      MarginBridge.stress_test_prolonged_negative(negative_rate, position_size, 1).daily_cost

    {market_setup, opportunity} = market_context_signals(market_context)

    %{
      daily_cost: daily_cost,
      capital_at_risk: not capital_protected,
      cash_flow_risk: Decimal.compare(daily_cost, @zero) == :gt,
      market_setup: market_setup,
      opportunity: opportunity
    }
  end

  api(
    :stress_test_extended_negative,
    "Stress-test multiple negative funding rates over an extended horizon.",
    params: [
      params: [
        kind: :value,
        description: "Map with :funding_rates list, :position_size, optional :scenario atom."
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional :capital, :initial_margin_ratio, :duration_days (default 90), :margin_threshold."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with scenario, per-rate rows (rate, daily, total_90d, margin_impact), " <>
          "kill_switch_trigger, and recommendation."
    }
  )

  @doc """
  Run extended negative-funding scenarios (default 90 days) across multiple rates.

  `margin_impact` expresses funding drain as extra margin pressure relative to free
  capital headroom below the kill-switch threshold.
  """
  @spec stress_test_extended_negative(map(), keyword()) :: extended_stress_result()
  def stress_test_extended_negative(params, opts \\ []) do
    funding_rates = Map.fetch!(params, :funding_rates)
    position_size = params |> Map.fetch!(:position_size) |> to_decimal()
    scenario = Map.get(params, :scenario, :bear_market_90d)

    duration_days = Keyword.get(opts, :duration_days, @default_duration_days)
    capital = opts |> Keyword.get(:capital, position_size) |> to_decimal()
    initial_margin_ratio = Keyword.get(opts, :initial_margin_ratio)
    margin_threshold = margin_threshold(opts)

    scenarios =
      Enum.map(funding_rates, fn rate ->
        rate = to_decimal(rate)

        result =
          MarginBridge.stress_test_prolonged_negative(
            rate,
            position_size,
            duration_days,
            capital: capital,
            initial_margin_ratio: initial_margin_ratio
          )

        %{
          rate: rate,
          daily: result.daily_cost,
          total_90d: result.total_cost,
          margin_impact: format_margin_impact(result.total_cost, capital, margin_threshold)
        }
      end)

    kill_switch_days =
      funding_rates
      |> Enum.map(fn rate ->
        MarginBridge.stress_test_prolonged_negative(
          rate,
          position_size,
          duration_days,
          capital: capital,
          initial_margin_ratio: initial_margin_ratio
        ).kill_switch_day
      end)
      |> Enum.reject(&is_nil/1)

    %{
      scenario: scenario,
      scenarios: scenarios,
      kill_switch_trigger: kill_switch_trigger(kill_switch_days),
      recommendation: "Maintain 5-10k cash buffer for extended negative funding"
    }
  end

  api(
    :monitor_margin_bridge_health,
    "Monitor margin-bridge health using margin ratio, runway, and status bands.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :initial_margin, :option_premium, :capital, :available_margin, :daily_burn."
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Optional :warning, :reduce, and :critical margin ratio thresholds."
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with margin_ratio, runway_days, and health_status."
    }
  )

  @doc """
  Evaluate margin-bridge health during the payback period.

  Delegates ratio and runway math to `DeltaCalc.MarginBridge`. Status bands default to
  phase7 thresholds: healthy ≤25%, warning ≤35%, critical above 35%.
  """
  @spec monitor_margin_bridge_health(map(), keyword()) :: margin_health()
  def monitor_margin_bridge_health(params, opts \\ []) do
    initial_margin = params |> Map.fetch!(:initial_margin) |> to_decimal()
    option_premium = params |> Map.fetch!(:option_premium) |> to_decimal()
    capital = params |> Map.fetch!(:capital) |> to_decimal()
    available_margin = params |> Map.fetch!(:available_margin) |> to_decimal()
    daily_burn = params |> Map.fetch!(:daily_burn) |> to_decimal()

    margin_ratio = MarginBridge.margin_ratio(initial_margin, option_premium, capital)
    runway_days = MarginBridge.margin_runway_days(available_margin, daily_burn)

    warning = opts |> Keyword.get(:warning, @default_warning_threshold) |> to_decimal()
    reduce = opts |> Keyword.get(:reduce, @default_reduce_threshold) |> to_decimal()
    critical = opts |> Keyword.get(:critical, @default_critical_threshold) |> to_decimal()

    %{
      margin_ratio: margin_ratio,
      runway_days: runway_days,
      health_status: health_status(margin_ratio, warning, reduce, critical)
    }
  end

  @spec market_context_signals(atom()) ::
          {:bullish | :neutral | :bearish, :high | :moderate | :low}
  defp market_context_signals(context)
       when context in [:post_crash, :bear_market, :negative_funding],
       do: {:bullish, :high}

  defp market_context_signals(:bull_market), do: {:bearish, :low}
  defp market_context_signals(_), do: {:neutral, :moderate}

  @spec format_margin_impact(Decimal.t(), Decimal.t(), Decimal.t()) :: String.t()
  defp format_margin_impact(total_cost, capital, margin_threshold) do
    headroom = Decimal.mult(capital, Decimal.sub(@one, margin_threshold))

    denominator =
      cond do
        Decimal.compare(headroom, @zero) == :gt ->
          headroom

        Decimal.compare(capital, @zero) == :gt ->
          Decimal.mult(capital, @default_margin_impact_denominator)

        true ->
          @one
      end

    impact_pct =
      total_cost
      |> Decimal.div(denominator)
      |> Decimal.mult(@hundred)
      |> Decimal.round(0)

    "+#{Decimal.to_string(impact_pct, :normal)}%"
  end

  @spec margin_threshold(keyword()) :: Decimal.t()
  defp margin_threshold(opts) do
    opts
    |> Keyword.get(:margin_threshold, @default_warning_threshold)
    |> to_decimal()
  end

  @spec kill_switch_trigger([pos_integer()]) :: String.t()
  defp kill_switch_trigger([]), do: "Not projected at current margin levels"

  defp kill_switch_trigger(days) do
    min_day = Enum.min(days)
    max_day = Enum.max(days)

    if min_day == max_day do
      "Day #{min_day}"
    else
      "Day #{min_day}-#{max_day} depending on rate"
    end
  end

  @spec health_status(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t()) :: health_status()
  defp health_status(margin_ratio, warning, reduce, _critical) do
    cond do
      Decimal.compare(margin_ratio, reduce) == :gt -> :critical
      Decimal.compare(margin_ratio, warning) == :gt -> :warning
      true -> :healthy
    end
  end

  # Shared coercion shape also lives in MarginBridge; keep module-local for now.
  # ex_dna:disable-for-lines:4
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
