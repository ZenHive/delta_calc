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
end
