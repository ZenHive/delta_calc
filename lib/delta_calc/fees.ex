defmodule DeltaCalc.Fees do
  @moduledoc """
  Pure fee and slippage math for effective fill prices, roundtrip costs, and
  funding-adjusted breakeven levels.

  Fee and slippage rates are caller-supplied — no exchange clients or I/O.
  """

  use Descripex, namespace: "/fees"

  alias DeltaCalc.Calc

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @bps_divisor Decimal.new(10_000)

  @typedoc "Side for entry/exit price adjustments and breakeven."
  @type side :: :long | :short

  @typedoc "Fee and slippage inputs for effective fill prices."
  @type fill_params :: %{
          required(:fee_rate) => Decimal.t() | number() | String.t(),
          optional(:slippage_bps) => Decimal.t() | number() | String.t(),
          optional(:side) => side()
        }

  @typedoc "Inputs for roundtrip fee cost."
  @type roundtrip_params :: %{
          optional(:notional) => Decimal.t() | number() | String.t(),
          optional(:entry_price) => Decimal.t() | number() | String.t(),
          optional(:size) => Decimal.t() | number() | String.t(),
          optional(:exit_price) => Decimal.t() | number() | String.t(),
          required(:open_fee_rate) => Decimal.t() | number() | String.t(),
          required(:close_fee_rate) => Decimal.t() | number() | String.t()
        }

  @typedoc "Inputs for funding-adjusted breakeven (extends roundtrip with size and side)."
  @type breakeven_params :: %{
          required(:size) => Decimal.t() | number() | String.t(),
          required(:open_fee_rate) => Decimal.t() | number() | String.t(),
          required(:close_fee_rate) => Decimal.t() | number() | String.t(),
          optional(:exit_price) => Decimal.t() | number() | String.t(),
          optional(:side) => side()
        }

  api(
    :effective_entry,
    "Adjust a fill price for entry fees and optional slippage.",
    params: [
      fill_price: [
        kind: :value,
        description: "Reported fill price before fees and slippage.",
        schema: float()
      ],
      params: [
        kind: :value,
        description:
          "Map with :fee_rate (taker or maker fraction), optional :slippage_bps, optional :side (:long default)."
      ]
    ],
    returns: %{
      type: :decimal,
      description:
        "Effective entry price — higher for long buys, lower for short sells after adverse costs."
    }
  )

  @doc """
  Return the effective entry price after folding in fee rate and slippage.

  Long entries (buys) increase; short entries (sells) decrease.
  """
  @spec effective_entry(Decimal.t() | number() | String.t(), fill_params()) :: Decimal.t()
  def effective_entry(fill_price, params) do
    fill_price
    |> to_decimal()
    |> apply_entry_adjustment(params)
    |> Calc.quantize()
  end

  api(
    :effective_exit,
    "Adjust a fill price for exit fees and optional slippage.",
    params: [
      fill_price: [
        kind: :value,
        description: "Reported fill price before fees and slippage.",
        schema: float()
      ],
      params: [
        kind: :value,
        description:
          "Map with :fee_rate (taker or maker fraction), optional :slippage_bps, optional :side (:long default)."
      ]
    ],
    returns: %{
      type: :decimal,
      description:
        "Effective exit price — lower for long sells, higher for short buys after adverse costs."
    }
  )

  @doc """
  Return the effective exit price after folding in fee rate and slippage.

  Long exits (sells) decrease; short exits (buys) increase.
  """
  @spec effective_exit(Decimal.t() | number() | String.t(), fill_params()) :: Decimal.t()
  def effective_exit(fill_price, params) do
    fill_price
    |> to_decimal()
    |> apply_exit_adjustment(params)
    |> Calc.quantize()
  end

  api(
    :roundtrip_cost,
    "Return total open+close fee cost for a position.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :open_fee_rate and :close_fee_rate plus either :notional or :entry_price and :size; optional :exit_price for close notional."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Absolute fee cost in quote currency for open and close legs."
    }
  )

  @doc """
  Return the total fee cost to open and close a position.

  Pass `:notional` directly, or `:entry_price` and `:size` (with optional
  `:exit_price` for the close leg; defaults to entry price).
  """
  @spec roundtrip_cost(roundtrip_params()) :: Decimal.t()
  def roundtrip_cost(params) do
    open_rate = to_decimal(params.open_fee_rate)
    close_rate = to_decimal(params.close_fee_rate)
    {entry_price, size, exit_price} = notional_inputs(params)

    open_notional = Decimal.mult(entry_price, size)
    close_notional = Decimal.mult(exit_price, size)

    open_notional
    |> Decimal.mult(open_rate)
    |> Decimal.add(Decimal.mult(close_notional, close_rate))
    |> Calc.quantize()
  end

  api(
    :funding_adjusted_breakeven,
    "Compute breakeven price after roundtrip fees and accrued funding.",
    params: [
      entry_price: [
        kind: :value,
        description: "Position entry price.",
        schema: float()
      ],
      params: [
        kind: :value,
        description:
          "Map with :size, :open_fee_rate, :close_fee_rate; optional :exit_price estimate and :side (:long default)."
      ],
      accrued_funding: [
        kind: :value,
        description:
          "Net accrued funding in quote currency (negative when paid, positive when received).",
        schema: float()
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Price at which the position breaks even after fees and funding."
    }
  )

  @doc """
  Return the breakeven price accounting for open/close fee rates and accrued funding.

  Uses the exact two-leg fee model: close fees apply to the breakeven exit notional.
  Returns `entry_price` unchanged when `size` is zero.
  """
  @spec funding_adjusted_breakeven(
          Decimal.t() | number() | String.t(),
          breakeven_params(),
          Decimal.t() | number() | String.t()
        ) :: Decimal.t()
  def funding_adjusted_breakeven(entry_price, params, accrued_funding) do
    entry = to_decimal(entry_price)
    size = to_decimal(params.size)
    funding = to_decimal(accrued_funding)
    side = Map.get(params, :side, :long)

    if Decimal.compare(size, @zero) != :gt do
      entry
    else
      open_rate = to_decimal(params.open_fee_rate)
      close_rate = to_decimal(params.close_fee_rate)

      breakeven_price(entry, size, open_rate, close_rate, funding, side)
      |> Calc.quantize()
    end
  end

  @spec apply_entry_adjustment(Decimal.t(), fill_params()) :: Decimal.t()
  defp apply_entry_adjustment(fill_price, params) do
    adjustment = total_adjustment(params)

    case Map.get(params, :side, :long) do
      :long -> Decimal.mult(fill_price, Decimal.add(@one, adjustment))
      :short -> Decimal.mult(fill_price, Decimal.sub(@one, adjustment))
    end
  end

  @spec apply_exit_adjustment(Decimal.t(), fill_params()) :: Decimal.t()
  defp apply_exit_adjustment(fill_price, params) do
    adjustment = total_adjustment(params)

    case Map.get(params, :side, :long) do
      :long -> Decimal.mult(fill_price, Decimal.sub(@one, adjustment))
      :short -> Decimal.mult(fill_price, Decimal.add(@one, adjustment))
    end
  end

  @spec total_adjustment(fill_params()) :: Decimal.t()
  defp total_adjustment(params) do
    fee = to_decimal(params.fee_rate)
    slippage = params |> Map.get(:slippage_bps, @zero) |> to_decimal() |> bps_to_rate()
    Decimal.add(fee, slippage)
  end

  @spec bps_to_rate(Decimal.t()) :: Decimal.t()
  defp bps_to_rate(bps), do: Decimal.div(bps, @bps_divisor)

  @spec notional_inputs(roundtrip_params()) ::
          {Decimal.t(), Decimal.t(), Decimal.t()}
  defp notional_inputs(%{notional: notional}) do
    entry = to_decimal(notional)
    {entry, @one, entry}
  end

  defp notional_inputs(params) do
    entry = to_decimal(params.entry_price)
    size = to_decimal(params.size)
    exit = params |> Map.get(:exit_price, entry) |> to_decimal()
    {entry, size, exit}
  end

  @spec breakeven_price(Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), Decimal.t(), side()) ::
          Decimal.t()
  defp breakeven_price(entry, size, open_rate, close_rate, funding, :long) do
    numerator =
      entry
      |> Decimal.mult(Decimal.add(@one, open_rate))
      |> Decimal.mult(size)
      |> Decimal.add(funding)

    denominator = Decimal.mult(size, Decimal.sub(@one, close_rate))
    Decimal.div(numerator, denominator)
  end

  defp breakeven_price(entry, size, open_rate, close_rate, funding, :short) do
    numerator =
      entry
      |> Decimal.mult(Decimal.sub(@one, open_rate))
      |> Decimal.mult(size)
      |> Decimal.sub(funding)

    denominator = Decimal.mult(size, Decimal.add(@one, close_rate))
    Decimal.div(numerator, denominator)
  end

  @spec to_decimal(Decimal.t() | number() | String.t()) :: Decimal.t()
  defp to_decimal(%Decimal{} = value), do: value

  defp to_decimal(value) do
    {:ok, decimal} = Decimal.cast(value)
    decimal
  end
end
