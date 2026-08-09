defmodule DeltaCalc.OptionLadderTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.OptionLadder

  describe "optimal_expiries/2" do
    test "selects front, middle, and back expiries using target allocations" do
      expiries = [
        %{expiry: "25JAN", days_to_expiry: 4, liquidity: "0.5", bid_ask_spread: "0.08"},
        %{expiry: "31JAN", days_to_expiry: 7, liquidity: "0.8", bid_ask_spread: "0.06"},
        %{expiry: "07FEB", days_to_expiry: 14, liquidity: "0.6", bid_ask_spread: "0.07"},
        %{expiry: "28FEB", days_to_expiry: 31, liquidity: "0.7", bid_ask_spread: "0.09"}
      ]

      result = OptionLadder.optimal_expiries(expiries, [])

      assert Enum.map(result.buckets, & &1.bucket) == [:front, :middle, :back]
      assert Enum.map(result.buckets, & &1.expiry) == ["31JAN", "07FEB", "28FEB"]
      assert Decimal.equal?(Enum.at(result.buckets, 0).allocation, Decimal.new("0.50"))
      assert Decimal.equal?(Enum.at(result.buckets, 1).allocation, Decimal.new("0.30"))
      assert Decimal.equal?(Enum.at(result.buckets, 2).allocation, Decimal.new("0.20"))
    end

    test "filters illiquid and wide-spread expiries then normalizes remaining allocations" do
      expiries = [
        %{expiry: "31JAN", days_to_expiry: 7, liquidity: "0.8", bid_ask_spread: "0.06"},
        %{expiry: "07FEB", days_to_expiry: 14, liquidity: "0.6", bid_ask_spread: "0.07"},
        %{expiry: "28FEB", days_to_expiry: 31, liquidity: "0.7", bid_ask_spread: "0.12"}
      ]

      result = OptionLadder.optimal_expiries(expiries, max_spread_percent: Decimal.new("10"))

      assert Enum.map(result.buckets, & &1.bucket) == [:front, :middle]
      assert Decimal.equal?(Enum.at(result.buckets, 0).allocation, Decimal.new("0.6250"))
      assert Decimal.equal?(Enum.at(result.buckets, 1).allocation, Decimal.new("0.3750"))
      assert Decimal.equal?(result.total_allocation, Decimal.new("1.0000"))
    end

    test "returns no buckets when every expiry fails liquidity or spread filters" do
      expiries = [
        %{expiry: "31JAN", days_to_expiry: 7, liquidity: "0.01", bid_ask_spread: "0.06"},
        %{expiry: "07FEB", days_to_expiry: 14, liquidity: "0.6", bid_ask_spread: "0.20"}
      ]

      result = OptionLadder.optimal_expiries(expiries)

      assert result.buckets == []
      assert Decimal.equal?(result.total_allocation, Decimal.new("0"))
    end
  end

  describe "check_roll_conditions/2" do
    test "rolls near-expiry positions when spread is acceptable" do
      position = %{days_to_expiry: 3, pnl_percent: "10", bid_ask_spread: "0.14"}

      assert OptionLadder.check_roll_conditions(position, %{momentum: :flat}) == %{
               action: :roll,
               target: :next_weekly
             }
    end

    test "closes only when near expiry but spread is too wide" do
      position = %{days_to_expiry: 2, pnl_percent: "10", bid_ask_spread: "0.15"}

      assert OptionLadder.check_roll_conditions(position, %{momentum: :flat}) == %{
               action: :close_only,
               reason: "Spread exceeds 15%"
             }
    end

    test "partially rolls strong winners in strong upward momentum" do
      position = %{days_to_expiry: 12, pnl_percent: "250", bid_ask_spread: "0.08"}

      assert OptionLadder.check_roll_conditions(position, %{momentum: :strong_up}) == %{
               action: :partial_roll,
               take_profit: Decimal.new("0.5"),
               roll_up: Decimal.new("0.5")
             }
    end

    test "rolls nearly worthless short-dated options back toward ATM" do
      position = %{days_to_expiry: 6, pnl_percent: "-71", bid_ask_spread: "0.20"}

      assert OptionLadder.check_roll_conditions(position, %{momentum: :flat}) == %{
               action: :roll_to_atm
             }
    end

    test "holds when no rolling trigger matches" do
      position = %{days_to_expiry: 20, pnl_percent: "25", bid_ask_spread: "0.06"}

      assert OptionLadder.check_roll_conditions(position, %{momentum: :flat}) == %{action: :hold}
    end
  end

  describe "select_strikes/2" do
    test "builds a balanced call ladder and increases size when IV is cheap" do
      result =
        OptionLadder.select_strikes(
          %{spot_price: "60000", iv_percentile: 35, risk_profile: :balanced},
          strike_increment: Decimal.new("500")
        )

      assert result.risk_profile == :balanced
      assert result.option_type == :call
      assert result.iv_adjustment.action == :increase_size

      assert Enum.map(result.strikes, & &1.strike) == [
               Decimal.new("63000"),
               Decimal.new("66000"),
               Decimal.new("69000")
             ]
    end

    test "builds an aggressive put ladder below spot and reduces size when IV is expensive" do
      result =
        OptionLadder.select_strikes(
          %{spot_price: "60000", iv_percentile: 75, risk_profile: :aggressive},
          option_type: :put,
          strike_increment: Decimal.new("500")
        )

      assert result.iv_adjustment.action == :reduce_size

      assert Enum.map(result.strikes, & &1.strike) == [
               Decimal.new("51000"),
               Decimal.new("46500"),
               Decimal.new("42000")
             ]
    end

    test "uses default call option type and strike increment" do
      result =
        OptionLadder.select_strikes(%{
          spot_price: 60_000,
          iv_percentile: 55,
          risk_profile: :conservative
        })

      assert result.option_type == :call

      assert Enum.map(result.strikes, & &1.strike) == [
               Decimal.new("60000"),
               Decimal.new("61500"),
               Decimal.new("63000")
             ]
    end

    test "uses caller-selected strike precision and rounding mode" do
      params = %{spot_price: "100.05", iv_percentile: 55, risk_profile: :conservative}

      coarse =
        OptionLadder.select_strikes(params,
          strike_increment: "0.1",
          rounding_mode: :half_up
        )

      fine =
        OptionLadder.select_strikes(params,
          strike_increment: "0.01",
          rounding_mode: :down
        )

      assert hd(coarse.strikes).strike == Decimal.new("100.1")
      assert hd(fine.strikes).strike == Decimal.new("100.05")
      assert coarse.spot_price == fine.spot_price
    end
  end

  describe "sync_with_funding/2" do
    test "executes a roll when funding covers roll and spread costs" do
      result =
        OptionLadder.sync_with_funding(
          %{funding_received: "30", positions_to_roll: 1, roll_cost: "25", spread_cost: "3"},
          []
        )

      assert result.status == :executed
      assert Decimal.equal?(result.excess_funding, Decimal.new("2"))
      assert Decimal.equal?(result.margin_used, Decimal.new("0"))
    end

    test "skips when spread cost alone exceeds funding income" do
      result =
        OptionLadder.sync_with_funding(
          %{funding_received: "10", positions_to_roll: 1, roll_cost: "5", spread_cost: "12"},
          []
        )

      assert result.status == :skipped
      assert result.reason == :spread_exceeds_funding
    end

    test "uses margin for the shortfall only when requested" do
      result =
        OptionLadder.sync_with_funding(
          %{funding_received: "20", positions_to_roll: 1, roll_cost: "25", spread_cost: "3"},
          use_margin: true
        )

      assert result.status == :executed
      assert Decimal.equal?(result.margin_used, Decimal.new("8"))
      assert Decimal.equal?(result.excess_funding, Decimal.new("0"))
    end

    test "defers when funding is insufficient and margin is disabled" do
      result =
        OptionLadder.sync_with_funding(%{
          funding_received: 20,
          positions_to_roll: 1,
          roll_cost: "25.0",
          spread_cost: 3
        })

      assert result.status == :deferred
      assert result.reason == :insufficient_funding
      assert Decimal.equal?(result.excess_funding, Decimal.new("20"))
    end
  end

  describe "iv_adjusted_size/2" do
    test "increases base size when IV percentile is below 40" do
      result = OptionLadder.iv_adjusted_size(Decimal.new("100"), iv_percentile: 35)

      assert result.action == :increase_size
      assert Decimal.equal?(result.adjusted_size, Decimal.new("125.00"))
    end

    test "keeps base size when IV percentile is normal" do
      result = OptionLadder.iv_adjusted_size(Decimal.new("100"), iv_percentile: 55)

      assert result.action == :normal_size
      assert Decimal.equal?(result.adjusted_size, Decimal.new("100.00"))
    end

    test "reduces base size when IV percentile is above 70" do
      result = OptionLadder.iv_adjusted_size(Decimal.new("100"), iv_percentile: 75)

      assert result.action == :reduce_size
      assert Decimal.equal?(result.adjusted_size, Decimal.new("60.00"))
    end

    test "accepts default opts arity" do
      assert OptionLadder.iv_adjusted_size(Decimal.new("100"), iv_percentile: 55).action ==
               :normal_size
    end
  end

  describe "api() hints" do
    test "every public function has Descripex hints" do
      for entry <- OptionLadder.__api__() do
        assert function_exported?(OptionLadder, entry.name, entry.arity)
        assert entry.hints.description != ""
      end
    end
  end
end
