defmodule DeltaCalc.FeesTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Fees

  @fill Decimal.new("50000")
  @fee_rate Decimal.new("0.0004")
  @slippage_bps Decimal.new("10")

  describe "effective_entry/2" do
    # Independent fees golden — provenance: hand calc from public fill-adjustment
    # contract. Long effective_entry = fill × (1 + fee_rate + slippage_bps/10_000).
    #   fill=50000, fee=0.0004, slippage=10 bps = 0.001
    #   adjustment = 0.0004 + 0.001 = 0.0014
    #   50000 × 1.0014 = 50070 exactly
    test "increases long entry price for fee and slippage" do
      result =
        Fees.effective_entry(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("50070.00000000"))
    end

    # Hand calc: short entry = fill × (1 − adjustment) = 50000 × 0.9986 = 49930
    test "decreases short entry price for fee and slippage" do
      result =
        Fees.effective_entry(@fill, %{
          fee_rate: @fee_rate,
          slippage_bps: @slippage_bps,
          side: :short
        })

      assert Decimal.equal?(result, Decimal.new("49930.00000000"))
    end

    # Hand calc: fee only 0.0004 → 50000 × 1.0004 = 50020
    test "defaults to long side and zero slippage" do
      result = Fees.effective_entry(@fill, %{fee_rate: @fee_rate})

      assert Decimal.equal?(result, Decimal.new("50020.00000000"))
    end

    # Hand calc: maker 0.0002 → 50000 × 1.0002 = 50010
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
    # Independent roundtrip golden — provenance: hand calc.
    #   open + close = 10000 × 0.0004 + 10000 × 0.0004 = 4 + 4 = 8
    test "returns open and close fees from notional" do
      result =
        Fees.roundtrip_cost(%{
          notional: Decimal.new("10000"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate
        })

      assert Decimal.equal?(result, Decimal.new("8.00000000"))
    end

    # Hand calc: (50000×2)×0.0004 × 2 legs = 40 × 2 = 80
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

    # Hand calc (independent literal — not recomputed from fee × notional algebra):
    #   open = 50000 × 1 × 0.0004 = 20
    #   close = 51000 × 1 × 0.0004 = 20.4
    #   total = 40.4
    test "uses exit price for close leg when provided" do
      result =
        Fees.roundtrip_cost(%{
          entry_price: @fill,
          exit_price: Decimal.new("51000"),
          size: Decimal.new("1"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate
        })

      assert Decimal.equal?(result, Decimal.new("40.40000000"))
    end

    # Hand calc: 10000×0.0004 + 10000×0.0002 = 4 + 2 = 6
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
    # Net PnL realized by closing a position of `size` opened at `entry` at price `close`,
    # paying open/close fees on each leg's notional and collecting signed `funding`.
    # At the true breakeven price this must be (approximately) zero.
    defp net_pnl(:long, entry, close, size, open_rate, close_rate, funding) do
      gross = entry |> Decimal.sub(close) |> Decimal.negate() |> Decimal.mult(size)
      fees = leg_fees(entry, close, size, open_rate, close_rate)
      gross |> Decimal.sub(fees) |> Decimal.add(funding)
    end

    defp net_pnl(:short, entry, close, size, open_rate, close_rate, funding) do
      gross = entry |> Decimal.sub(close) |> Decimal.mult(size)
      fees = leg_fees(entry, close, size, open_rate, close_rate)
      gross |> Decimal.sub(fees) |> Decimal.add(funding)
    end

    defp leg_fees(entry, close, size, open_rate, close_rate) do
      open_fee = entry |> Decimal.mult(size) |> Decimal.mult(open_rate)
      close_fee = close |> Decimal.mult(size) |> Decimal.mult(close_rate)
      Decimal.add(open_fee, close_fee)
    end

    defp assert_breaks_even(side, entry, breakeven, size, open_rate, close_rate, funding) do
      net = net_pnl(side, entry, breakeven, size, open_rate, close_rate, funding)
      # breakeven is quantized to 8 dp, so allow a sub-cent residual.
      assert Decimal.compare(Decimal.abs(net), Decimal.new("0.0001")) == :lt,
             "expected net PnL ~0 at breakeven, got #{Decimal.to_string(net)}"
    end

    test "long breakeven (no funding) yields zero net PnL" do
      result =
        Fees.funding_adjusted_breakeven(
          @fill,
          %{
            size: Decimal.new("2"),
            open_fee_rate: @fee_rate,
            close_fee_rate: Decimal.new("0.0002"),
            side: :long
          },
          Decimal.new("0")
        )

      assert Decimal.compare(result, @fill) == :gt

      assert_breaks_even(
        :long,
        @fill,
        result,
        Decimal.new("2"),
        @fee_rate,
        Decimal.new("0.0002"),
        Decimal.new("0")
      )
    end

    test "received funding lowers long breakeven and still nets zero" do
      base =
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

      funding = Decimal.new("10")

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

      assert Decimal.compare(result, base) == :lt
      assert_breaks_even(:long, @fill, result, Decimal.new("1"), @fee_rate, @fee_rate, funding)
    end

    test "paid funding raises long breakeven and still nets zero" do
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

      assert_breaks_even(:long, @fill, result, Decimal.new("1"), @fee_rate, @fee_rate, funding)
    end

    test "short breakeven is below entry and nets zero" do
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

      assert Decimal.compare(result, @fill) == :lt

      assert_breaks_even(
        :short,
        @fill,
        result,
        Decimal.new("1"),
        @fee_rate,
        @fee_rate,
        Decimal.new("0")
      )
    end

    test "received funding raises short breakeven and still nets zero" do
      base =
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

      assert Decimal.compare(result, base) == :gt
      assert_breaks_even(:short, @fill, result, Decimal.new("1"), @fee_rate, @fee_rate, funding)
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
