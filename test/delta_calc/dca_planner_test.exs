defmodule DeltaCalc.DCAPlannerTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias DeltaCalc.{DCAPlanner, PositionCalculator, Presets}

  @config %{risk_modes: Presets.load_modes()}

  defp position_setup(overrides \\ []) do
    params =
      Map.merge(
        %{
          aum: D.new("10000"),
          mode: :conservative,
          side: :long,
          entry_price: D.new("3000"),
          subaccount_allocation: D.new("100"),
          initial_position_pct: D.new("0.5"),
          black_swan_pct: D.new("0.15"),
          ui_leverage: D.new("2"),
          mmr_rate: D.new("0.005"),
          mark_buffer: D.new("0.001"),
          fee_rate: D.new("0.0004")
        },
        Map.new(overrides)
      )

    pos = PositionCalculator.calculate_position(params, @config)

    dca_params = %{
      params: %{
        dca_enabled: true,
        defensive_prices: [D.new("2850"), D.new("2700")],
        aggressive_prices: [D.new("3150"), D.new("3300")],
        dca_allocations: [D.new("30"), D.new("30")]
      },
      position_with_tokens: pos.position,
      dca_reserve: pos.allocation.reserve,
      entry_price: params.entry_price,
      ui_leverage: params.ui_leverage,
      side: params.side,
      mmr_rate: params.mmr_rate,
      mark_buffer: params.mark_buffer,
      aum: params.aum,
      black_swan_pct: params.black_swan_pct
    }

    {dca_params, pos}
  end

  describe "calculate_dca_ladder/1" do
    # Independent DCA golden — provenance: hand calc from the public
    # DCAPlanner.calculate_dca_ladder/1 contract.
    # Base position (conservative, ui=2, init_pct=0.5, entry=3000):
    #   sub_eq=100; init=50; reserve=50; notional=50×2=100; tokens=100/3000
    # Defensive step 1 price=2850 (caller-supplied), alloc=30% of reserve:
    #   spend = 50 × 0.30 = 15; add_notional = 15 × 2 = 30
    #   cumulative_notional = 100 + 30 = 130
    #   lev_to_aum = 130 / 10000 = 0.013
    #   black_swan @ 15%: 3000 × 0.85 = 2550
    test "returns defensive and aggressive strategies with enhanced steps" do
      {dca_params, _pos} = position_setup()
      result = DCAPlanner.calculate_dca_ladder(dca_params)

      assert %{defensive: defensive, aggressive: aggressive} = result
      assert [_, _] = defensive.steps
      assert [_, _] = aggressive.steps
      assert defensive.final_notional
      assert aggressive.final_notional

      first_def = Enum.at(defensive.steps, 0)
      assert D.eq?(first_def.dca_price, D.new("2850.00000000"), D.new("0.00000001"))
      assert D.eq?(first_def.spend, D.new("15.00000000"), D.new("0.00000001"))
      assert D.eq?(first_def.leverage_to_aum, D.new("0.01300000"), D.new("0.00000001"))
      assert first_def.passes_black_swan
      assert D.eq?(first_def.black_swan_price, D.new("2550.00000000"), D.new("0.00000001"))

      first_agg = Enum.at(aggressive.steps, 0)
      assert D.eq?(first_agg.dca_price, D.new("3150.00000000"), D.new("0.00000001"))
      assert D.compare(first_agg.dca_price, dca_params.entry_price) == :gt
    end

    test "returns nil when reserve is zero" do
      {dca_params, _} = position_setup(initial_position_pct: D.new("1"))
      assert DCAPlanner.calculate_dca_ladder(dca_params) == nil
    end

    test "returns nil when DCA is disabled" do
      {dca_params, _} = position_setup()
      disabled = put_in(dca_params.params[:dca_enabled], false)
      assert DCAPlanner.calculate_dca_ladder(disabled) == nil
    end

    test "short side converts default defensive preset upward" do
      {dca_params, _} = position_setup(side: :short)
      short_params = put_in(dca_params.params, %{dca_enabled: true})

      result = DCAPlanner.calculate_dca_ladder(short_params)

      assert D.equal?(Enum.at(result.defensive.steps, 0).dca_price, D.new("3150.00000000"))
      assert D.equal?(Enum.at(result.aggressive.steps, 0).dca_price, D.new("2850.00000000"))
    end
  end

  describe "build_defensive_preset/3" do
    test "converts custom prices and allocations to multipliers" do
      params = %{
        defensive_prices: [D.new("2850"), D.new("2700")],
        dca_allocations: [D.new("40"), D.new("30")]
      }

      preset = DCAPlanner.build_defensive_preset(params, D.new("3000"), :long)

      assert [{m1, a1}, {m2, a2}] = preset
      assert D.equal?(m1, D.new("0.95"))
      assert D.equal?(a1, D.new("0.40"))
      assert D.equal?(m2, D.new("0.90"))
      assert D.equal?(a2, D.new("0.30"))
    end

    test "falls back to dca_prices when defensive_prices empty" do
      params = %{
        defensive_prices: [],
        dca_prices: [D.new("2850")],
        dca_allocations: [D.new("40")]
      }

      preset = DCAPlanner.build_defensive_preset(params, D.new("3000"), :long)
      assert [{mult, alloc}] = preset
      assert D.equal?(mult, D.new("0.95"))
      assert D.equal?(alloc, D.new("0.40"))
    end

    test "uses converted default preset for short defensive" do
      preset = DCAPlanner.build_defensive_preset(%{}, D.new("3000"), :short)

      assert [{mult, alloc} | _] = preset
      assert D.equal?(mult, D.new("1.05"))
      assert D.equal?(alloc, D.new("0.30"))
    end
  end

  describe "build_aggressive_preset/3" do
    test "converts custom prices and allocations to multipliers" do
      params = %{
        aggressive_prices: [D.new("3150"), D.new("3300")],
        dca_allocations: [D.new("40"), D.new("30")]
      }

      preset = DCAPlanner.build_aggressive_preset(params, D.new("3000"), :long)

      assert [{m1, a1}, {m2, a2}] = preset
      assert D.equal?(m1, D.new("1.05"))
      assert D.equal?(a1, D.new("0.40"))
      assert D.equal?(m2, D.new("1.10"))
      assert D.equal?(a2, D.new("0.30"))
    end

    test "uses converted default preset for long aggressive" do
      preset = DCAPlanner.build_aggressive_preset(%{}, D.new("3000"), :long)

      assert [{mult, alloc} | _] = preset
      assert D.equal?(mult, D.new("1.05"))
      assert D.equal?(alloc, D.new("0.30"))
    end
  end

  describe "enhance_dca_steps/5" do
    test "adds leverage_to_aum, passes_black_swan, and black_swan_price per step" do
      steps = [
        %{
          cumulative_notional: D.new("130"),
          new_liq: D.new("695.40")
        }
      ]

      enhanced =
        DCAPlanner.enhance_dca_steps(
          steps,
          D.new("10000"),
          D.new("0.15"),
          D.new("3000"),
          :long
        )

      [step] = enhanced
      assert D.equal?(step.leverage_to_aum, D.new("0.01300000"))
      assert D.equal?(step.black_swan_price, D.new("2550.00000000"))
      assert step.passes_black_swan
    end

    test "short side inverts black swan pass check" do
      steps = [%{cumulative_notional: D.new("130"), new_liq: D.new("3000")}]

      [step] =
        DCAPlanner.enhance_dca_steps(
          steps,
          D.new("10000"),
          D.new("0.15"),
          D.new("3000"),
          :short
        )

      assert D.equal?(step.black_swan_price, D.new("3450.00000000"))
      refute step.passes_black_swan
    end

    test "returns Calc error when AUM is invalid" do
      steps = [%{cumulative_notional: D.new("130"), new_liq: D.new("695.40")}]

      assert DCAPlanner.enhance_dca_steps(
               steps,
               D.new("0"),
               D.new("0.15"),
               D.new("3000"),
               :long
             ) == {:error, :non_positive_total_aum}
    end
  end

  describe "Descripex api() declarations" do
    test "public functions are annotated with api() hints" do
      fns = [
        calculate_dca_ladder: 1,
        build_defensive_preset: 3,
        build_aggressive_preset: 3,
        enhance_dca_steps: 5
      ]

      {:docs_v1, _, :elixir, _, _, _, fn_docs} = Code.fetch_docs(DCAPlanner)

      for {name, arity} <- fns do
        doc =
          Enum.find(fn_docs, fn
            {{:function, ^name, ^arity}, _, _, _, _} -> true
            _ -> false
          end)

        assert doc, "Missing doc entry for #{name}/#{arity}"
        {{:function, ^name, ^arity}, _, _, _, meta} = doc
        assert Map.has_key?(meta, :hints), "Missing api() hints for #{name}/#{arity}"
      end
    end
  end
end
