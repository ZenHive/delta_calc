defmodule DeltaCalc.Hedging do
  @moduledoc """
  Pure spot-hedging formulas for portfolio balance and coverage calculations.

  All functions take plain `Decimal` values — no Ecto, Repo, Scope, or Snapshot struct
  coupling. Callers fetch values from their own storage and pass them in.
  """

  use Descripex, namespace: "/hedging"

  @typedoc "Snapshot values map required by change functions."
  @type snapshot_values :: %{
          total_spot: Decimal.t(),
          cex_spot: Decimal.t(),
          cold_wallet: Decimal.t(),
          hedge_coverage_pct: Decimal.t(),
          captured_at: DateTime.t()
        }

  @typedoc "Absolute change between two snapshots."
  @type change_result :: %{
          total_change: Decimal.t(),
          cex_change: Decimal.t(),
          cold_change: Decimal.t(),
          hedge_change: Decimal.t(),
          duration_hours: float()
        }

  @typedoc "Percentage change between two snapshots."
  @type pct_change_result :: %{
          total_pct: Decimal.t(),
          cex_pct: Decimal.t(),
          cold_pct: Decimal.t(),
          hedge_pct: Decimal.t(),
          duration_hours: float()
        }

  @typedoc "Inputs for hedge requirement calculation."
  @type hedge_inputs :: %{
          required(:cex_spot) => Decimal.t(),
          required(:target_hedge_percent) => Decimal.t()
        }

  @typedoc "Hedge requirement result with CEX sufficiency flags."
  @type hedge_requirements :: %{
          required_hedge: Decimal.t(),
          required_cex_balance: Decimal.t(),
          effective_target_percent: Decimal.t(),
          capped_at_max: boolean(),
          cex_sufficient: boolean(),
          needs_transfer: boolean()
        }

  @typedoc "Spot vs perpetual basis spread."
  @type basis_spread :: %{
          spread: Decimal.t(),
          spread_pct: Decimal.t(),
          direction: :contango | :backwardation | :flat
        }

  @typedoc "Per-exchange hedge allocation suggestion."
  @type hedge_distribution :: %{
          allocations: %{atom() => Decimal.t()},
          notes: [String.t()]
        }

  @max_portfolio_hedge_percent Decimal.new(100)
  @coverage_110_percent Decimal.new(110)
  @default_max_per_exchange Decimal.new("0.8")

  api(
    :calculate_required_cex_balance,
    "Compute the CEX balance required to hedge a given percentage of spot holdings.",
    params: [
      total_spot: [
        kind: :value,
        description: "Total spot portfolio value in USD.",
        schema: float()
      ],
      hedge_percent: [
        kind: :value,
        description: "Target hedge percentage (e.g. 60 for 60%).",
        schema: float()
      ]
    ],
    returns: %{type: :float, description: "Required CEX balance in USD as a Decimal."}
  )

  @doc "Return the CEX balance needed to cover `hedge_percent` of `total_spot`."
  @spec calculate_required_cex_balance(Decimal.t(), Decimal.t()) :: Decimal.t()
  def calculate_required_cex_balance(total_spot, hedge_percent) do
    Decimal.mult(total_spot, Decimal.div(hedge_percent, Decimal.new(100)))
  end

  api(
    :check_hedge_coverage,
    "Determine whether current CEX holdings meet the target hedge percentage.",
    params: [
      cex_value: [
        kind: :value,
        description: "Current CEX spot value in USD.",
        schema: float()
      ],
      total_spot: [
        kind: :value,
        description: "Total spot portfolio value in USD.",
        schema: float()
      ],
      target_hedge_percent: [
        kind: :value,
        description: "Target hedge percentage (e.g. 60 for 60%).",
        schema: float()
      ]
    ],
    returns: %{
      type: :tagged_tuple,
      description:
        "{:ok, coverage_percent} when coverage meets target; " <>
          "{:needs_rebalancing, current_percent, target_percent} otherwise."
    }
  )

  @doc "Return `:ok` with coverage percentage, or `:needs_rebalancing` when below target."
  @spec check_hedge_coverage(Decimal.t(), Decimal.t(), Decimal.t()) ::
          {:ok, Decimal.t()} | {:needs_rebalancing, Decimal.t(), Decimal.t()}
  def check_hedge_coverage(cex_value, total_spot, target_hedge_percent) do
    coverage_percent =
      if Decimal.compare(total_spot, Decimal.new(0)) == :gt do
        cex_value
        |> Decimal.div(total_spot)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(2)
      else
        Decimal.new(0)
      end

    if Decimal.compare(coverage_percent, target_hedge_percent) == :lt do
      {:needs_rebalancing, coverage_percent, target_hedge_percent}
    else
      {:ok, coverage_percent}
    end
  end

  api(
    :needs_rebalancing?,
    "Check whether current hedge coverage falls below the target threshold.",
    params: [
      hedge_coverage_pct: [
        kind: :value,
        description: "Current hedge coverage percentage (0–100).",
        schema: float()
      ],
      target_hedge_percent: [
        kind: :value,
        description: "Target hedge percentage; defaults to 60.",
        schema: float()
      ]
    ],
    returns: %{type: :boolean, description: "true if coverage is below the target."}
  )

  @doc "Return `true` when `hedge_coverage_pct` is below `target_hedge_percent`."
  @spec needs_rebalancing?(Decimal.t(), Decimal.t()) :: boolean()
  def needs_rebalancing?(hedge_coverage_pct, target_hedge_percent \\ Decimal.new(60)) do
    Decimal.compare(hedge_coverage_pct, target_hedge_percent) == :lt
  end

  api(
    :calculate_change,
    "Compute absolute changes in spot, CEX, cold wallet, and hedge coverage between two snapshots.",
    params: [
      prior: [
        kind: :value,
        description:
          "Prior snapshot map with keys: total_spot, cex_spot, cold_wallet, hedge_coverage_pct, captured_at.",
        schema: map()
      ],
      current: [
        kind: :value,
        description: "Current snapshot map with the same keys.",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :total_change, :cex_change, :cold_change, :hedge_change (Decimal each) and :duration_hours (float)."
    }
  )

  @doc "Return absolute Decimal deltas and elapsed hours between `prior` and `current` snapshots."
  @spec calculate_change(snapshot_values(), snapshot_values()) :: change_result()
  def calculate_change(prior, current) do
    %{
      total_change: Decimal.sub(current.total_spot, prior.total_spot),
      cex_change: Decimal.sub(current.cex_spot, prior.cex_spot),
      cold_change: Decimal.sub(current.cold_wallet, prior.cold_wallet),
      hedge_change: Decimal.sub(current.hedge_coverage_pct, prior.hedge_coverage_pct),
      duration_hours: DateTime.diff(current.captured_at, prior.captured_at) / 3600
    }
  end

  api(
    :calculate_percentage_change,
    "Compute percentage changes in spot, CEX, cold wallet, and hedge coverage between two snapshots.",
    params: [
      prior: [
        kind: :value,
        description: "Prior snapshot map (same shape as calculate_change/2).",
        schema: map()
      ],
      current: [
        kind: :value,
        description: "Current snapshot map (same shape as calculate_change/2).",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :total_pct, :cex_pct, :cold_pct, :hedge_pct (Decimal each) and :duration_hours (float). " <>
          "Zero-value prior fields produce 0 to avoid division by zero."
    }
  )

  @doc "Return percentage Decimal deltas and elapsed hours between `prior` and `current` snapshots."
  @spec calculate_percentage_change(snapshot_values(), snapshot_values()) :: pct_change_result()
  def calculate_percentage_change(prior, current) do
    %{
      total_pct: pct(prior.total_spot, current.total_spot),
      cex_pct: pct(prior.cex_spot, current.cex_spot),
      cold_pct: pct(prior.cold_wallet, current.cold_wallet),
      hedge_pct: pct(prior.hedge_coverage_pct, current.hedge_coverage_pct),
      duration_hours: DateTime.diff(current.captured_at, prior.captured_at) / 3600
    }
  end

  api(
    :calculate_hedge_requirements,
    "Compute required hedge and CEX balance for a target coverage percentage.",
    params: [
      total_spot: [
        kind: :value,
        description: "Total spot portfolio value in USD (CEX + cold wallet).",
        schema: float()
      ],
      inputs: [
        kind: :value,
        description: "Map with :cex_spot and :target_hedge_percent keys.",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :required_hedge, :required_cex_balance, :effective_target_percent, " <>
          ":capped_at_max, :cex_sufficient, and :needs_transfer."
    }
  )

  @doc "Return hedge and CEX requirements for `total_spot` at the given target percentage."
  @spec calculate_hedge_requirements(Decimal.t(), hedge_inputs()) :: hedge_requirements()
  def calculate_hedge_requirements(total_spot, %{cex_spot: cex_spot, target_hedge_percent: target}) do
    {effective_target, capped?} = cap_target_percent(target)

    required_hedge =
      enforce_max_hedge(total_spot, hedge_for_percent(total_spot, effective_target))

    required_cex = required_hedge
    sufficient? = cex_sufficient?(cex_spot, required_cex)

    %{
      required_hedge: required_hedge,
      required_cex_balance: required_cex,
      effective_target_percent: effective_target,
      capped_at_max: capped?,
      cex_sufficient: sufficient?,
      needs_transfer: needs_cex_transfer?(cex_spot, required_cex)
    }
  end

  api(
    :calculate_funding_cost,
    "Estimate daily funding cost for a perpetual position.",
    params: [
      position_size: [
        kind: :value,
        description: "Absolute position notional in USD.",
        schema: float()
      ],
      funding_rate: [
        kind: :value,
        description: "Per-period funding rate as a decimal (e.g. 0.0001 for 0.01%).",
        schema: float()
      ],
      periods_per_day: [
        kind: :value,
        description: "Funding periods per day (3 for standard 8-hour funding).",
        schema: integer()
      ]
    ],
    returns: %{type: :float, description: "Estimated daily funding cost as a Decimal."}
  )

  @doc "Return estimated daily funding cost from per-period rate and settlement frequency."
  @spec calculate_funding_cost(Decimal.t(), Decimal.t(), pos_integer()) :: Decimal.t()
  def calculate_funding_cost(position_size, funding_rate, periods_per_day)
      when is_integer(periods_per_day) and periods_per_day > 0 do
    position_size
    |> Decimal.mult(funding_rate)
    |> Decimal.mult(Decimal.new(periods_per_day))
    |> Decimal.round(8)
  end

  api(
    :needs_cex_transfer?,
    "Check whether CEX spot balance is insufficient for the required hedge.",
    params: [
      cex_spot: [
        kind: :value,
        description: "Current CEX spot value in USD.",
        schema: float()
      ],
      required_cex_balance: [
        kind: :value,
        description: "Required CEX balance to support the target hedge.",
        schema: float()
      ]
    ],
    returns: %{type: :boolean, description: "true when CEX balance is below the requirement."}
  )

  @doc "Return `true` when `cex_spot` is below `required_cex_balance`."
  @spec needs_cex_transfer?(Decimal.t(), Decimal.t()) :: boolean()
  def needs_cex_transfer?(cex_spot, required_cex_balance) do
    not cex_sufficient?(cex_spot, required_cex_balance)
  end

  api(
    :get_basis_spread,
    "Calculate spot vs perpetual basis spread.",
    params: [
      spot_price: [
        kind: :value,
        description: "Spot market price.",
        schema: float()
      ],
      perp_price: [
        kind: :value,
        description: "Perpetual futures price.",
        schema: float()
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :spread (perp - spot), :spread_pct (percentage of spot), and :direction."
    }
  )

  @doc "Return absolute and percentage basis spread between spot and perpetual prices."
  @spec get_basis_spread(Decimal.t(), Decimal.t()) :: basis_spread()
  def get_basis_spread(spot_price, perp_price) do
    spread = Decimal.sub(perp_price, spot_price)

    spread_pct =
      if Decimal.compare(spot_price, Decimal.new(0)) == :gt do
        spread
        |> Decimal.div(spot_price)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.round(4)
      else
        Decimal.new(0)
      end

    direction =
      case Decimal.compare(spread, Decimal.new(0)) do
        :gt -> :contango
        :lt -> :backwardation
        :eq -> :flat
      end

    %{spread: spread, spread_pct: spread_pct, direction: direction}
  end

  api(
    :enforce_max_hedge,
    "Cap requested hedge at 1:1 of spot for portfolio margin safety.",
    params: [
      spot_value: [
        kind: :value,
        description: "Spot holdings value in USD.",
        schema: float()
      ],
      requested_hedge: [
        kind: :value,
        description: "Requested hedge notional in USD.",
        schema: float()
      ]
    ],
    returns: %{
      type: :float,
      description: "Hedge notional capped at spot value (never over-hedge)."
    }
  )

  @doc "Return `min(requested_hedge, spot_value)` so portfolio margin never exceeds 1:1."
  @spec enforce_max_hedge(Decimal.t(), Decimal.t()) :: Decimal.t()
  def enforce_max_hedge(spot_value, requested_hedge) do
    if Decimal.compare(requested_hedge, spot_value) == :gt do
      spot_value
    else
      requested_hedge
    end
  end

  api(
    :calculate_110_percent_hedge,
    "Compute hedge notional for 110% coverage of spot holdings.",
    params: [
      spot_value: [
        kind: :value,
        description: "Spot holdings value in USD.",
        schema: float()
      ]
    ],
    returns: %{
      type: :float,
      description: "Hedge notional sized to 110% of spot (portfolio margin buffer)."
    }
  )

  @doc "Return hedge notional sized to 110% of `spot_value`."
  @spec calculate_110_percent_hedge(Decimal.t()) :: Decimal.t()
  def calculate_110_percent_hedge(spot_value) do
    hedge_for_percent(spot_value, @coverage_110_percent)
  end

  api(
    :cex_sufficient?,
    "Check whether CEX spot balance meets the required hedge allocation.",
    params: [
      cex_spot: [
        kind: :value,
        description: "Current CEX spot value in USD.",
        schema: float()
      ],
      required_cex_balance: [
        kind: :value,
        description: "Required CEX balance to support the target hedge.",
        schema: float()
      ]
    ],
    returns: %{type: :boolean, description: "true when CEX balance meets or exceeds requirement."}
  )

  @doc "Return `true` when `cex_spot` is at least `required_cex_balance`."
  @spec cex_sufficient?(Decimal.t(), Decimal.t()) :: boolean()
  def cex_sufficient?(cex_spot, required_cex_balance) do
    Decimal.compare(cex_spot, required_cex_balance) != :lt
  end

  api(
    :suggest_hedge_distribution,
    "Split a hedge target across exchanges by capital efficiency.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :total_hedge_target, :available_exchanges, and optional :preferences " <>
            "(:deribit_priority, :max_per_exchange).",
        schema: map()
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with :allocations (exchange => signed hedge notional) and :notes."
    }
  )

  @doc "Suggest per-exchange hedge allocation favoring capital-efficient venues."
  @spec suggest_hedge_distribution(map()) :: hedge_distribution()
  def suggest_hedge_distribution(
        %{
          total_hedge_target: total_hedge_target,
          available_exchanges: available_exchanges
        } = params
      ) do
    preferences = Map.get(params, :preferences, %{})
    deribit_priority? = Map.get(preferences, :deribit_priority, false)
    max_per_exchange = Map.get(preferences, :max_per_exchange, @default_max_per_exchange)

    abs_target = Decimal.abs(total_hedge_target)

    if Decimal.compare(abs_target, Decimal.new(0)) == :eq do
      %{allocations: %{}, notes: []}
    else
      distribute_hedge_target(
        abs_target,
        hedge_sign(total_hedge_target),
        Decimal.mult(abs_target, max_per_exchange),
        available_exchanges,
        deribit_priority?
      )
    end
  end

  defp distribute_hedge_target(
         abs_target,
         sign,
         max_per_venue,
         available_exchanges,
         deribit_priority?
       ) do
    notes =
      if deribit_priority? and :deribit in available_exchanges do
        ["Deribit offers better capital efficiency for BTC/ETH"]
      else
        []
      end

    case available_exchanges do
      [single_exchange] ->
        %{allocations: %{single_exchange => apply_hedge_sign(abs_target, sign)}, notes: notes}

      _ ->
        distribute_across_exchanges(
          abs_target,
          sign,
          max_per_venue,
          available_exchanges,
          deribit_priority?,
          notes
        )
    end
  end

  defp distribute_across_exchanges(
         abs_target,
         sign,
         max_per_venue,
         available_exchanges,
         deribit_priority?,
         notes
       ) do
    {priority_alloc, remaining, other_exchanges} =
      if deribit_priority? and :deribit in available_exchanges do
        deribit_alloc = Decimal.min(max_per_venue, abs_target)
        others = List.delete(available_exchanges, :deribit)

        {%{deribit: apply_hedge_sign(deribit_alloc, sign)},
         Decimal.sub(abs_target, deribit_alloc), others}
      else
        {%{}, abs_target, available_exchanges}
      end

    overflow_alloc = split_remaining(remaining, other_exchanges, sign)

    %{
      allocations: Map.merge(priority_alloc, overflow_alloc),
      notes: notes
    }
  end

  defp pct(old_val, new_val) do
    if Decimal.compare(old_val, Decimal.new(0)) == :gt do
      new_val
      |> Decimal.sub(old_val)
      |> Decimal.div(old_val)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end

  defp cap_target_percent(target) do
    if Decimal.compare(target, @max_portfolio_hedge_percent) == :gt do
      {@max_portfolio_hedge_percent, true}
    else
      {target, false}
    end
  end

  defp hedge_for_percent(spot_value, percent) do
    calculate_required_cex_balance(spot_value, percent)
  end

  defp hedge_sign(value) do
    case Decimal.compare(value, Decimal.new(0)) do
      :lt -> -1
      _ -> 1
    end
  end

  defp apply_hedge_sign(amount, sign) when sign < 0, do: Decimal.negate(amount)
  defp apply_hedge_sign(amount, _sign), do: amount

  defp split_remaining(remaining, exchanges, sign) do
    case exchanges do
      [] ->
        %{}

      [exchange] ->
        %{exchange => apply_hedge_sign(remaining, sign)}

      exchanges ->
        count = length(exchanges)
        per_exchange = Decimal.div(remaining, Decimal.new(count))

        base_allocations =
          Map.new(exchanges, fn exchange ->
            {exchange, apply_hedge_sign(per_exchange, sign)}
          end)

        allocated =
          per_exchange
          |> Decimal.mult(Decimal.new(count))
          |> Decimal.sub(remaining)
          |> Decimal.abs()

        if Decimal.compare(allocated, Decimal.new(0)) == :eq do
          base_allocations
        else
          [first | _] = exchanges

          Map.update!(
            base_allocations,
            first,
            &Decimal.add(&1, apply_hedge_sign(allocated, sign))
          )
        end
    end
  end
end
