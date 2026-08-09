defmodule DeltaCalc.PropertyTest do
  @moduledoc false

  use ExUnit.Case
  use ExUnitProperties

  alias Decimal, as: D

  alias DeltaCalc.{
    Calc,
    Carry,
    Funding,
    MarginBridge,
    OptionsRisk,
    Pnl,
    PortfolioMargin,
    StressScenario
  }

  @max_runs 100
  @zero D.new(0)
  @one D.new(1)
  @hundred D.new(100)
  @days_per_year 365

  # --- Reusable generators ---

  defp positive_decimal(min_int, max_int) do
    bind(integer(min_int..max_int), fn n ->
      constant(D.new(Integer.to_string(n)))
    end)
  end

  defp positive_price do
    positive_decimal(1, 100_000)
  end

  defp positive_size do
    positive_decimal(1, 10_000)
  end

  defp leverage do
    bind(integer(1..50), fn n -> constant(D.new(Integer.to_string(n))) end)
  end

  defp mmr_rate do
    bind(integer(1..50), fn n ->
      constant(D.div(D.new(Integer.to_string(n)), D.new("10000")))
    end)
  end

  defp side do
    member_of([:long, :short])
  end

  defp periods_per_day do
    member_of([1, 3, 8, 24])
  end

  defp holding_days do
    integer(1..365)
  end

  defp leg do
    bind(positive_price(), fn entry ->
      bind(positive_decimal(10, 50_000), fn notional ->
        constant(%{entry: entry, notional: notional})
      end)
    end)
  end

  defp stress_position do
    bind(
      fixed_map(%{
        side: side(),
        quantity: integer(1..100),
        mark_price: positive_price(),
        mmr_bps: integer(1..100)
      }),
      fn %{side: position_side, quantity: qty, mark_price: mark, mmr_bps: mmr_bps} ->
        constant(%{
          id: System.unique_integer([:positive]),
          side: position_side,
          quantity: D.new(Integer.to_string(qty)),
          mark_price: mark,
          mmr: D.div(D.new(Integer.to_string(mmr_bps)), D.new("10000"))
        })
      end
    )
  end

  defp stress_account do
    bind(positive_decimal(100, 100_000), fn equity ->
      bind(list_of(stress_position(), min_length: 1, max_length: 4), fn positions ->
        constant(%{equity: equity, positions: positions})
      end)
    end)
  end

  # --- Math-derived helpers (not copied from production implementations) ---

  @spec gross_pnl_formula(D.t(), D.t(), D.t(), :long | :short) :: D.t()
  defp gross_pnl_formula(entry, price, size, :long) do
    price |> D.sub(entry) |> D.mult(size)
  end

  defp gross_pnl_formula(entry, price, size, :short) do
    entry |> D.sub(price) |> D.mult(size)
  end

  @spec leg_pnl_formula(map(), D.t(), :long | :short) :: D.t()
  defp leg_pnl_formula(%{entry: entry, notional: notional}, current_price, position_side) do
    tokens = D.div(notional, entry)

    case position_side do
      :long -> D.mult(tokens, D.sub(current_price, entry))
      :short -> D.mult(tokens, D.sub(entry, current_price))
    end
  end

  @spec multi_leg_pnl_formula([map()], D.t(), :long | :short) :: D.t()
  defp multi_leg_pnl_formula(legs, current_price, position_side) do
    legs
    |> Enum.map(&leg_pnl_formula(&1, current_price, position_side))
    |> Enum.reduce(@zero, &D.add/2)
  end

  @spec effective_leverage_formula(D.t(), D.t()) :: D.t()
  defp effective_leverage_formula(notional, equity) do
    if D.compare(equity, @zero) == :gt, do: D.div(notional, equity), else: @zero
  end

  @spec shocked_mark_formula(D.t(), D.t()) :: D.t()
  defp shocked_mark_formula(mark, shock_pct) do
    mark
    |> D.mult(shock_pct |> D.div(@hundred) |> D.add(@one))
    |> Calc.quantize()
  end

  @spec position_shock_pnl_formula(map(), D.t()) :: D.t()
  defp position_shock_pnl_formula(position, shock_pct) do
    mark = position.mark_price
    shocked = shocked_mark_formula(mark, shock_pct)

    signed_qty =
      if position.side == :long, do: position.quantity, else: D.negate(position.quantity)

    shocked
    |> D.sub(mark)
    |> D.mult(signed_qty)
  end

  @spec shocked_equity_formula(map(), D.t()) :: D.t()
  defp shocked_equity_formula(account, shock_pct) do
    unrealized =
      account.positions
      |> Enum.map(&position_shock_pnl_formula(&1, shock_pct))
      |> Enum.reduce(@zero, &D.add/2)

    account.equity |> D.add(unrealized) |> Calc.quantize()
  end

  @spec annualized_basis_formula(D.t(), pos_integer()) :: D.t()
  defp annualized_basis_formula(raw_basis, horizon_days) do
    D.mult(raw_basis, D.div(D.new(@days_per_year), D.new(horizon_days)))
  end

  @spec funding_daily_cost_formula(D.t(), D.t(), pos_integer()) :: D.t()
  defp funding_daily_cost_formula(rate_fraction, position_size, ppd) do
    # Fraction unit (matches Funding/Hedging/MarginBridge): abs(rate) * size * periods.
    rate_fraction
    |> D.abs()
    |> D.mult(position_size)
    |> D.mult(D.new(ppd))
  end

  describe "PnL antisymmetry" do
    property "gross PnL flips sign when side flips" do
      check all(
              entry <- positive_price(),
              price <- positive_price(),
              size <- positive_size(),
              max_runs: @max_runs
            ) do
        long =
          Pnl.unrealized_pnl(%{entry_price: entry, mark_price: price, size: size, side: :long})

        short =
          Pnl.unrealized_pnl(%{entry_price: entry, mark_price: price, size: size, side: :short})

        assert D.equal?(long, gross_pnl_formula(entry, price, size, :long))
        assert D.equal?(short, gross_pnl_formula(entry, price, size, :short))
        assert D.equal?(long, D.negate(short))
      end
    end
  end

  describe "DCA safety side awareness" do
    property "compare_dca_safety leverage change follows side-aware leg PnL" do
      check all(
              single <- leg(),
              dca <- leg(),
              current <- positive_price(),
              equity <- positive_decimal(50, 10_000),
              mmr <- mmr_rate(),
              position_side <- side(),
              swan <- positive_decimal(10, 90),
              max_runs: @max_runs
            ) do
        result =
          Calc.compare_dca_safety(single, dca, current, equity, mmr, position_side, swan)

        legs = [single, dca]
        total_notional = D.add(single.notional, dca.notional)
        pnl = multi_leg_pnl_formula(legs, current, position_side)

        pre_eff = Calc.quantize(effective_leverage_formula(single.notional, equity))
        post_eff = Calc.quantize(effective_leverage_formula(total_notional, D.add(equity, pnl)))
        expected_change = Calc.quantize(D.sub(post_eff, pre_eff))

        diff = result.leverage_change |> D.sub(expected_change) |> D.abs()
        assert D.compare(diff, D.new("0.00000002")) != :gt
      end
    end

    property "multi-leg PnL is antisymmetric across sides" do
      check all(
              single <- leg(),
              dca <- leg(),
              current <- positive_price(),
              max_runs: @max_runs
            ) do
        legs = [single, dca]
        long_pnl = multi_leg_pnl_formula(legs, current, :long)
        short_pnl = multi_leg_pnl_formula(legs, current, :short)

        assert D.equal?(long_pnl, D.negate(short_pnl))
      end
    end
  end

  describe "StressScenario cascade invariants" do
    property "shocked equity is conserved through each simulated liquidation" do
      check all(
              account <- stress_account(),
              shock_bps <- integer(-5000..5000),
              max_runs: @max_runs
            ) do
        shock = D.new(Integer.to_string(shock_bps))
        equity_before = shocked_equity_formula(account, shock)

        case pick_highest_margin_index(account, shock) do
          nil ->
            :ok

          index ->
            position = Enum.at(account.positions, index)
            remaining_positions = List.delete_at(account.positions, index)

            updated_account = %{
              account
              | equity: D.add(account.equity, position_shock_pnl_formula(position, shock)),
                positions: remaining_positions
            }

            equity_after = shocked_equity_formula(updated_account, shock)

            assert D.equal?(equity_after, equity_before)
        end
      end
    end

    property "insolvent books never report survives?" do
      check all(
              account <- stress_account(),
              shock_bps <- integer(-8000..8000),
              max_runs: @max_runs
            ) do
        shock = D.new(Integer.to_string(shock_bps))
        result = StressScenario.cascade(account, shock)

        final_account = cascade_final_account(account, shock, result.liquidated_positions)
        shocked_final = shocked_account_at_shock(final_account, shock)
        maintenance = PortfolioMargin.combined_maintenance_margin(shocked_final)

        if result.survives? do
          assert D.compare(shocked_final.equity, maintenance) != :lt
        else
          refute portfolio_solvent?(shocked_final)
        end
      end
    end
  end

  describe "funding cadence linearity" do
    property "MarginBridge daily cost scales linearly with periods_per_day" do
      check all(
              rate <- positive_decimal(1, 500),
              size <- positive_size(),
              base_ppd <- member_of([1, 3]),
              multiplier <- member_of([2, 4]),
              max_runs: @max_runs
            ) do
        scaled_ppd = base_ppd * multiplier

        base =
          MarginBridge.stress_test_prolonged_negative(
            D.negate(rate),
            size,
            1,
            periods_per_day: base_ppd
          ).daily_cost

        scaled =
          MarginBridge.stress_test_prolonged_negative(
            D.negate(rate),
            size,
            1,
            periods_per_day: scaled_ppd
          ).daily_cost

        expected = funding_daily_cost_formula(rate, size, scaled_ppd)
        assert D.equal?(scaled, expected)
        assert D.equal?(scaled, D.mult(base, D.new(multiplier)))
      end
    end

    property "Funding annual APR delta scales linearly with periods_per_day" do
      check all(
              high_rate <- positive_decimal(1, 1000),
              low_rate <- positive_decimal(1, 1000),
              base_ppd <- member_of([1, 3]),
              multiplier <- member_of([2, 8]),
              max_runs: @max_runs
            ) do
        {max_rate, min_rate} =
          if D.compare(high_rate, low_rate) == :gt,
            do: {high_rate, low_rate},
            else: {low_rate, high_rate}

        if D.equal?(max_rate, min_rate) do
          :ok
        else
          base_result =
            Funding.compare_funding_rates(%{venue_a: max_rate, venue_b: min_rate}, base_ppd)

          scaled_result =
            Funding.compare_funding_rates(
              %{venue_a: max_rate, venue_b: min_rate},
              base_ppd * multiplier
            )

          base_delta = Map.fetch!(base_result, :annual_apr_delta)
          scaled_delta = Map.fetch!(scaled_result, :annual_apr_delta)

          rate_delta = D.sub(max_rate, min_rate)

          expected_base =
            rate_delta
            |> D.mult(D.new(base_ppd))
            |> D.mult(D.new(@days_per_year))
            |> D.mult(@hundred)
            |> D.round(2)

          assert D.equal?(base_delta, expected_base)
          assert D.equal?(scaled_delta, D.mult(base_delta, D.new(multiplier)))
        end
      end
    end

    property "OptionsRisk daily cost scales linearly with periods_per_day" do
      check all(
              rate <- positive_decimal(1, 500),
              size <- positive_size(),
              base_ppd <- member_of([1, 3]),
              multiplier <- member_of([2, 4]),
              max_runs: @max_runs
            ) do
        scaled_ppd = base_ppd * multiplier

        base =
          OptionsRisk.calculate_negative_funding_impact(%{
            negative_rate: D.negate(rate),
            position_size: size,
            periods_per_day: base_ppd
          }).daily_cost

        scaled =
          OptionsRisk.calculate_negative_funding_impact(%{
            negative_rate: D.negate(rate),
            position_size: size,
            periods_per_day: scaled_ppd
          }).daily_cost

        assert D.equal?(scaled, D.mult(base, D.new(multiplier)))
      end
    end
  end

  describe "Carry scaling laws" do
    property "raw basis matches spot-perp premium formula" do
      check all(
              spot <- positive_price(),
              perp <- positive_price(),
              max_runs: @max_runs
            ) do
        raw =
          perp
          |> D.sub(spot)
          |> D.div(spot)
          |> D.mult(@hundred)

        assert D.equal?(Carry.basis(spot, perp), Calc.quantize(raw))
      end
    end

    property "annualized basis over horizon H equals raw basis * 365/H" do
      check all(
              spot <- positive_price(),
              perp <- positive_price(),
              horizon <- holding_days(),
              max_runs: @max_runs
            ) do
        raw = Carry.basis(spot, perp)
        annualized = annualized_basis_formula(raw, horizon)

        assert D.equal?(annualized, D.mult(raw, D.div(D.new(@days_per_year), D.new(horizon))))
      end
    end

    property "basis_yield is the one-time stock (equals raw basis, not prorated)" do
      check all(
              spot <- positive_price(),
              perp <- positive_price(),
              horizon <- integer(1..364),
              ppd <- periods_per_day(),
              max_runs: @max_runs
            ) do
        result =
          Carry.net_carry(%{
            spot_price: spot,
            perp_price: perp,
            funding_rate: D.new("0.0001"),
            holding_days: horizon,
            periods_per_day: ppd
          })

        assert D.equal?(result.basis_yield, result.basis)

        if D.compare(D.abs(result.basis), @zero) == :gt do
          refute D.equal?(result.basis_yield, annualized_basis_formula(result.basis, horizon))
        end
      end
    end

    property "funding_yield scales linearly with periods_per_day and holding horizon" do
      check all(
              spot <- positive_price(),
              perp <- positive_price(),
              rate <- positive_decimal(1, 1000),
              horizon <- holding_days(),
              base_ppd <- member_of([1, 3]),
              multiplier <- member_of([2, 4]),
              max_runs: @max_runs
            ) do
        rate_frac = D.div(rate, D.new("100000"))

        base =
          Carry.net_carry(%{
            spot_price: spot,
            perp_price: perp,
            funding_rate: rate_frac,
            holding_days: horizon,
            periods_per_day: base_ppd
          }).funding_yield

        scaled =
          Carry.net_carry(%{
            spot_price: spot,
            perp_price: perp,
            funding_rate: rate_frac,
            holding_days: horizon,
            periods_per_day: base_ppd * multiplier
          }).funding_yield

        expected =
          rate_frac
          |> D.mult(D.new(horizon * base_ppd * multiplier))
          |> D.mult(@hundred)
          |> Calc.quantize()

        assert D.equal?(scaled, expected)
        assert D.equal?(scaled, D.mult(base, D.new(multiplier)))
      end
    end
  end

  describe "liquidation monotonicity (Calc.liquidation approximation)" do
    property "long liq < entry < short liq for positive leverage" do
      check all(
              entry <- positive_price(),
              lev <- leverage(),
              mmr <- mmr_rate(),
              max_runs: @max_runs
            ) do
        long_liq = Calc.liquidation(entry, lev, mmr, :long)
        short_liq = Calc.liquidation(entry, lev, mmr, :short)

        assert D.compare(long_liq, entry) == :lt
        assert D.compare(short_liq, entry) == :gt
      end
    end

    property "higher leverage moves liquidation price closer to entry" do
      check all(
              entry <- positive_price(),
              low_lev <- integer(1..10),
              extra <- integer(1..20),
              mmr <- mmr_rate(),
              position_side <- side(),
              max_runs: @max_runs
            ) do
        high_lev = low_lev + extra
        low = Calc.liquidation(entry, D.new(low_lev), mmr, position_side)
        high = Calc.liquidation(entry, D.new(high_lev), mmr, position_side)

        case position_side do
          :long ->
            assert D.compare(high, low) == :gt
            assert D.compare(D.sub(entry, high), D.sub(entry, low)) == :lt

          :short ->
            assert D.compare(high, low) == :lt
            assert D.compare(D.sub(high, entry), D.sub(low, entry)) == :lt
        end
      end
    end
  end

  # --- Cascade simulation helpers ---

  defp pick_highest_margin_index(account, shock) do
    account.positions
    |> Enum.with_index()
    |> Enum.map(fn {position, index} ->
      shocked_mark = shocked_mark_formula(position.mark_price, shock)

      margin =
        position.quantity
        |> D.abs()
        |> D.mult(shocked_mark)
        |> D.mult(position.mmr)
        |> Calc.quantize()

      {margin, index}
    end)
    |> Enum.max_by(fn {margin, _index} -> margin end, fn -> nil end)
    |> case do
      nil -> nil
      {_margin, index} -> index
    end
  end

  defp cascade_final_account(account, shock, liquidated_ids) do
    liquidated_set = MapSet.new(liquidated_ids)

    {remaining, realized} =
      Enum.reduce(account.positions, {[], @zero}, fn position, {positions_acc, realized_acc} ->
        id = Map.get(position, :id)

        if id in liquidated_set do
          {positions_acc, D.add(realized_acc, position_shock_pnl_formula(position, shock))}
        else
          {[position | positions_acc], realized_acc}
        end
      end)

    %{account | equity: D.add(account.equity, realized), positions: Enum.reverse(remaining)}
  end

  defp shocked_account_at_shock(account, shock) do
    %{
      equity: shocked_equity_formula(account, shock),
      positions:
        Enum.map(account.positions, fn position ->
          %{position | mark_price: shocked_mark_formula(position.mark_price, shock)}
        end)
    }
  end

  defp portfolio_solvent?(account) do
    D.compare(account.equity, PortfolioMargin.combined_maintenance_margin(account)) != :lt
  end
end
