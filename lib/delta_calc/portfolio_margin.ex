defmodule DeltaCalc.PortfolioMargin do
  @moduledoc """
  Portfolio-margin calculations over a caller-supplied position list.

  This module nets offsetting long and short quantities before computing maintenance
  margin, liquidation price, and margin usage. It performs no I/O and assumes all
  positions in a call belong to the same risk unit.
  """

  use Descripex, namespace: "/portfolio_margin"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @hundred Decimal.new(100)

  @typedoc "Position side used for net exposure."
  @type side :: :long | :short

  @typedoc "Portfolio-margin position input."
  @type position :: %{
          side: side(),
          quantity: DecimalInput.input(),
          mark_price: DecimalInput.input(),
          mmr: DecimalInput.input()
        }

  @typedoc "Portfolio-margin account input."
  @type account :: %{
          :positions => [position()],
          optional(:equity) => DecimalInput.input()
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
        description:
          "Map with :positions, each carrying :side plus :quantity, :mark_price, and :mmr as canonical decimal strings; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          positions: [
            %{
              side: :long | :short,
              quantity: String.t(),
              mark_price: String.t(),
              mmr: String.t()
            }
          ]
        }
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Maintenance margin for the net position at Decimal context precision."
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
  end

  api(
    :portfolio_liquidation_price,
    "Estimate liquidation price for the netted portfolio book.",
    params: [
      account: [
        kind: :value,
        description:
          "Map with :equity and position :quantity, :mark_price, and :mmr as canonical decimal strings plus each position :side; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          equity: String.t(),
          positions: [
            %{
              side: :long | :short,
              quantity: String.t(),
              mark_price: String.t(),
              mmr: String.t()
            }
          ]
        }
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
    equity = DecimalInput.cast!(account.equity)

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
          "Map with :equity and position :quantity, :mark_price, and :mmr as canonical decimal strings plus each position :side; native Elixir callers may also pass Decimal or integer for exact fields.",
        schema: %{
          equity: String.t(),
          positions: [
            %{
              side: :long | :short,
              quantity: String.t(),
              mark_price: String.t(),
              mmr: String.t()
            }
          ]
        }
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
    equity = DecimalInput.cast!(account.equity)
    used = combined_maintenance_margin(account)
    available = equity |> Decimal.sub(used) |> Decimal.max(@zero)

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

      _ ->
        @zero
    end
  end

  defp net_exposure(positions) do
    positions
    |> Enum.reduce(%{net_quantity: @zero, signed_notional: @zero, mmr: @zero}, fn position, acc ->
      quantity = DecimalInput.cast!(position.quantity)
      mark_price = DecimalInput.cast!(position.mark_price)
      mmr = DecimalInput.cast!(position.mmr)
      signed_quantity = signed_quantity(position.side, quantity)

      %{
        net_quantity: Decimal.add(acc.net_quantity, signed_quantity),
        signed_notional:
          Decimal.add(acc.signed_notional, Decimal.mult(signed_quantity, mark_price)),
        mmr: Decimal.max(acc.mmr, mmr)
      }
    end)
    |> normalize_mark_price()
  end

  defp normalize_mark_price(%{net_quantity: net_quantity} = exposure) do
    mark_price =
      case Decimal.compare(net_quantity, @zero) do
        :eq -> @zero
        _ -> Decimal.div(exposure.signed_notional, net_quantity)
      end

    Map.put(exposure, :mark_price, mark_price)
  end

  defp signed_quantity(:long, quantity), do: quantity
  defp signed_quantity(:short, quantity), do: Decimal.negate(quantity)
end
