defmodule DeltaCalc.PnLTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Fees
  alias DeltaCalc.PnL

  @entry Decimal.new("50000")
  @mark Decimal.new("51000")
  @exit Decimal.new("52000")
  @size Decimal.new("2")
  @fee_rate Decimal.new("0.0004")
  @close_rate Decimal.new("0.0002")

  describe "unrealized_pnl/1" do
    test "long profits when mark is above entry" do
      result =
        PnL.unrealized_pnl(%{
          entry_price: @entry,
          mark_price: @mark,
          size: @size,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("2000.00000000"))
    end

    test "short loses when mark is above entry" do
      result =
        PnL.unrealized_pnl(%{
          entry_price: @entry,
          mark_price: @mark,
          size: @size,
          side: :short
        })

      assert Decimal.equal?(result, Decimal.new("-2000.00000000"))
    end

    test "returns zero at entry price" do
      result =
        PnL.unrealized_pnl(%{
          entry_price: @entry,
          mark_price: @entry,
          size: @size,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "returns zero when size is zero" do
      result =
        PnL.unrealized_pnl(%{
          entry_price: @entry,
          mark_price: @mark,
          size: Decimal.new("0"),
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "returns zero when entry price is zero" do
      result =
        PnL.unrealized_pnl(%{
          entry_price: Decimal.new("0"),
          mark_price: @mark,
          size: @size,
          side: :long
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "accepts numeric and string inputs" do
      from_int =
        PnL.unrealized_pnl(%{
          entry_price: 50_000,
          mark_price: 51_000,
          size: 1,
          side: :long
        })

      from_string =
        PnL.unrealized_pnl(%{
          entry_price: "50000",
          mark_price: "51000",
          size: "1",
          side: :long
        })

      assert Decimal.equal?(from_int, Decimal.new("1000.00000000"))
      assert Decimal.equal?(from_int, from_string)
    end
  end

  describe "realized_pnl/1" do
    test "long nets fees and funding at exit" do
      funding = Decimal.new("15")

      result =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: @exit,
          size: @size,
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate,
          accrued_funding: funding
        })

      gross = Decimal.mult(Decimal.sub(@exit, @entry), @size)

      fees =
        Fees.roundtrip_cost(%{
          entry_price: @entry,
          exit_price: @exit,
          size: @size,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate
        })

      expected = gross |> Decimal.sub(fees) |> Decimal.add(funding) |> Decimal.round(8)

      assert Decimal.equal?(result, expected)
    end

    test "short nets fees and funding at exit" do
      exit = Decimal.new("48000")
      funding = Decimal.new("-8")

      result =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: exit,
          size: @size,
          side: :short,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate,
          accrued_funding: funding
        })

      gross = Decimal.mult(Decimal.sub(@entry, exit), @size)

      fees =
        Fees.roundtrip_cost(%{
          entry_price: @entry,
          exit_price: exit,
          size: @size,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate
        })

      expected = gross |> Decimal.sub(fees) |> Decimal.add(funding) |> Decimal.round(8)

      assert Decimal.equal?(result, expected)
    end

    test "defaults accrued funding to zero" do
      with_funding =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: @exit,
          size: @size,
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate,
          accrued_funding: Decimal.new("0")
        })

      without_funding =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: @exit,
          size: @size,
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate
        })

      assert Decimal.equal?(with_funding, without_funding)
    end

    test "returns zero when size is zero" do
      result =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: @exit,
          size: Decimal.new("0"),
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "returns zero when entry price is zero" do
      result =
        PnL.realized_pnl(%{
          entry_price: Decimal.new("0"),
          exit_price: @exit,
          size: @size,
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end
  end

  describe "roe/1" do
    test "returns pnl as a percentage of margin" do
      result =
        PnL.roe(%{
          pnl: Decimal.new("250"),
          margin: Decimal.new("1000")
        })

      assert Decimal.equal?(result, Decimal.new("25.00000000"))
    end

    test "returns negative ROE for losses" do
      result =
        PnL.roe(%{
          pnl: Decimal.new("-150"),
          margin: Decimal.new("500")
        })

      assert Decimal.equal?(result, Decimal.new("-30.00000000"))
    end

    test "returns zero when margin is zero" do
      result =
        PnL.roe(%{
          pnl: Decimal.new("250"),
          margin: Decimal.new("0")
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end

    test "returns zero when margin is negative" do
      result =
        PnL.roe(%{
          pnl: Decimal.new("250"),
          margin: Decimal.new("-100")
        })

      assert Decimal.equal?(result, Decimal.new("0"))
    end
  end

  describe "breakeven/1" do
    test "delegates to Fees.funding_adjusted_breakeven/3 for long" do
      funding = Decimal.new("12")

      params = %{
        entry_price: @entry,
        size: @size,
        open_fee_rate: @fee_rate,
        close_fee_rate: @close_rate,
        side: :long,
        accrued_funding: funding
      }

      assert Decimal.equal?(
               PnL.breakeven(params),
               Fees.funding_adjusted_breakeven(@entry, Map.delete(params, :entry_price), funding)
             )
    end

    test "delegates to Fees.funding_adjusted_breakeven/3 for short" do
      funding = Decimal.new("-5")

      params = %{
        entry_price: @entry,
        size: Decimal.new("1"),
        open_fee_rate: @fee_rate,
        close_fee_rate: @fee_rate,
        side: :short,
        accrued_funding: funding
      }

      assert Decimal.equal?(
               PnL.breakeven(params),
               Fees.funding_adjusted_breakeven(@entry, Map.delete(params, :entry_price), funding)
             )
    end

    test "returns entry unchanged when size is zero" do
      result =
        PnL.breakeven(%{
          entry_price: @entry,
          size: Decimal.new("0"),
          open_fee_rate: @fee_rate,
          close_fee_rate: @close_rate,
          accrued_funding: Decimal.new("10")
        })

      assert Decimal.equal?(result, @entry)
    end
  end

  describe "long/short symmetry" do
    test "unrealized PnL mirrors across sides at the same mark" do
      params = %{entry_price: @entry, mark_price: @mark, size: @size}

      long = PnL.unrealized_pnl(Map.put(params, :side, :long))
      short = PnL.unrealized_pnl(Map.put(params, :side, :short))

      assert Decimal.equal?(long, Decimal.abs(short))
      assert Decimal.compare(long, Decimal.new("0")) == :gt
      assert Decimal.compare(short, Decimal.new("0")) == :lt
    end

    test "realized PnL mirrors gross component across sides at symmetric exits" do
      long_exit = Decimal.new("52000")
      short_exit = Decimal.new("48000")

      long =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: long_exit,
          size: Decimal.new("1"),
          side: :long,
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate,
          accrued_funding: Decimal.new("0")
        })

      short =
        PnL.realized_pnl(%{
          entry_price: @entry,
          exit_price: short_exit,
          size: Decimal.new("1"),
          side: :short,
          open_fee_rate: @fee_rate,
          close_fee_rate: @fee_rate,
          accrued_funding: Decimal.new("0")
        })

      # Same absolute move from entry; fees differ slightly by exit notional but both profitable.
      assert Decimal.compare(long, Decimal.new("0")) == :gt
      assert Decimal.compare(short, Decimal.new("0")) == :gt
    end
  end

  describe "Descripex api() declarations" do
    test "all public functions are annotated with api() hints" do
      docs =
        case Code.fetch_docs(PnL) do
          {:docs_v1, _, _, _, _, _, docs} -> docs
          other -> flunk("Expected docs for PnL, got: #{inspect(other)}")
        end

      public_functions =
        PnL.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__api__))

      for name <- public_functions do
        assert PnL.__api__(name), "Missing __api__/1 entry for #{name}"

        assert Enum.any?(docs, fn
                 {{:function, ^name, _arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
                 _ -> false
               end),
               "Missing api() hints for #{name}"
      end
    end
  end
end
