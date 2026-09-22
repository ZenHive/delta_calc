defmodule DeltaCalc.CashSecuredPutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DeltaCalc.CashSecuredPut

  defp money(value, currency \\ "USD"), do: %{currency: currency, value: value}

  defp params do
    %{
      settled_cash: money("752.25"),
      strike: %{base_currency: "ETH", quote_currency: "USD", value: "3000"},
      quantity: %{
        unit: :contracts,
        base_currency: "ETH",
        value: "2.5",
        base_units_per_contract: "0.1"
      },
      fee_reserve: money("2.25"),
      existing_commitments: []
    }
  end

  defp coverage(params), do: CashSecuredPut.cash_secured_put_coverage(params)
  defp equal(actual, expected), do: assert(Decimal.equal?(actual, Decimal.new(expected)))

  test "golden fractional contracts fund full strike principal and fees exactly" do
    assert {:ok, result} = coverage(params())
    assert result.cash_currency == "USD"
    assert result.base_currency == "ETH"
    equal(result.base_amount, "0.25")
    equal(result.strike_principal, "750")
    equal(result.fee_reserve, "2.25")
    equal(result.existing_commitments, "0")
    equal(result.settled_cash, "752.25")
    equal(result.total_required, "752.25")
    equal(result.remaining_capacity, "0")
    equal(result.uncovered_amount, "0")
    assert result.fully_covered
  end

  test "one caller-denominated smallest cash unit short cannot count as covered" do
    input = put_in(params(), [:settled_cash, :value], "752.24999999")
    assert {:ok, result} = coverage(input)
    equal(result.uncovered_amount, "0.00000001")
    equal(result.remaining_capacity, "0")
    refute result.fully_covered
  end

  test "base amount is not multiplied and multiple disjoint commitments consume cash" do
    input = %{
      params()
      | quantity: %{unit: :base_currency, base_currency: "ETH", value: "0.25"},
        existing_commitments: [money("10"), money("0.75"), money("100")],
        settled_cash: money("900")
    }

    assert {:ok, result} = coverage(input)
    equal(result.strike_principal, "750")
    equal(result.existing_commitments, "110.75")
    equal(result.total_required, "863")
    equal(result.remaining_capacity, "37")
    equal(result.uncovered_amount, "0")
    assert result.fully_covered

    assert {:ok, deficit} = coverage(%{input | settled_cash: money(100)})
    equal(deficit.uncovered_amount, "763")
    refute deficit.fully_covered
  end

  test "zero quantities, strike and cash are valid; fees and commitments still require cash" do
    input = params() |> put_in([:quantity, :value], 0) |> Map.put(:settled_cash, money(0))
    assert {:ok, result} = coverage(input)
    equal(result.strike_principal, "0")
    equal(result.uncovered_amount, "2.25")
    refute result.fully_covered

    assert {:ok, result} = coverage(%{input | fee_reserve: money("-0")})
    assert result.fully_covered
    equal(result.total_required, "0")

    assert {:ok, result} = coverage(put_in(params(), [:strike, :value], 0))
    equal(result.strike_principal, "0")
    equal(result.remaining_capacity, "750")
  end

  test "no premium input can offset principal" do
    assert {:error, :invalid_shape} = coverage(Map.put(params(), :unreceived_premium, "750"))
    assert {:error, :invalid_shape} = coverage(Map.put(params(), :premium, "750"))
  end

  test "rejects mismatched and invalid currency identifiers at every boundary" do
    for path <- [
          [:quantity, :base_currency],
          [:strike, :base_currency],
          [:strike, :quote_currency],
          [:settled_cash, :currency],
          [:fee_reserve, :currency]
        ] do
      assert {:error, :currency_mismatch} = coverage(put_in(params(), path, "usd"))

      for invalid <- ["", nil, :USD, 123] do
        assert {:error, :invalid_currency} = coverage(put_in(params(), path, invalid))
      end
    end

    assert {:error, :currency_mismatch} =
             coverage(%{params() | existing_commitments: [money(1), money(1, "BTC")]})
  end

  test "rejects inexact, nonfinite, malformed and negative amounts" do
    paths = [
      [:strike, :value],
      [:settled_cash, :value],
      [:fee_reserve, :value],
      [:quantity, :value],
      [:quantity, :base_units_per_contract]
    ]

    invalid = [nil, 0.1, "bad", "1oops", "NaN", "Infinity", "-Infinity", Decimal.new("NaN")]

    for path <- paths do
      for value <- invalid do
        assert {:error, :invalid_decimal} = coverage(put_in(params(), path, value))
      end

      assert {:error, :negative_amount} = coverage(put_in(params(), path, "-0.001"))
    end

    for value <- invalid do
      assert {:error, :invalid_decimal} =
               coverage(%{params() | existing_commitments: [money(value)]})
    end

    assert {:error, :negative_amount} =
             coverage(%{params() | existing_commitments: [money(-1)]})

    assert {:error, :non_positive_multiplier} =
             coverage(put_in(params(), [:quantity, :base_units_per_contract], 0))
  end

  test "rejects missing, unknown and ambiguous units and shapes" do
    for key <- Map.keys(params()) do
      assert {:error, :invalid_shape} = coverage(Map.delete(params(), key))
    end

    for input <- [
          nil,
          [],
          %{},
          %{params() | strike: nil},
          %{params() | existing_commitments: nil}
        ] do
      assert {:error, :invalid_shape} = coverage(input)
    end

    for quantity <- [
          nil,
          %{unit: :contracts, base_currency: "ETH", value: 1},
          %{unit: :base_currency, base_currency: "ETH", value: 1, base_units_per_contract: 10},
          %{unit: :usd_notional, base_currency: "ETH", value: 1},
          %{base_currency: "ETH", value: 1}
        ] do
      assert {:error, :invalid_shape} = coverage(%{params() | quantity: quantity})
    end

    for key <- [:fee_reserve, :settled_cash] do
      assert {:error, :invalid_shape} = coverage(Map.put(params(), key, 1))
    end

    assert {:error, :invalid_shape} = coverage(%{params() | existing_commitments: [1]})

    assert {:error, :invalid_shape} =
             coverage(%{params() | existing_commitments: [money("1") | :tail]})
  end

  test "exact results exceed default precision and ignore display rounding and context" do
    input = %{
      params()
      | quantity: %{unit: :base_currency, base_currency: "BTC", value: Decimal.new(1)},
        strike: %{
          base_currency: "BTC",
          quote_currency: "USD",
          value: "1000000000000000000000000000000000"
        },
        settled_cash: money("1000000000000000000000000000000000"),
        fee_reserve: money("0.000000001")
    }

    context = %Decimal.Context{precision: 3, rounding: :down, traps: [:inexact, :rounded]}

    Decimal.Context.with(context, fn ->
      assert {:ok, result} = coverage(input)

      assert Decimal.equal?(
               result.total_required,
               Decimal.new(1, 1_000_000_000_000_000_000_000_000_000_000_000_000_000_001, -9)
             )

      equal(result.uncovered_amount, "0.000000001")
      refute result.fully_covered
      assert Decimal.Context.get() == context
    end)
  end

  test "multiplication preserves digits beyond the default arithmetic precision" do
    input = %{
      params()
      | quantity: %{
          unit: :contracts,
          base_currency: "ETH",
          value: "99999999999999999999",
          base_units_per_contract: "99999999999999999999"
        },
        strike: %{base_currency: "ETH", quote_currency: "USD", value: 1},
        fee_reserve: money(0),
        settled_cash: money(0)
    }

    assert {:ok, result} = coverage(input)
    equal(result.strike_principal, 9_999_999_999_999_999_999_800_000_000_000_000_000_001)
    equal(result.uncovered_amount, 9_999_999_999_999_999_999_800_000_000_000_000_000_001)
  end

  test "finite Decimal amounts outside decimal128 exponents stay exact" do
    for exponent <- [-6200, 6200] do
      value = Decimal.new(1, 1, exponent)

      input = %{
        params()
        | quantity: %{unit: :base_currency, base_currency: "ETH", value: value},
          strike: %{base_currency: "ETH", quote_currency: "USD", value: 1},
          fee_reserve: money(0),
          settled_cash: money(0)
      }

      assert {:ok, result} = coverage(input)
      assert Decimal.equal?(result.strike_principal, value)
      assert Decimal.equal?(result.uncovered_amount, value)
      refute result.fully_covered
    end
  end

  property "integer cash-unit ledger independently proves surplus and shortfall" do
    check all(
            count <- integer(0..100),
            fee_cents <- integer(0..500),
            obligations <- list_of(integer(0..500), max_length: 10),
            cash_cents <- integer(0..100_000)
          ) do
      # Each contract delivers 0.25 base at 12 USD: debit 300 cents per contract.
      debits = List.duplicate(300, count) ++ [fee_cents | obligations]
      balance_cents = Enum.reduce(debits, cash_cents, &(&2 - &1))

      input = %{
        settled_cash: money(Decimal.new(1, cash_cents, -2)),
        strike: %{base_currency: "BTC", quote_currency: "USD", value: "12"},
        quantity: %{
          unit: :contracts,
          base_currency: "BTC",
          value: count,
          base_units_per_contract: "0.25"
        },
        fee_reserve: money(Decimal.new(1, fee_cents, -2)),
        existing_commitments: Enum.map(obligations, &money(Decimal.new(1, &1, -2)))
      }

      assert {:ok, result} = coverage(input)
      assert result.fully_covered == balance_cents >= 0
      assert Decimal.equal?(result.remaining_capacity, Decimal.new(1, max(balance_cents, 0), -2))
      assert Decimal.equal?(result.uncovered_amount, Decimal.new(1, max(-balance_cents, 0), -2))
    end
  end

  property "equivalent base and fractional contract quantities have identical funding" do
    check all(hundredths <- integer(0..10_000)) do
      contract_input = put_in(params(), [:quantity, :value], Decimal.new(1, hundredths, -2))

      base_input = %{
        contract_input
        | quantity: %{
            unit: :base_currency,
            base_currency: "ETH",
            value: Decimal.new(1, hundredths, -3)
          }
      }

      assert {:ok, contracts} = coverage(contract_input)
      assert {:ok, base} = coverage(base_input)
      assert contracts == base
    end
  end
end
