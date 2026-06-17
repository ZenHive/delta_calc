defmodule DeltaCalc.FeesTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Fees

  @fill Decimal.new("50000")
  @fee_rate Decimal.new("0.0004")
  @slippage_bps Decimal.new("10")

  describe "effective_entry/2" do
    test "increases long entry price for fee and slippage" do
      result =
        Fees.effective_entry(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("50070.00000000"))
    end

    test "decreases short entry price for fee and slippage" do
      result =
        Fees.effective_entry(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :short
        })

      assert Decimal.equal?(result, Decimal.new("49930.00000000"))
    end

    test "defaults to long side and zero slippage" do
      result = Fees.effective_entry(@fill, %{fee_rate: @fee_rate})

      assert Decimal.equal?(result, Decimal.new("50020.00000000"))
    end

    test "accepts maker fee only without slippage" do
      result =
        Fees.effective_entry(@fill, %{
          fee_rate: Decimal.new("0.0002"),
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("50010.00000000"))
    end

    test "accepts numeric and string inputs" do
      from_int = Fees.effective_entry(50_000, %{fee_rate: "0.0004"})
      from_float = Fees.effective_entry(50_000.0, %{fee_rate: 0.0004})

      assert Decimal.equal?(from_int, Decimal.new("50020.00000000"))
      assert Decimal.equal?(from_int, from_float)
    end
  end

  describe "effective_exit/2" do
    test "decreases long exit price for fee and slippage" do
      result =
        Fees.effective_exit(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("49930.00000000"))
    end

    test "increases short exit price for fee and slippage" do
      result =
        Fees.effective_exit(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :short
        })

      assert Decimal.equal?(result, Decimal.new("50070.00000000"))
    end

    test "defaults to long side and zero slippage" do
      result = Fees.effective_exit(@fill, %{fee_rate: @fee_rate})

      assert Decimal.equal?(result, Decimal.new("49980.00000000"))
    end
  end

  describe "roundtrip_cost/1" do
    test "returns open and close fees from notional" do
      result =
        Fees.roundtrip_cost(%{
          notional: Decimal.new("10000"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate
        })

      assert Decimal.equal?(result, Decimal.new("8.00000000"))
    end

    test "returns fees from entry price and size" do
      result =
        Fees.roundtrip_cost(%{
          entry_price: @fill,
          size: Decimal.new("2"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate
        })

      assert Decimal.equal?(result, Decimal.new("80.00000000"))
    end

    test "uses exit price for close leg when provided" do
      result =
        Fees.roundtrip_cost(%{
          entry_price: @fill,
          exit_price: Decimal.new("51000"),
          size: Decimal.new("1"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate
        })

      open_fee = Decimal.mult(@fill, @fee_rate)
      close_fee = Decimal.mult(Decimal.new("51000"), @fee_rate)

      assert Decimal.equal?(result, Decimal.add(open_fee, close_fee) |> Decimal.round(8))
    end

    test "supports asymmetric taker open and maker close rates" do
      result =
        Fees.roundtrip_cost(%{
          notional: Decimal.new("10000"),
          open_fee_rate: Decimal.new("0.0004"),
          close_fee_rate: Decimal.new("0.0002")
        })

      assert Decimal.equal?(result, Decimal.new("6.00000000"))
    end
  end

  describe "funding_adjusted_breakeven/3" do
    test "returns long breakeven with exact two-leg fee model" do
      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("1"),
            open_fee_rate: @fee_rate,
            close_fee_rate: @fee_rate,
            side: :long
          },
          Decimal.new("0")
        )

      expected =
        @fill
        |> Decimal.mult(Decimal.add(Decimal.new("1"), @fee_rate))
        |> Decimal.div(Decimal.sub(Decimal.new("1"), @fee_rate))

      assert Decimal.equal?(result, Decimal.round(expected, 8))
    end

    test "adds paid funding to long breakeven" do
      funding = Decimal.new("-10")

      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("1"),
            open_fee_rate: @fee_rate,
            close_fee_rate: @fee_rate,
            side: :long
          },
          funding
        )

      numerator =
        @fill
        |> Decimal.mult(Decimal.add(Decimal.new("1"), @fee_rate))
        |> Decimal.add(funding)

      expected = Decimal.div(numerator, Decimal.sub(Decimal.new("1"), @fee_rate))

      assert Decimal.equal?(result, Decimal.round(expected, 8))
    end

    test "returns short breakeven below entry when funding is zero" do
      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("1"),
            open_fee_rate: @fee_rate,
            close_fee_rate: @fee_rate,
            side: :short
          },
          Decimal.new("0")
        )

      expected =
        @fill
        |> Decimal.mult(Decimal.sub(Decimal.new("1"), @fee_rate))
        |> Decimal.div(Decimal.add(Decimal.new("1"), @fee_rate))

      assert Decimal.compare(result, @fill) == :lt
      assert Decimal.equal?(result, Decimal.round(expected, 8))
    end

    test "subtracts received funding from short breakeven requirement" do
      funding = Decimal.new("10")

      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("1"),
            open_fee_rate: @fee_rate,
            close_fee_rate: @fee_rate,
            side: :short
          },
          funding
        )

      numerator =
        @fill
        |> Decimal.mult(Decimal.sub(Decimal.new("1"), @fee_rate))
        |> Decimal.sub(funding)

      expected = Decimal.div(numerator, Decimal.add(Decimal.new("1"), @fee_rate))

      assert Decimal.equal?(result, Decimal.round(expected, 8))
    end

    test "returns entry unchanged when size is zero" do
      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("0"),
            open_fee_rate: @fee_rate,
            close_fee_rate: @fee_rate
          },
          Decimal.new("-25")
        )

      assert Decimal.equal?(result, @fill)
    end
  end

  describe "long/short symmetry" do
    test "entry and exit adjustments mirror across sides" do
      params = %{fee_rate: @fee_rate, slippage_bps: @slippage_bps}

      long_entry = Fees.effective_entry(@fill, Map.put(params, :side, :long))
      short_exit = Fees.effective_exit(@fill, Map.put(params, :side, :short))

      short_entry = Fees.effective_entry(@fill, Map.put(params, :side, :short))
      long_exit = Fees.effective_exit(@fill, Map.put(params, :side, :long))

      assert Decimal.equal?(long_entry, short_exit)
      assert Decimal.equal?(short_entry, long_exit)
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(Fees) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for Fees, got: #{inspect(other)}")
        end

      public_functions =
        Fees.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert Fees.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
