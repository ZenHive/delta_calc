defmodule DeltaCalc.DeltaNeutral do
  @moduledoc """
  Net delta aggregation and rebalance sizing for delta-neutral portfolios.

  Callers supply position maps with exchange-reported deltas (e.g. Deribit SPM
  `delta_total` for options). This module does not price options or compute Greeks.
  """

  use Descripex, namespace: "/delta_neutral"

  alias DeltaCalc.Calc

  @zero Decimal.new(0)
  @default_tolerance Decimal.new("0.0001")
  @default_instrument :perp

  @type position_kind :: :spot | :perp | :option
  @type position_side :: :long | :short

  @type position :: %{
          required(:kind) => position_kind(),
          optional(:size) => Decimal.t() | number() | String.t(),
          optional(:notional) => Decimal.t() | number() | String.t(),
          optional(:side) => position_side(),
          optional(:delta) => Decimal.t() | number() | String.t()
        }

  @type rebalance_params :: %{
          required(:positions) => [position()],
          optional(:tolerance) => Decimal.t() | number() | String.t(),
          optional(:instrument) => :spot | :perp
        }

  @type rebalance_result :: %{
          net_delta: Decimal.t(),
          within_tolerance: boolean(),
          side: :long | :short | :none,
          size: Decimal.t(),
          instrument: :spot | :perp,
          signed_hedge: Decimal.t()
        }

  api(
    :net_delta,
    "Aggregate signed delta exposure across spot, perp, and option positions.",
    params: [
      positions: [
        kind: :value,
        description:
          "List of position maps with :kind (:spot, :perp, or :option). " <>
            "Options must include exchange-supplied :delta; spot/perp use :delta when " <>
            "present, otherwise signed :size or :notional with optional :side."
      ]
    ],
    returns: %{
      type: :decimal,
      description: "Net signed delta exposure (positive = net long, negative = net short)."
    }
  )

  @doc """
  Sum signed delta exposure across `positions`.

  Option positions must include exchange-supplied `:delta` (not computed here).
  Spot and perp positions use `:delta` when present; otherwise derive signed
  exposure from `:size` or `:notional` and `:side` (default `:long`).
  """
  @spec net_delta([position()]) :: Decimal.t()
  def net_delta(positions) when is_list(positions) do
    positions
    |> Enum.reduce(@zero, fn position, acc ->
      acc |> Decimal.add(position_delta(position))
    end)
    |> Calc.quantize()
  end

  api(
    :rebalance_to_neutral,
    "Compute the hedge leg needed to flatten net delta within a tolerance.",
    params: [
      params: [
        kind: :value,
        description:
          "Map with :positions and optional :tolerance (default 0.0001) and " <>
            ":instrument (:perp default, or :spot). Also accepts a bare position list."
      ]
    ],
    returns: %{
      type: :map,
      description:
        "Map with :net_delta, :within_tolerance, :side (:long, :short, or :none), " <>
          ":size, :instrument, and :signed_hedge for Hedging distribution."
    }
  )

  @doc """
  Return the hedge adjustment to bring net delta to ~0 within `tolerance`.

  When already within tolerance, `:side` is `:none` and `:size` is zero.
  `:signed_hedge` is sized for `DeltaCalc.Hedging.suggest_hedge_distribution/1`.
  """
  @spec rebalance_to_neutral(rebalance_params() | [position()]) :: rebalance_result()
  def rebalance_to_neutral(positions) when is_list(positions) do
    rebalance_to_neutral(%{positions: positions})
  end

  def rebalance_to_neutral(%{positions: positions} = params) do
    tolerance = params |> Map.get(:tolerance, @default_tolerance) |> to_decimal() |> Decimal.abs()
    instrument = Map.get(params, :instrument, @default_instrument)
    net = net_delta(positions)

    if within_tolerance?(net, tolerance) do
      %{
        net_delta: net,
        within_tolerance: true,
        side: :none,
        size: @zero,
        instrument: instrument,
        signed_hedge: signed_hedge(:none, @zero)
      }
    else
      {side, size} = hedge_leg(net)

      %{
        net_delta: net,
        within_tolerance: false,
        side: side,
        size: size,
        instrument: instrument,
        signed_hedge: signed_hedge(side, size)
      }
    end
  end

  @spec position_delta(position()) :: Decimal.t()
  defp position_delta(%{kind: :option} = position) do
    position |> Map.fetch!(:delta) |> to_decimal()
  end

  defp position_delta(%{kind: kind} = position) when kind in [:spot, :perp] do
    case Map.get(position, :delta) do
      nil -> signed_size(position)
      delta -> to_decimal(delta)
    end
  end

  @spec signed_size(position()) :: Decimal.t()
  defp signed_size(position) do
    position
    |> position_size()
    |> to_decimal()
    |> Decimal.abs()
    |> apply_side(Map.get(position, :side, :long))
  end

  @spec position_size(position()) :: term()
  defp position_size(%{size: size}), do: size
  defp position_size(%{notional: notional}), do: notional

  defp position_size(position) do
    raise ArgumentError,
          "position requires :size or :notional, got: #{inspect(Map.drop(position, [:kind]))}"
  end

  @spec apply_side(Decimal.t(), position_side()) :: Decimal.t()
  defp apply_side(size, :short), do: Decimal.negate(size)
  defp apply_side(size, _), do: size

  @spec within_tolerance?(Decimal.t(), Decimal.t()) :: boolean()
  defp within_tolerance?(net, tolerance) do
    net |> Decimal.abs() |> Decimal.compare(tolerance) != :gt
  end

  @spec hedge_leg(Decimal.t()) :: {:long | :short, Decimal.t()}
  defp hedge_leg(net) do
    case Decimal.compare(net, @zero) do
      :gt -> {:short, Calc.quantize(net)}
      _ -> {:long, net |> Decimal.abs() |> Calc.quantize()}
    end
  end

  @spec signed_hedge(:long | :short | :none, Decimal.t()) :: Decimal.t()
  defp signed_hedge(:short, size), do: Decimal.negate(size)
  defp signed_hedge(:long, size), do: size
  defp signed_hedge(:none, _size), do: @zero

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
end
