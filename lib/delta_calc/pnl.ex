defmodule DeltaCalc.Pnl do
  @moduledoc """
  Position PnL, return-on-equity, and fee/funding-adjusted breakeven math.

  Callers supply entry, mark/exit prices, size, side, fee rates, margin, and
  accrued funding from their own state — no exchange clients or I/O.
  """

  use Descripex, namespace: "/pnl"

  alias DeltaCalc.Calc
  alias DeltaCalc.Decimal, as: DecimalInput
  alias DeltaCalc.Fees

  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  @typedoc "Position side for PnL calculations."
  @type side :: :long | :short

  @type decimal_input :: DecimalInput.input()

  @typedoc "Inputs for mark-to-market unrealized PnL."
  @type unrealized_params :: %{
          required(:entry_price) => decimal_input(),
          required(:mark_price) => decimal_input(),
          required(:size) => decimal_input(),
          required(:side) => side()
        }

  @typedoc "Inputs for exit-based realized PnL including fees and funding."
  @type realized_params :: %{
          required(:entry_price) => decimal_input(),
          required(:exit_price) => decimal_input(),
          required(:size) => decimal_input(),
          required(:side) => side(),
          required(:open_fee_rate) => decimal_input(),
          required(:close_fee_rate) => decimal_input(),
          optional(:accrued_funding) => decimal_input()
        }

  @typedoc "Inputs for return on equity."
  @type roe_params :: %{
          required(:pnl) => decimal_input(),
          required(:margin) => decimal_input()
        }

  @typedoc "Inputs for fee- and funding-adjusted breakeven price."
  @type breakeven_params :: %{
          required(:entry_price) => decimal_input(),
          required(:size) => decimal_input(),
          required(:open_fee_rate) => decimal_input(),
          required(:close_fee_rate) => decimal_input(),
          optional(:side) => side(),
          optional(:accrued_funding) => decimal_input()
        }

  api(
    :unrealized_pnl,
    "Calculate mark-to-market unrealized PnL for an open position.",
    params: [
      params: [
        kind: :value,
        description: "Map with :entry_price, :mark_price, :size, and :side (:long or :short)."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Unrealized PnL in quote currency (positive = profit)."
    }
  )

  @doc """
  Return side-aware unrealized PnL from entry to mark price.

  Returns zero when `size` or `entry_price` is not positive.
  """
  @spec unrealized_pnl(unrealized_params()) :: Decimal.t()
  def unrealized_pnl(params) do
    entry = DecimalInput.cast!(params.entry_price)
    mark = DecimalInput.cast!(params.mark_price)
    size = DecimalInput.cast!(params.size)

    if position_active?(entry, size) do
      gross_pnl(entry, mark, size, params.side)
      |> Calc.quantize()
    else
      @zero
    end
  end

  api(
    :realized_pnl,
    "Calculate net realized PnL at exit after roundtrip fees and accrued funding.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :entry_price, :exit_price, :size, :side, :open_fee_rate, " <>
            ":close_fee_rate; optional :accrued_funding (default 0)."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Net realized PnL in quote currency after fees and funding."
    }
  )

  @doc """
  Return net realized PnL at `exit_price` after open/close fees and accrued funding.

  Uses `DeltaCalc.Fees.roundtrip_cost/1` for the fee component.
  Returns zero when `size` or `entry_price` is not positive.
  """
  @spec realized_pnl(realized_params()) :: Decimal.t()
  def realized_pnl(params) do
    entry = DecimalInput.cast!(params.entry_price)
    exit = DecimalInput.cast!(params.exit_price)
    size = DecimalInput.cast!(params.size)
    funding = params |> Map.get(:accrued_funding, @zero) |> DecimalInput.cast!()

    if position_active?(entry, size) do
      gross = gross_pnl(entry, exit, size, params.side)

      fees =
        Fees.roundtrip_cost(%{
          entry_price: entry,
          exit_price: exit,
          size: size,
          open_fee_rate: params.open_fee_rate,
          close_fee_rate: params.close_fee_rate
        })

      gross
      |> Decimal.sub(fees)
      |> Decimal.add(funding)
      |> Calc.quantize()
    else
      @zero
    end
  end

  api(
    :roe,
    "Calculate return on equity as PnL divided by margin.",
    params: [
      params: [
        kind: :value,
        description: "Map with :pnl and :margin in quote currency."
      ]
    ],
    returns: %{
      type: :decimal,
      description:
        "ROE as a percentage (pnl / margin * 100), or zero when margin is not positive."
    }
  )

  @doc """
  Return `pnl / margin * 100`, or zero when margin is not positive.
  """
  @spec roe(roe_params()) :: Decimal.t()
  def roe(params) do
    pnl = DecimalInput.cast!(params.pnl)
    margin = DecimalInput.cast!(params.margin)

    if Decimal.compare(margin, @zero) == :gt do
      pnl
      |> Decimal.div(margin)
      |> Decimal.mult(@hundred)
      |> Calc.quantize()
    else
      @zero
    end
  end

  api(
    :breakeven,
    "Compute the price where the position turns green after fees and funding.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :entry_price, :size, :open_fee_rate, :close_fee_rate; " <>
            "optional :side (:long default) and :accrued_funding (default 0)."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Breakeven exit price after roundtrip fees and accrued funding."
    }
  )

  @doc """
  Return the breakeven exit price after roundtrip fees and accrued funding.

  Delegates to `DeltaCalc.Fees.funding_adjusted_breakeven/3`.
  Returns `entry_price` unchanged when `size` is zero.
  """
  @spec breakeven(breakeven_params()) :: Decimal.t()
  def breakeven(params) do
    accrued = params |> Map.get(:accrued_funding, @zero) |> DecimalInput.cast!()

    Fees.funding_adjusted_breakeven(
      params.entry_price,
      %{
        size: params.size,
        open_fee_rate: params.open_fee_rate,
        close_fee_rate: params.close_fee_rate,
        side: Map.get(params, :side, :long)
      },
      accrued
    )
  end

  @spec position_active?(Decimal.t(), Decimal.t()) :: boolean()
  defp position_active?(entry, size) do
    Decimal.compare(entry, @zero) == :gt and Decimal.compare(size, @zero) == :gt
  end

  @spec gross_pnl(Decimal.t(), Decimal.t(), Decimal.t(), side()) :: Decimal.t()
  defp gross_pnl(entry, price, size, :long) do
    price |> Decimal.sub(entry) |> Decimal.mult(size)
  end

  defp gross_pnl(entry, price, size, :short) do
    entry |> Decimal.sub(price) |> Decimal.mult(size)
  end
end
