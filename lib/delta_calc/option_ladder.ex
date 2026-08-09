defmodule DeltaCalc.OptionLadder do
  @moduledoc """
  Pure rolling option ladder calculations for perp-funded option strategies.

  This module keeps scheduling and execution outside DeltaCalc. Callers pass option
  chain snapshots, position state, funding receipts, and strategy preferences as
  plain values; the functions return deterministic decisions and Decimal amounts.
  """

  use Descripex, namespace: "/option_ladder"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new("0")
  @one Decimal.new("1")
  @hundred Decimal.new("100")
  @spread_close_only Decimal.new("0.15")
  @spread_partial_roll Decimal.new("0.10")
  @cheap_iv_percentile 40
  @expensive_iv_percentile 70
  @near_expiry_days 3
  @worthless_roll_days 7
  @winner_pnl_percent Decimal.new("200")
  @worthless_pnl_percent Decimal.new("-70")
  @default_liquidity_minimum Decimal.new("0.1")
  @default_max_spread Decimal.new("0.10")
  @default_strike_increment Decimal.new("500")
  @cheap_iv_multiplier Decimal.new("1.25")
  @normal_iv_multiplier Decimal.new("1.00")
  @expensive_iv_multiplier Decimal.new("0.60")
  @half Decimal.new("0.5")

  @expiry_buckets [
    %{bucket: :front, range: 3..10, target_days: 7, allocation: Decimal.new("0.50")},
    %{bucket: :middle, range: 10..20, target_days: 14, allocation: Decimal.new("0.30")},
    %{bucket: :back, range: 20..40, target_days: 30, allocation: Decimal.new("0.20")}
  ]

  @strike_profiles %{
    conservative: [Decimal.new("0.00"), Decimal.new("0.025"), Decimal.new("0.05")],
    balanced: [Decimal.new("0.05"), Decimal.new("0.10"), Decimal.new("0.15")],
    aggressive: [Decimal.new("0.15"), Decimal.new("0.225"), Decimal.new("0.30")],
    lottery: [Decimal.new("0.30"), Decimal.new("0.40"), Decimal.new("0.50")]
  }

  @type expiry :: %{
          expiry: String.t(),
          days_to_expiry: pos_integer(),
          liquidity: DecimalInput.input(),
          bid_ask_spread: DecimalInput.input()
        }

  @type expiry_bucket :: %{
          bucket: :front | :middle | :back,
          expiry: String.t(),
          days_to_expiry: pos_integer(),
          allocation: Decimal.t(),
          liquidity: Decimal.t(),
          bid_ask_spread: Decimal.t()
        }

  @type expiry_result :: %{
          buckets: [expiry_bucket()],
          total_allocation: Decimal.t()
        }

  @type roll_decision ::
          %{action: :roll, target: :next_weekly}
          | %{action: :close_only, reason: String.t()}
          | %{action: :partial_roll, take_profit: Decimal.t(), roll_up: Decimal.t()}
          | %{action: :roll_to_atm}
          | %{action: :hold}

  @type strike_result :: %{
          risk_profile: atom(),
          option_type: :call | :put,
          spot_price: Decimal.t(),
          iv_adjustment: size_result(),
          strikes: [map()]
        }

  @type funding_result :: %{
          funding_received: Decimal.t(),
          positions_to_roll: non_neg_integer(),
          roll_cost: Decimal.t(),
          spread_cost: Decimal.t(),
          total_cost: Decimal.t(),
          excess_funding: Decimal.t(),
          margin_used: Decimal.t(),
          status: :executed | :skipped | :deferred,
          reason: atom() | nil
        }

  @type size_result :: %{
          base_size: Decimal.t(),
          adjusted_size: Decimal.t(),
          multiplier: Decimal.t(),
          action: :increase_size | :normal_size | :reduce_size,
          reason: String.t()
        }

  api(
    :optimal_expiries,
    "Select liquid expiries across front, middle, and back buckets and normalize allocations.",
    params: [
      expiries: [
        kind: :value,
        description:
          "List of expiry maps with :expiry, positive-integer :days_to_expiry, and :liquidity and :bid_ask_spread as canonical decimal strings; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: [
          %{
            expiry: String.t(),
            days_to_expiry: pos_integer(),
            liquidity: String.t(),
            bid_ask_spread: String.t()
          }
        ]
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional :liquidity_minimum and :max_spread_percent as canonical decimal strings; native Elixir callers may also pass Decimal or integer. Spread accepts ratio or percent."
      ]
    ],
    returns: %{type: :map, description: "Map with selected buckets and total allocation."}
  )

  @doc "Return selected expiry buckets with normalized allocation percentages."
  @spec optimal_expiries([expiry()], keyword()) :: expiry_result()
  def optimal_expiries(expiries, opts \\ []) do
    liquid_expiries = liquid_expiries(expiries, opts)

    buckets =
      @expiry_buckets
      |> Enum.map(&select_bucket(liquid_expiries, &1))
      |> Enum.reject(&is_nil/1)
      |> normalize_allocations()

    %{
      buckets: buckets,
      total_allocation: sum_allocations(buckets)
    }
  end

  api(
    :check_roll_conditions,
    "Evaluate phase 7 rolling rules from days to expiry, PnL percent, momentum, and spread.",
    params: [
      position: [
        kind: :value,
        description:
          "Position map with positive-integer :days_to_expiry plus :pnl_percent and :bid_ask_spread as canonical decimal strings; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          days_to_expiry: pos_integer(),
          pnl_percent: String.t(),
          bid_ask_spread: String.t()
        }
      ],
      market: [
        kind: :value,
        description: "Market map with :momentum, e.g. :strong_up.",
        schema: %{momentum: atom()}
      ]
    ],
    returns: %{type: :map, description: "Decision map with :action and optional roll details."}
  )

  @doc "Return the roll action for a single option position."
  @spec check_roll_conditions(map(), map()) :: roll_decision()
  def check_roll_conditions(position, market) do
    days = position.days_to_expiry
    pnl = DecimalInput.cast!(position.pnl_percent)
    spread = to_spread_ratio(position.bid_ask_spread)
    momentum = Map.get(market, :momentum)

    near_expiry_decision(days, spread) ||
      winner_decision(pnl, momentum, spread) ||
      worthless_decision(days, pnl) ||
      %{action: :hold}
  end

  api(
    :select_strikes,
    "Build a strike ladder from spot price, IV percentile, risk profile, and option type.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :spot_price as a canonical decimal string, integer :iv_percentile, and :risk_profile; native Elixir callers may also pass Decimal or integer for the exact price.",
        schema: %{
          spot_price: String.t(),
          iv_percentile: integer(),
          risk_profile: :conservative | :balanced | :aggressive | :lottery
        }
      ],
      opts: [
        kind: :value,
        default: [],
        description:
          "Optional :option_type (:call or :put) and :strike_increment as a canonical decimal string; native Elixir callers may also pass Decimal or integer for the exact increment."
      ]
    ],
    returns: %{type: :map, description: "Map with selected strikes and IV size adjustment."}
  )

  @doc "Return an IV-aware strike ladder for the requested risk profile."
  @spec select_strikes(map(), keyword()) :: strike_result()
  def select_strikes(params, opts \\ []) do
    spot_price = DecimalInput.cast!(params.spot_price)
    risk_profile = params.risk_profile
    option_type = Keyword.get(opts, :option_type, :call)

    increment =
      opts
      |> Keyword.get(:strike_increment, @default_strike_increment)
      |> DecimalInput.cast!()

    iv_adjustment = iv_adjusted_size(@one, iv_percentile: params.iv_percentile)

    strikes =
      risk_profile
      |> profile_steps()
      |> Enum.map(&build_strike(spot_price, &1, option_type, increment))

    %{
      risk_profile: risk_profile,
      option_type: option_type,
      spot_price: spot_price,
      iv_adjustment: iv_adjustment,
      strikes: strikes
    }
  end

  api(
    :sync_with_funding,
    "Compare funding income with roll and spread costs to decide whether a roll can execute.",
    params: [
      roll: [
        kind: :value,
        description:
          "Map with :funding_received, :roll_cost, and :spread_cost as canonical decimal strings plus non-negative-integer :positions_to_roll; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          funding_received: String.t(),
          positions_to_roll: non_neg_integer(),
          roll_cost: String.t(),
          spread_cost: String.t()
        }
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Optional :spread_check (default true) and :use_margin."
      ]
    ],
    returns: %{type: :map, description: "Funding-synchronized roll decision and cost fields."}
  )

  @doc "Return whether funding covers the roll, whether margin is used, or whether to skip/defer."
  @spec sync_with_funding(map(), keyword()) :: funding_result()
  def sync_with_funding(roll, opts \\ []) do
    funding_received = DecimalInput.cast!(roll.funding_received)
    roll_cost = DecimalInput.cast!(roll.roll_cost)
    spread_cost = DecimalInput.cast!(roll.spread_cost)
    total_cost = Decimal.add(roll_cost, spread_cost)

    funding_result(
      %{
        funding_received: funding_received,
        positions_to_roll: roll.positions_to_roll,
        roll_cost: roll_cost,
        spread_cost: spread_cost,
        total_cost: total_cost
      },
      opts
    )
  end

  api(
    :iv_adjusted_size,
    "Adjust position size from IV percentile: increase below 40, reduce above 70, otherwise unchanged.",
    params: [
      base_size: [
        kind: :value,
        description:
          "Base option budget or notional size as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      opts: [
        kind: :value,
        default: [],
        description: "Required :iv_percentile plus optional threshold overrides."
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with base size, adjusted size, multiplier, and action."
    }
  )

  @doc "Return the IV-adjusted position size and action."
  @spec iv_adjusted_size(DecimalInput.input(), keyword()) :: size_result()
  def iv_adjusted_size(base_size, opts \\ []) do
    base_size = DecimalInput.cast!(base_size)
    iv_percentile = Keyword.fetch!(opts, :iv_percentile)
    {action, multiplier, reason} = size_adjustment(iv_percentile)

    %{
      base_size: base_size,
      adjusted_size: base_size |> Decimal.mult(multiplier) |> Decimal.round(2),
      multiplier: multiplier,
      action: action,
      reason: reason
    }
  end

  defp liquid_expiries(expiries, opts) do
    liquidity_minimum =
      opts
      |> Keyword.get(:liquidity_minimum, @default_liquidity_minimum)
      |> DecimalInput.cast!()

    max_spread =
      opts
      |> Keyword.get(:max_spread_percent, @default_max_spread)
      |> to_spread_ratio()

    Enum.filter(expiries, fn expiry ->
      gte?(DecimalInput.cast!(expiry.liquidity), liquidity_minimum) and
        lte?(to_spread_ratio(expiry.bid_ask_spread), max_spread)
    end)
  end

  defp select_bucket(expiries, bucket) do
    expiries
    |> Enum.filter(&(&1.days_to_expiry in bucket.range))
    |> Enum.min_by(&abs(&1.days_to_expiry - bucket.target_days), fn -> nil end)
    |> bucket_result(bucket)
  end

  defp bucket_result(nil, _bucket), do: nil

  defp bucket_result(expiry, bucket) do
    %{
      bucket: bucket.bucket,
      expiry: expiry.expiry,
      days_to_expiry: expiry.days_to_expiry,
      allocation: bucket.allocation,
      liquidity: DecimalInput.cast!(expiry.liquidity),
      bid_ask_spread: to_spread_ratio(expiry.bid_ask_spread)
    }
  end

  defp normalize_allocations([]), do: []

  defp normalize_allocations(buckets) do
    base_total = Enum.reduce(buckets, @zero, &Decimal.add(&1.allocation, &2))

    Enum.map(buckets, fn bucket ->
      %{bucket | allocation: bucket.allocation |> Decimal.div(base_total) |> Decimal.round(4)}
    end)
  end

  defp sum_allocations(buckets) do
    Enum.reduce(buckets, @zero, &Decimal.add(&1.allocation, &2))
  end

  defp profile_steps(risk_profile) do
    Map.fetch!(@strike_profiles, risk_profile)
  end

  defp build_strike(spot_price, otm_pct, option_type, increment) do
    multiplier = strike_multiplier(otm_pct, option_type)
    strike = spot_price |> Decimal.mult(multiplier) |> round_to_increment(increment)

    %{
      strike: strike,
      otm_percent: Decimal.mult(otm_pct, @hundred),
      option_type: option_type
    }
  end

  defp strike_multiplier(otm_pct, :call), do: Decimal.add(@one, otm_pct)
  defp strike_multiplier(otm_pct, :put), do: Decimal.sub(@one, otm_pct)

  defp near_expiry_decision(days, spread) when days <= @near_expiry_days do
    if lt?(spread, @spread_close_only) do
      %{action: :roll, target: :next_weekly}
    else
      %{action: :close_only, reason: "Spread exceeds 15%"}
    end
  end

  defp near_expiry_decision(_days, _spread), do: nil

  defp winner_decision(pnl, :strong_up, spread) do
    if gt?(pnl, @winner_pnl_percent) and lt?(spread, @spread_partial_roll) do
      %{action: :partial_roll, take_profit: @half, roll_up: @half}
    end
  end

  defp winner_decision(_pnl, _momentum, _spread), do: nil

  defp worthless_decision(days, pnl) when days < @worthless_roll_days do
    if lt?(pnl, @worthless_pnl_percent), do: %{action: :roll_to_atm}
  end

  defp worthless_decision(_days, _pnl), do: nil

  defp funding_result(costs, opts) do
    spread_check? = Keyword.get(opts, :spread_check, true)
    use_margin? = Keyword.get(opts, :use_margin, false)

    cond do
      spread_check? and gt?(costs.spread_cost, costs.funding_received) ->
        Map.merge(costs, %{
          status: :skipped,
          reason: :spread_exceeds_funding,
          excess_funding: costs.funding_received,
          margin_used: @zero
        })

      gte?(costs.funding_received, costs.total_cost) ->
        Map.merge(costs, %{
          status: :executed,
          reason: nil,
          excess_funding: Decimal.sub(costs.funding_received, costs.total_cost),
          margin_used: @zero
        })

      use_margin? ->
        Map.merge(costs, %{
          status: :executed,
          reason: nil,
          excess_funding: @zero,
          margin_used: Decimal.sub(costs.total_cost, costs.funding_received)
        })

      true ->
        Map.merge(costs, %{
          status: :deferred,
          reason: :insufficient_funding,
          excess_funding: costs.funding_received,
          margin_used: @zero
        })
    end
  end

  defp size_adjustment(iv_percentile) when iv_percentile < @cheap_iv_percentile do
    {:increase_size, @cheap_iv_multiplier, "Vol cheap, buy more"}
  end

  defp size_adjustment(iv_percentile) when iv_percentile > @expensive_iv_percentile do
    {:reduce_size, @expensive_iv_multiplier, "Vol expensive, buy less"}
  end

  defp size_adjustment(_iv_percentile) do
    {:normal_size, @normal_iv_multiplier, "Vol normal, keep base size"}
  end

  defp round_to_increment(value, increment) do
    value
    |> Decimal.div(increment)
    |> Decimal.round(0)
    |> Decimal.mult(increment)
  end

  defp to_spread_ratio(value) do
    value = DecimalInput.cast!(value)

    if gt?(value, @one), do: Decimal.div(value, @hundred), else: value
  end

  defp lt?(left, right), do: Decimal.compare(left, right) == :lt
  defp lte?(left, right), do: Decimal.compare(left, right) in [:lt, :eq]
  defp gt?(left, right), do: Decimal.compare(left, right) == :gt
  defp gte?(left, right), do: Decimal.compare(left, right) in [:gt, :eq]
end
