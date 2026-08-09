defmodule DeltaCalc.Calc do
  @moduledoc false

  alias DeltaCalc.{Allocation, DCAPlanner, Leverage, Liquidation, Quantization, Safety}

  @type decimal_result :: Decimal.t() | {:error, atom()}
  @type safety_result :: map() | {:error, :non_positive_entry}
  @doc false
  @spec effective_leverage(Decimal.t(), Decimal.t()) :: decimal_result()
  defdelegate effective_leverage(notional, wallet_equity), to: Leverage

  @doc false
  @spec leverage_to_aum(Decimal.t(), Decimal.t()) :: decimal_result()
  defdelegate leverage_to_aum(notional, total_aum), to: Leverage

  @doc false
  @spec liquidation(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: decimal_result()
  defdelegate liquidation(entry, leff, mmr_total, side), to: Liquidation

  @doc false
  @spec allocate(Decimal.t(), map(), list(atom()), map(), Decimal.t()) :: map()
  defdelegate allocate(aum, mode_cfg, assets, weights, per_sub_cap_pct), to: Allocation

  @doc false
  @spec position(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: map()
  defdelegate position(sub_eq, init_margin_pct, ui_lev, entry, side), to: Leverage

  @doc false
  @spec multi_leg_position(list(map()), Decimal.t(), Decimal.t(), :long | :short) :: map()
  def multi_leg_position(legs, current_price, initial_equity, side \\ :long) do
    Leverage.multi_leg_position(legs, current_price, initial_equity, side)
  end

  @doc false
  @spec safety(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short, map()) :: safety_result()
  def safety(liq, entry, swan_pct, side, cfg \\ %{}) do
    Safety.safety(liq, entry, swan_pct, side, cfg)
  end

  @doc false
  @spec compare_dca_safety(
          map(),
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          :long | :short,
          Decimal.t(),
          map()
        ) :: map() | {:error, atom()}
  def compare_dca_safety(
        single_leg,
        dca_leg,
        current_price,
        initial_equity,
        mmr,
        side,
        swan_pct,
        safety_cfg \\ %{}
      ) do
    Safety.compare_dca_safety(
      single_leg,
      dca_leg,
      current_price,
      initial_equity,
      mmr,
      side,
      swan_pct,
      safety_cfg
    )
  end

  @doc false
  @spec convert_ladder_for_short(list()) :: list()
  defdelegate convert_ladder_for_short(long_preset), to: DCAPlanner

  @doc false
  @spec dca_ladder(
          map(),
          Decimal.t(),
          Decimal.t(),
          Decimal.t(),
          list(),
          :long | :short,
          Decimal.t(),
          keyword() | Decimal.t()
        ) :: map()
  def dca_ladder(
        position,
        reserve,
        entry_price,
        ui_lev,
        ladder_preset,
        side,
        mmr_rate,
        opts \\ []
      ) do
    DCAPlanner.dca_ladder(
      position,
      reserve,
      entry_price,
      ui_lev,
      ladder_preset,
      side,
      mmr_rate,
      opts
    )
  end

  @doc false
  @spec quantize(Decimal.t()) :: Decimal.t()
  defdelegate quantize(value), to: Quantization
end
