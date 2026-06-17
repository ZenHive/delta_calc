defmodule DeltaCalc.PresetsTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Presets

  describe "load_modes/0" do
    test "returns three risk modes with correct structure" do
      modes = Presets.load_modes()

      assert %{conservative: _, moderate: _, aggressive: _} = modes
      assert map_size(modes) == 3
    end

    test "conservative mode has correct values" do
      modes = Presets.load_modes()
      conservative = modes.conservative

      assert %{pct: pct, cap: cap} = conservative
      assert Decimal.equal?(pct, Decimal.new("0.01"))
      assert Decimal.equal?(cap, Decimal.new("0.01"))
    end

    test "moderate mode has correct values" do
      modes = Presets.load_modes()
      moderate = modes.moderate

      assert %{pct: pct, cap: cap} = moderate
      assert Decimal.equal?(pct, Decimal.new("0.03"))
      assert Decimal.equal?(cap, Decimal.new("0.02"))
    end

    test "aggressive mode has correct values" do
      modes = Presets.load_modes()
      aggressive = modes.aggressive

      assert %{pct: pct, cap: cap} = aggressive
      assert Decimal.equal?(pct, Decimal.new("0.05"))
      assert Decimal.equal?(cap, Decimal.new("0.03"))
    end

    test "modes are ordered by increasing risk" do
      modes = Presets.load_modes()

      # Conservative < Moderate < Aggressive for both pct and cap
      assert Decimal.compare(modes.conservative.pct, modes.moderate.pct) == :lt
      assert Decimal.compare(modes.moderate.pct, modes.aggressive.pct) == :lt
      assert Decimal.compare(modes.conservative.cap, modes.moderate.cap) == :lt
      assert Decimal.compare(modes.moderate.cap, modes.aggressive.cap) == :lt
    end

    test "all percentages are within valid range [0, 1]" do
      modes = Presets.load_modes()

      for {_mode_name, mode} <- modes do
        assert Decimal.compare(mode.pct, Decimal.new("0")) in [:gt, :eq]
        assert Decimal.compare(mode.pct, Decimal.new("1")) in [:lt, :eq]
        assert Decimal.compare(mode.cap, Decimal.new("0")) in [:gt, :eq]
        assert Decimal.compare(mode.cap, Decimal.new("1")) in [:lt, :eq]
      end
    end
  end

  describe "load_thresholds/0" do
    test "returns thresholds for major assets" do
      thresholds = Presets.load_thresholds()

      assert %{"ETH" => _, "BTC" => _, "SOL" => _} = thresholds
      assert map_size(thresholds) == 3
    end

    test "ETH thresholds are correct" do
      thresholds = Presets.load_thresholds()
      eth = thresholds["ETH"]

      assert %{long: 25, short: 25} = eth
    end

    test "BTC thresholds are correct" do
      thresholds = Presets.load_thresholds()
      btc = thresholds["BTC"]

      assert %{long: 20, short: 20} = btc
    end

    test "SOL thresholds are correct" do
      thresholds = Presets.load_thresholds()
      sol = thresholds["SOL"]

      assert %{long: 30, short: 30} = sol
    end

    test "all thresholds are positive integers" do
      thresholds = Presets.load_thresholds()

      for {_asset, threshold} <- thresholds do
        assert is_integer(threshold.long)
        assert is_integer(threshold.short)
        assert threshold.long > 0
        assert threshold.short > 0
      end
    end

    test "thresholds reflect relative volatility ordering" do
      thresholds = Presets.load_thresholds()

      # BTC (most stable) < ETH (moderate) < SOL (most volatile)
      assert thresholds["BTC"].long < thresholds["ETH"].long
      assert thresholds["ETH"].long < thresholds["SOL"].long
      assert thresholds["BTC"].short < thresholds["ETH"].short
      assert thresholds["ETH"].short < thresholds["SOL"].short
    end

    test "symmetric thresholds for long and short" do
      thresholds = Presets.load_thresholds()

      for {_asset, threshold} <- thresholds do
        assert threshold.long == threshold.short
      end
    end
  end

  describe "load_dca_preset/0" do
    test "returns 3-step DCA ladder" do
      ladder = Presets.load_dca_preset()

      assert [_, _, _] = ladder
    end

    test "each step is a tuple with price and allocation percentages" do
      ladder = Presets.load_dca_preset()

      for {price_pct, allocation_pct} <- ladder do
        assert %Decimal{} = price_pct
        assert %Decimal{} = allocation_pct
      end
    end

    test "price percentages are in descending order" do
      ladder = Presets.load_dca_preset()
      price_percentages = Enum.map(ladder, fn {price_pct, _} -> price_pct end)

      [step1, step2, step3] = price_percentages
      assert Decimal.compare(step1, step2) == :gt
      assert Decimal.compare(step2, step3) == :gt
    end

    test "correct DCA ladder values" do
      ladder = Presets.load_dca_preset()

      expected = [
        {Decimal.new("0.95"), Decimal.new("0.30")},
        {Decimal.new("0.90"), Decimal.new("0.30")},
        {Decimal.new("0.85"), Decimal.new("0.30")}
      ]

      assert ladder == expected
    end

    test "price percentages are within valid range" do
      ladder = Presets.load_dca_preset()

      for {price_pct, _allocation_pct} <- ladder do
        assert Decimal.compare(price_pct, Decimal.new("0")) == :gt
        assert Decimal.compare(price_pct, Decimal.new("1")) == :lt
      end
    end

    test "allocation percentages are within valid range" do
      ladder = Presets.load_dca_preset()

      for {_price_pct, allocation_pct} <- ladder do
        assert Decimal.compare(allocation_pct, Decimal.new("0")) == :gt
        assert Decimal.compare(allocation_pct, Decimal.new("1")) == :lt
      end
    end

    test "total allocation leaves 10% reserve" do
      ladder = Presets.load_dca_preset()

      total_allocated =
        ladder
        |> Enum.map(fn {_price_pct, allocation_pct} -> allocation_pct end)
        |> Enum.reduce(Decimal.new("0"), &Decimal.add/2)

      expected_allocated = Decimal.new("0.90")
      expected_reserve = Decimal.new("0.10")

      assert Decimal.equal?(total_allocated, expected_allocated)

      remaining = Decimal.sub(Decimal.new("1"), total_allocated)
      assert Decimal.equal?(remaining, expected_reserve)
    end

    test "implements reserve-based DCA strategy" do
      ladder = Presets.load_dca_preset()

      # Verify decreasing price levels (scaling in on weakness)
      [{price1, _}, {price2, _}, {price3, _}] = ladder

      # 5% drawdown from entry
      assert Decimal.equal?(price1, Decimal.new("0.95"))
      # 10% drawdown from entry
      assert Decimal.equal?(price2, Decimal.new("0.90"))
      # 15% drawdown from entry
      assert Decimal.equal?(price3, Decimal.new("0.85"))

      # Equal allocation per step (30% each)
      for {_price, allocation} <- ladder do
        assert Decimal.equal?(allocation, Decimal.new("0.30"))
      end
    end
  end

  describe "integration tests" do
    test "all functions return valid data structures" do
      modes = Presets.load_modes()
      thresholds = Presets.load_thresholds()
      ladder = Presets.load_dca_preset()

      # Modes can be used for allocation calculations
      assert is_map(modes)

      for {_name, mode} <- modes do
        assert %{pct: %Decimal{}, cap: %Decimal{}} = mode
      end

      # Thresholds can be used for safety calculations
      assert is_map(thresholds)

      for {asset_name, threshold} <- thresholds do
        assert is_binary(asset_name)
        assert %{long: long_pct, short: short_pct} = threshold
        assert is_integer(long_pct) and is_integer(short_pct)
      end

      # Ladder can be used for DCA calculations
      assert is_list(ladder)

      for {price_pct, allocation_pct} <- ladder do
        assert %Decimal{} = price_pct
        assert %Decimal{} = allocation_pct
      end
    end

    test "presets are consistent with risk management principles" do
      modes = Presets.load_modes()
      thresholds = Presets.load_thresholds()
      ladder = Presets.load_dca_preset()

      # Conservative mode has lowest risk
      assert Decimal.compare(modes.conservative.pct, modes.aggressive.pct) == :lt

      # Higher volatility assets have higher black swan thresholds
      assert thresholds["SOL"].long > thresholds["BTC"].long

      # DCA ladder preserves capital for reserve-based scaling
      total_dca_allocation =
        ladder
        |> Enum.map(fn {_, allocation} -> allocation end)
        |> Enum.reduce(&Decimal.add/2)

      # 90% allocated across 3 steps, 10% held in reserve
      assert Decimal.equal?(total_dca_allocation, Decimal.new("0.90"))
    end
  end
end
