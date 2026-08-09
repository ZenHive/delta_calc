defmodule DeltaCalc.Decimal do
  @moduledoc """
  Exact input coercion for DeltaCalc's Decimal calculations.

  Accepted inputs are existing `Decimal` values, integers, and complete decimal
  strings. Floats are rejected because they cannot represent arbitrary decimal
  values exactly.
  """

  use Descripex, namespace: "/decimal"

  @typedoc "An exact value accepted by DeltaCalc's calculation boundaries."
  @type input :: Elixir.Decimal.t() | integer() | String.t()

  @typedoc "The reason returned when a value is not an exact Decimal input."
  @type cast_error :: :invalid_decimal

  api(:cast, "Cast an exact input (Decimal, integer, or complete decimal string) to Decimal.",
    params: [
      value: [
        kind: :value,
        description:
          "Decimal, integer, or complete decimal string; floats are rejected as inexact"
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, Decimal.t()} on success, {:error, :invalid_decimal} otherwise"
    }
  )

  @doc "Cast an exact input to Decimal or return a tagged error."
  @spec cast(term()) :: {:ok, Elixir.Decimal.t()} | {:error, cast_error()}
  def cast(%Elixir.Decimal{} = value), do: {:ok, value}
  def cast(value) when is_integer(value), do: {:ok, Elixir.Decimal.new(value)}

  def cast(value) when is_binary(value) do
    case Elixir.Decimal.cast(value) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, :invalid_decimal}
    end
  end

  def cast(_value), do: {:error, :invalid_decimal}

  api(:cast!, "Cast an exact input to Decimal, raising on invalid input.",
    params: [
      value: [
        kind: :value,
        description:
          "Decimal, integer, or complete decimal string; floats are rejected as inexact"
      ]
    ],
    returns: %{
      type: :decimal,
      description: "The coerced Decimal; raises ArgumentError for floats or invalid input"
    }
  )

  @doc "Cast an exact input to Decimal or raise `ArgumentError`."
  @spec cast!(term()) :: Elixir.Decimal.t()
  def cast!(value) do
    case cast(value) do
      {:ok, decimal} ->
        decimal

      {:error, :invalid_decimal} ->
        raise ArgumentError,
              "expected a Decimal, integer, or canonical decimal string, got: #{inspect(value)}"
    end
  end
end
