defmodule DeltaCalc.PortfolioMargin do
  @moduledoc """
  Portfolio-margin calculations over a caller-supplied position list.

  This module nets offsetting long and short quantities before computing maintenance
  margin, liquidation price, and margin usage. It performs no I/O and assumes all
  positions in a call belong to the same risk unit.
  """

  use Descripex, namespace: "/portfolio_margin"

  alias DeltaCalc.Calc

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)

  @typedoc "Position side used for net exposure."
  @type side :: :long | :short

  @typedoc "Portfolio-margin position input."
  @type position :: %{
          side: side(),
          quantity: Decimal.t() | integer() | float() | String.t(),
          mark_price: Decimal.t() | integer() | float() | String.t(),
          mmr: Decimal.t() | integer() | float() | String.t()
        }

  @typedoc "Portfolio-margin account input."
  @type account :: %{
          :positions => [position()],
          optional(:equity) => Decimal.t() | integer() | float() | String.t()
        }

  @typedoc "Margin usage under the portfolio model."
  @type usage :: %{
          used: Decimal.t(),
          available: Decimal.t(),
          usage_pct: Decimal.t()
        }

  api(
    :combined_maintenance_margin,
    "Calculate maintenance margin after netting offsetting portfolio positions.",
    params: [
      account: [
        kind: :value,
        description: "Map with :positions, each carrying :side, :quantity, :mark_price, and :mmr."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Maintenance margin for the net position, rounded to 8 places."
    }
  )

  @doc "Return net quantity x mark price x max MMR across the portfolio."
  @spec combined_maintenance_margin(account()) :: Decimal.t()
  def combined_maintenance_margin(account) do
    exposure = net_exposure(account.positions)

    exposure.net_quantity
    |> Decimal.abs()
    |> Decimal.mult(exposure.mark_price)
    |> Decimal.mult(exposure.mmr)
    |> Calc.quantize()
  end

  api(
    :portfolio_liquidation_price,
    "Estimate liquidation price for the netted portfolio book.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :equity and :positions carrying :side, :quantity, :mark_price, and :mmr."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Netted-book liquidation price, or nil when the book is flat."
    }
  )

  @doc "Return the price where equity equals net maintenance margin, or nil for a flat book."
  @spec portfolio_liquidation_price(account()) :: Decimal.t() | nil
  def portfolio_liquidation_price(account) do
    exposure = net_exposure(account.positions)
    equity = to_decimal(account.equity)

    case Decimal.compare(exposure.net_quantity, @zero) do
      :gt -> net_long_liquidation_price(equity, exposure)
      :lt -> net_short_liquidation_price(equity, exposure)
      :eq -> nil
    end
  end

  api(
    :margin_usage,
    "Calculate used and available margin under portfolio-margin netting.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :equity and :positions carrying :side, :quantity, :mark_price, and :mmr."
      ]
    ],
    returns: %{
      type: :map,
      description: "Map with :used, :available, and :usage_pct Decimal fields."
    }
  )

  @doc "Return used maintenance margin, available equity, and usage percentage."
  @spec margin_usage(account()) :: usage()
  def margin_usage(account) do
    equity = to_decimal(account.equity)
    used = combined_maintenance_margin(account)
    available = equity |> Decimal.sub(used) |> Decimal.max(@zero) |> Calc.quantize()

    %{
      used: used,
      available: available,
      usage_pct: usage_pct(used, equity)
    }
  end

  defp net_long_liquidation_price(equity, exposure) do
    numerator =
      exposure.net_quantity
      |> Decimal.mult(exposure.mark_price)
      |> Decimal.sub(equity)

    denominator = Decimal.mult(exposure.net_quantity, Decimal.sub(@one, exposure.mmr))

    liquidation_price(numerator, denominator)
  end

  defp net_short_liquidation_price(equity, exposure) do
    net_size = Decimal.abs(exposure.net_quantity)

    numerator =
      net_size
      |> Decimal.mult(exposure.mark_price)
      |> Decimal.add(equity)

    denominator = Decimal.mult(net_size, Decimal.add(@one, exposure.mmr))

    liquidation_price(numerator, denominator)
  end

  defp liquidation_price(numerator, denominator) do
    case Decimal.compare(denominator, @zero) do
      :gt ->
        numerator
        |> Decimal.div(denominator)
        |> Calc.quantize()
        |> Decimal.max(@zero)

      _ ->
        nil
    end
  end

  defp usage_pct(used, equity) do
    case Decimal.compare(equity, @zero) do
      :gt ->
        used
        |> Decimal.div(equity)
        |> Decimal.mult(@hundred)
        |> Calc.quantize()

      _ ->
        @zero
    end
  end

  defp net_exposure(positions) do
    Enum.reduce(
      positions,
      %{net_quantity: @zero, weighted_mark: @zero, gross_quantity: @zero, mmr: @zero},
      fn
        position, acc ->
          quantity = to_decimal(position.quantity)
          mark_price = to_decimal(position.mark_price)
          mmr = to_decimal(position.mmr)
          signed_quantity = signed_quantity(position.side, quantity)
          abs_quantity = Decimal.abs(quantity)

          %{
            net_quantity: Decimal.add(acc.net_quantity, signed_quantity),
            weighted_mark: Decimal.add(acc.weighted_mark, Decimal.mult(abs_quantity, mark_price)),
            gross_quantity: Decimal.add(acc.gross_quantity, abs_quantity),
            mmr: Decimal.max(acc.mmr, mmr)
          }
      end
    )
    |> Map.put_new(:mark_price, @zero)
    |> normalize_mark_price()
  end

  defp normalize_mark_price(%{gross_quantity: gross_quantity} = exposure) do
    mark_price =
      case Decimal.compare(gross_quantity, @zero) do
        :gt -> Decimal.div(exposure.weighted_mark, gross_quantity)
        _ -> @zero
      end

    %{exposure | mark_price: mark_price}
  end

  defp signed_quantity(:long, quantity), do: quantity
  defp signed_quantity(:short, quantity), do: Decimal.negate(quantity)

  @spec to_decimal(Decimal.t() | number() | String.t()) :: Decimal.t()
  defp to_decimal(%Decimal{} = value), do: value

  defp to_decimal(value) do
    {:ok, decimal} = Decimal.cast(value)
    decimal
  end
end
