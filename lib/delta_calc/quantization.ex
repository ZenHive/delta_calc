defmodule DeltaCalc.Quantization do
  @moduledoc """
  Legacy output-boundary quantization retained for retired-dashboard compatibility.
  """

  use Descripex, namespace: "/quantization"

  @output_precision 8

  api(:quantize, "Round a Decimal to the retired dashboard's eight-place compatibility format.",
    params: [
      value: [
        kind: :value,
        description:
          "Value to quantize as a canonical decimal string; native Elixir callers may also pass Decimal or integer.",
        schema: String.t()
      ]
    ],
    returns: %{type: :decimal, description: "Value rounded to the legacy 8-place format"}
  )

  @spec quantize(Decimal.t()) :: Decimal.t()
  def quantize(value), do: Decimal.round(value, @output_precision)
end
