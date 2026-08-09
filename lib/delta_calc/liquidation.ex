defmodule DeltaCalc.Liquidation do
  @moduledoc """
  Simplified analytical liquidation-price calculations for long and short positions.
  """

  use Descripex, namespace: "/liquidation"

  alias DeltaCalc.Decimal, as: DecimalInput

  @zero Decimal.new(0)
  @one Decimal.new(1)
  @maximum_mmr Decimal.new("0.99999999")

  @type decimal_result :: Decimal.t() | {:error, atom()}

  api(:liquidation, "Calculate liquidation price using simplified analytical model.",
    params: [
      entry: [
        kind: :value,
        description:
          "Entry price (> 0) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      leff: [
        kind: :value,
        description:
          "Effective leverage (>= 0) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      mmr_total: [
        kind: :value,
        description:
          "Total minimum margin requirement (0-1) as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ],
      side: [kind: :value, description: "Position side (:long or :short)", schema: :long | :short]
    ],
    returns: %{
      type: :decimal,
      description:
        "Estimated liquidation price, or {:error, :non_positive_entry | :negative_effective_leverage}"
    }
  )

  @spec liquidation(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: decimal_result()
  def liquidation(entry, leff, mmr_total, side) do
    entry = DecimalInput.cast!(entry)
    leff = DecimalInput.cast!(leff)

    mmr_total =
      mmr_total
      |> DecimalInput.cast!()
      |> Decimal.max(@zero)
      |> Decimal.min(@maximum_mmr)

    cond do
      Decimal.compare(entry, @zero) in [:lt, :eq] ->
        {:error, :non_positive_entry}

      Decimal.compare(leff, @zero) == :lt ->
        {:error, :negative_effective_leverage}

      Decimal.compare(leff, @zero) == :eq ->
        @zero

      true ->
        liquidation_for_side(entry, leff, mmr_total, side)
    end
  end

  @spec liquidation_for_side(Decimal.t(), Decimal.t(), Decimal.t(), :long | :short) :: Decimal.t()
  defp liquidation_for_side(entry, leff, mmr_total, side) do
    factor = @one |> Decimal.sub(mmr_total) |> Decimal.div(leff)

    case side do
      :long -> @one |> Decimal.sub(factor) |> Decimal.mult(entry) |> Decimal.max(@zero)
      :short -> @one |> Decimal.add(factor) |> Decimal.mult(entry)
    end
  end
end
