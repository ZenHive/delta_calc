defmodule DeltaCalc.Concentration do
  @moduledoc """
  Concentration-risk primitives for portfolio asset weights.

  HHI is returned on the normalized 0-1 scale: equal weights move toward 0 and
  a single-asset portfolio returns 1.
  """

  use Descripex, namespace: "/concentration"

  alias DeltaCalc.Calc

  @zero Decimal.new(0)

  @type weight_input :: %{optional(term()) => Decimal.t()} | [Decimal.t()]

  api(:hhi, "Calculate Herfindahl-Hirschman Index over asset weights.",
    params: [
      weights: [
        kind: :value,
        description: "Per-asset weights as a map or list. Values are normalized before squaring."
      ]
    ],
    returns: %{type: :decimal, description: "HHI on the normalized 0-1 scale."}
  )

  @doc "Return the normalized HHI: `sum((weight / total_weight)^2)`."
  @spec hhi(weight_input()) :: Decimal.t()
  def hhi(weights) do
    weights = values(weights)
    total = Enum.reduce(weights, @zero, &Decimal.add/2)

    if Decimal.compare(total, @zero) == :gt do
      weights
      |> Enum.map(&normalized_square(&1, total))
      |> Enum.reduce(@zero, &Decimal.add/2)
      |> Calc.quantize()
    else
      @zero
    end
  end

  @spec values(weight_input()) :: [Decimal.t()]
  defp values(weights) when is_map(weights), do: Map.values(weights)
  defp values(weights) when is_list(weights), do: weights

  @spec normalized_square(Decimal.t(), Decimal.t()) :: Decimal.t()
  defp normalized_square(weight, total) do
    normalized = Decimal.div(weight, total)
    Decimal.mult(normalized, normalized)
  end
end
