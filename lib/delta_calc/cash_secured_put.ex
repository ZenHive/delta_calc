defmodule DeltaCalc.CashSecuredPut do
  @moduledoc """
  Pure cash-secured put funding arithmetic in the strike's quote currency.

  The consumer supplies actual settled cash, disjoint existing cash commitments,
  and a separate fee reserve. Unreceived premium is never credited. Currency
  identifiers are nonempty, case-sensitive strings; no conversion is performed.
  Coverage is arithmetic only, never provider margin acceptance, eligibility,
  reservation, risk-target approval, or permission to trade.
  """

  use Descripex, namespace: "/cash_secured_put"

  alias DeltaCalc.Decimal, as: DecimalInput

  @type money :: %{currency: String.t(), value: DecimalInput.input()}
  @type quantity ::
          %{unit: :base_currency, base_currency: String.t(), value: DecimalInput.input()}
          | %{
              unit: :contracts,
              base_currency: String.t(),
              value: DecimalInput.input(),
              base_units_per_contract: DecimalInput.input()
            }
  @type params :: %{
          settled_cash: money(),
          strike: %{
            base_currency: String.t(),
            quote_currency: String.t(),
            value: DecimalInput.input()
          },
          quantity: quantity(),
          fee_reserve: money(),
          existing_commitments: [money()]
        }
  @type result :: %{
          cash_currency: String.t(),
          base_currency: String.t(),
          base_amount: Decimal.t(),
          settled_cash: Decimal.t(),
          strike_principal: Decimal.t(),
          fee_reserve: Decimal.t(),
          existing_commitments: Decimal.t(),
          total_required: Decimal.t(),
          remaining_capacity: Decimal.t(),
          uncovered_amount: Decimal.t(),
          fully_covered: boolean()
        }
  @type error ::
          :invalid_shape
          | :invalid_currency
          | :currency_mismatch
          | :invalid_decimal
          | :negative_amount
          | :non_positive_multiplier

  api(:cash_secured_put_coverage, "Calculate full strike principal and cash funding capacity.",
    params: [
      params: [
        kind: :value,
        description:
          "Actual settled cash, strike in quote currency per base unit, explicitly tagged quantity, " <>
            "separate fee reserve, and disjoint existing cash commitments. Exact values use decimal strings. " <>
            "Contracts require a positive provider-supplied base_units_per_contract; base amounts forbid it. " <>
            "Fractional contracts are accepted; consumer owns eligibility. No premium credit or currency conversion.",
        schema: %{
          settled_cash: %{currency: String.t(), value: String.t()},
          strike: %{base_currency: String.t(), quote_currency: String.t(), value: String.t()},
          quantity: %{
            optional(:base_units_per_contract) => String.t(),
            unit: :base_currency | :contracts,
            base_currency: String.t(),
            value: String.t()
          },
          fee_reserve: %{currency: String.t(), value: String.t()},
          existing_commitments: [%{currency: String.t(), value: String.t()}]
        }
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, map} with Decimal base_amount, settled_cash, strike_principal, fee_reserve, " <>
          "summed existing_commitments, total_required, remaining_capacity, uncovered_amount and " <>
          "fully_covered; or {:error, reason}. Coverage is never margin acceptance or risk approval."
    }
  )

  @doc """
  Return cash capacity after full strike principal, fees and existing commitments.

  `:contracts` quantity is multiplied exactly once by `:base_units_per_contract`.
  `:base_currency` quantity is already a base amount and rejects a multiplier.
  Quantity base currency must match strike base currency; all money currencies
  must match strike quote currency. Extra fields and ambiguous shapes are rejected.
  Amounts must be finite, exact and nonnegative; the contract multiplier is positive.
  Fractional contracts are allowed arithmetically; the consumer checks provider rules.

  Remaining capacity and uncovered amount are clamped at zero and expressed in
  cash currency, after the proposed put and all commitments. No display rounding
  or ambient Decimal precision affects the result. Premium is not an input;
  the consumer alone determines which funds have actually settled.
  """
  @spec cash_secured_put_coverage(params()) :: {:ok, result()} | {:error, error()}
  def cash_secured_put_coverage(
        %{
          settled_cash: cash,
          strike: %{base_currency: base, quote_currency: quote, value: strike} = price,
          quantity: quantity,
          fee_reserve: fee,
          existing_commitments: commitments
        } = params
      )
      when map_size(params) == 5 and map_size(price) == 3 and is_list(commitments) do
    with :ok <- currency(base),
         :ok <- currency(quote),
         {:ok, strike} <- amount(strike),
         {:ok, cash} <- money(cash, quote),
         {:ok, fee} <- money(fee, quote),
         {:ok, count, multiplier} <- quantity(quantity, base),
         {:ok, commitments} <- commitments(commitments, quote) do
      values = [strike, cash, fee, count, multiplier | commitments]

      context =
        struct(Decimal.Context,
          precision: exact_precision(values),
          emax: :infinity,
          emin: :infinity
        )

      Decimal.Context.with(context, fn ->
        base_amount = Decimal.mult(count, multiplier)
        principal = Decimal.mult(base_amount, strike)
        existing = Enum.reduce(commitments, Decimal.new(0), &Decimal.add/2)
        required = principal |> Decimal.add(fee) |> Decimal.add(existing)
        remaining = Decimal.sub(cash, required)

        {:ok,
         %{
           cash_currency: quote,
           base_currency: base,
           base_amount: base_amount,
           settled_cash: cash,
           strike_principal: principal,
           fee_reserve: fee,
           existing_commitments: existing,
           total_required: required,
           remaining_capacity: Decimal.max(remaining, 0),
           uncovered_amount: Decimal.max(Decimal.negate(remaining), 0),
           fully_covered: Decimal.compare(remaining, 0) != :lt
         }}
      end)
    end
  end

  def cash_secured_put_coverage(_params), do: {:error, :invalid_shape}

  defp currency(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp currency(_value), do: {:error, :invalid_currency}

  defp same_currency(value, expected) do
    with :ok <- currency(value) do
      if value == expected, do: :ok, else: {:error, :currency_mismatch}
    end
  end

  defp money(%{currency: currency, value: value} = money, expected)
       when map_size(money) == 2 do
    with :ok <- same_currency(currency, expected), do: amount(value)
  end

  defp money(_money, _expected), do: {:error, :invalid_shape}

  defp quantity(%{unit: :base_currency, base_currency: currency, value: value} = quantity, base)
       when map_size(quantity) == 3 do
    with :ok <- same_currency(currency, base),
         {:ok, value} <- amount(value) do
      {:ok, value, Decimal.new(1)}
    end
  end

  defp quantity(
         %{
           unit: :contracts,
           base_currency: currency,
           value: value,
           base_units_per_contract: multiplier
         } = quantity,
         base
       )
       when map_size(quantity) == 4 do
    with :ok <- same_currency(currency, base),
         {:ok, value} <- amount(value),
         {:ok, multiplier} <- amount(multiplier) do
      if Decimal.positive?(multiplier),
        do: {:ok, value, multiplier},
        else: {:error, :non_positive_multiplier}
    end
  end

  defp quantity(_quantity, _base), do: {:error, :invalid_shape}

  defp commitments(values, currency) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case money(value, currency) do
        {:ok, amount} -> {:cont, {:ok, [amount | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp amount(value) do
    case DecimalInput.cast(value) do
      {:ok, %Decimal{coef: coef, exp: exp, sign: sign} = decimal}
      when is_integer(coef) and coef >= 0 and is_integer(exp) and sign in [-1, 1] ->
        if Decimal.negative?(decimal), do: {:error, :negative_amount}, else: {:ok, decimal}

      _ ->
        {:error, :invalid_decimal}
    end
  end

  # Bound all product digits, exponent alignment and addition carries without rounding.
  defp exact_precision(values) do
    Enum.reduce(values, 1, fn %Decimal{coef: coef, exp: exp}, precision ->
      precision + byte_size(Integer.to_string(coef)) + abs(exp) + 1
    end)
  end
end
