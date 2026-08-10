defmodule DeltaCalc.AccountMetrics do
  @moduledoc """
  Per-account liquidation, leverage, and margin-usage metrics.

  This module is pure calculation glue around `DeltaCalc.Leverage`, `DeltaCalc.Liquidation`,
  and `DeltaCalc.Safety`; callers own account isolation, alert thresholds, exchange state,
  and persistence.
  """

  use Descripex, namespace: "/account_metrics"

  alias DeltaCalc.Calc

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  @typedoc "Position side for account liquidation calculations."
  @type side :: :long | :short

  @typedoc "Per-account inputs required for risk metric calculation."
  @type account :: %{
          entry_price: Decimal.t(),
          notional: Decimal.t(),
          equity: Decimal.t(),
          margin_used: Decimal.t(),
          mmr_total: Decimal.t(),
          side: side(),
          swan_pct: Decimal.t()
        }

  @typedoc "Calculated account risk metrics."
  @type metrics :: %{
          effective_leverage: Decimal.t(),
          liquidation_price: Decimal.t(),
          liquidation_distance_pct: Decimal.t(),
          margin_usage_pct: Decimal.t(),
          safety: map()
        }

  api(
    :calculate,
    "Calculate per-account liquidation, leverage, margin usage, and safety metrics.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :entry_price, :notional, :equity, :margin_used, :mmr_total, :side, and :swan_pct. " <>
            "Exact fields use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          entry_price: String.t(),
          notional: String.t(),
          equity: String.t(),
          margin_used: String.t(),
          mmr_total: String.t(),
          side: :long | :short,
          swan_pct: String.t()
        }
      ],
      opts: [
        kind: :value,
        default: %{},
        description:
          "Optional map with :safety_cfg passed to DeltaCalc.Calc.safety/5. " <>
            "Exact multiplier fields use canonical decimal strings; native Elixir callers may also pass Decimal or integer.",
        schema: %{
          optional(:safety_cfg) => %{
            optional(:threshold_multiplier) => String.t(),
            optional(:safe_multiplier) => String.t()
          }
        }
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with effective_leverage, liquidation_price, liquidation_distance_pct, margin_usage_pct, and safety, or {:error, reason}."
    }
  )

  @doc """
  Return account-level risk metrics for one isolated account.

  `:safety_cfg` in `opts` is passed through to `DeltaCalc.Safety.safety/5`.
  """
  @spec calculate(account(), map()) :: metrics() | {:error, atom()}
  def calculate(account, opts \\ %{}) do
    with %Decimal{} = effective_leverage <-
           Calc.effective_leverage(account.notional, account.equity),
         %Decimal{} = liquidation_price <-
           Calc.liquidation(
             account.entry_price,
             effective_leverage,
             account.mmr_total,
             account.side
           ),
         %{} = safety <-
           Calc.safety(
             liquidation_price,
             account.entry_price,
             account.swan_pct,
             account.side,
             Map.get(opts, :safety_cfg, %{})
           ) do
      %{
        effective_leverage: effective_leverage,
        liquidation_price: liquidation_price,
        liquidation_distance_pct: safety.distance_to_liq_pct,
        margin_usage_pct: margin_usage_pct(account.margin_used, account.equity),
        safety: safety
      }
    end
  end

  api(:margin_usage_pct, "Calculate margin used as a percentage of account equity.",
    params: [
      margin_used: [
        kind: :value,
        description:
          "Margin currently used by the account as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      equity: [
        kind: :value,
        description:
          "Current account equity as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Margin usage percentage at Decimal context precision."
    }
  )

  @doc "Return `margin_used / equity * 100`, or zero when equity is not positive."
  @spec margin_usage_pct(Decimal.t(), Decimal.t()) :: Decimal.t()
  def margin_usage_pct(margin_used, equity) do
    if Decimal.compare(equity, @zero) == :gt do
      margin_used
      |> Decimal.abs()
      |> Decimal.div(equity)
      |> Decimal.mult(@hundred)
    else
      @zero
    end
  end
end
