defmodule DeltaCalc.ManifestTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Manifest

  @expected_modules [
    "DeltaCalc.Decimal",
    "DeltaCalc.Leverage",
    "DeltaCalc.Liquidation",
    "DeltaCalc.Allocation",
    "DeltaCalc.Safety",
    "DeltaCalc.Presets",
    "DeltaCalc.DCAPlanner",
    "DeltaCalc.Quantization",
    "DeltaCalc.PositionCalculator",
    "DeltaCalc.Hedging",
    "DeltaCalc.Funding",
    "DeltaCalc.AccountMetrics",
    "DeltaCalc.Concentration",
    "DeltaCalc.MarginBridge",
    "DeltaCalc.FundingProjection",
    "DeltaCalc.OptionLadder",
    "DeltaCalc.OptionsRisk",
    "DeltaCalc.Pnl",
    "DeltaCalc.DeltaNeutral",
    "DeltaCalc.PortfolioMargin",
    "DeltaCalc.StressScenario",
    "DeltaCalc.Fees",
    "DeltaCalc.Carry"
  ]

  describe "build/0" do
    test "returns a manifest with version and all calculator modules" do
      manifest = Manifest.build()

      assert is_map(manifest)
      assert manifest.version == "1.0"
      assert is_binary(manifest.generated_at)

      module_names =
        manifest.modules
        |> Enum.map(& &1.module)
        |> Enum.sort()

      assert module_names == Enum.sort(@expected_modules)
    end

    test "includes every api()-annotated public function" do
      manifest = Manifest.build()

      api_keys =
        Manifest.modules()
        |> Enum.flat_map(fn mod ->
          Enum.map(mod.__api__(), fn entry -> {mod, entry.name, entry.arity} end)
        end)
        |> MapSet.new()

      manifest_keys =
        manifest.modules
        |> Enum.flat_map(fn mod_entry ->
          mod = Module.concat([mod_entry.module])

          Enum.map(mod_entry.functions, fn fn_entry ->
            {mod, String.to_existing_atom(fn_entry.name), fn_entry.arity}
          end)
        end)
        |> MapSet.new()

      assert MapSet.subset?(api_keys, manifest_keys)
    end

    test "advertises exact scalar and structured inputs as canonical decimal strings" do
      manifest = Manifest.build()

      funding_apr = manifest_function!(manifest, "DeltaCalc.Funding", "funding_apr")

      position =
        manifest_function!(manifest, "DeltaCalc.PositionCalculator", "calculate_position")

      assert get_in(funding_apr, [:hints, :params, :rate, :schema]) == %{"type" => "string"}

      assert get_in(position, [
               :hints,
               :params,
               :params,
               :schema,
               "properties",
               "entry_price",
               "type"
             ]) == "string"

      assert get_in(position, [
               :hints,
               :params,
               :params,
               :schema,
               "properties",
               "side"
             ]) == %{"type" => "string", "enum" => ["long", "short"]}
    end
  end

  describe "tools/0" do
    test "returns MCP tool definitions for every api()-annotated function" do
      tools = Manifest.tools()

      expected_count =
        Manifest.modules()
        |> Enum.map(& &1.__api__())
        |> List.flatten()
        |> length()

      assert length(tools) == expected_count

      for tool <- tools do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert %{type: "object"} = tool.inputSchema
      end
    end

    test "tool names use short module prefixes" do
      tool_names = Manifest.tools() |> Enum.map(& &1.name) |> Enum.sort()

      assert "leverage__effective_leverage" in tool_names
      assert "liquidation__liquidation" in tool_names
      assert "allocation__allocate" in tool_names
      assert "safety__safety" in tool_names
      assert "dca_planner__dca_ladder" in tool_names
      assert "dca_planner__convert_ladder_for_short" in tool_names
      assert "quantization__quantize" in tool_names
      assert "hedging__calculate_required_cex_balance" in tool_names
      assert "position_calculator__calculate_position" in tool_names
      assert "funding__funding_apr" in tool_names
      assert "account_metrics__calculate" in tool_names
      assert "concentration__hhi" in tool_names
      assert "margin_bridge__margin_ratio" in tool_names
      assert "margin_bridge__payback_timeline" in tool_names
      assert "funding_projection__project_payback_timeline" in tool_names
      assert "option_ladder__optimal_expiries" in tool_names
      assert "options_risk__max_loss" in tool_names
      assert "pnl__unrealized_pnl" in tool_names
      assert "delta_neutral__net_delta" in tool_names
      assert "portfolio_margin__combined_maintenance_margin" in tool_names
      assert "stress_scenario__apply_shock" in tool_names
      assert "fees__effective_entry" in tool_names
      assert "carry__basis" in tool_names
    end

    test "bare function names are unique across modules" do
      bare_names =
        Manifest.modules()
        |> Enum.flat_map(fn mod ->
          Enum.map(mod.__api__(), fn entry -> {entry.name, mod} end)
        end)

      collisions =
        bare_names
        |> Enum.group_by(fn {name, _mod} -> name end, fn {_name, mod} -> mod end)
        |> Enum.reject(fn {_name, [_]} -> true end)

      assert collisions == [],
             "Duplicate bare api names across modules: #{inspect(collisions)}"
    end

    test "canonical decimal strings survive MCP JSON transport and invalid exact inputs fail" do
      tool = Enum.find(Manifest.tools(), &(&1.name == "carry__basis"))
      exact = "9007199254740993.1234567890123456"

      assert get_in(tool, [:inputSchema, :properties, :spot_price, "type"]) == "string"
      assert get_in(tool, [:inputSchema, :properties, :perp_price, "type"]) == "string"

      transported =
        %{tool: tool.name, arguments: %{spot_price: exact, perp_price: exact}}
        |> Jason.encode!()
        |> Jason.decode!()

      transported_exact = get_in(transported, ["arguments", "spot_price"])

      assert transported_exact == exact
      assert Decimal.equal?(DeltaCalc.Decimal.cast!(transported_exact), Decimal.new(exact))
      assert Decimal.equal?(DeltaCalc.Decimal.cast!(Decimal.new("1.25")), Decimal.new("1.25"))
      assert Decimal.equal?(DeltaCalc.Decimal.cast!(7), Decimal.new(7))

      assert_raise ArgumentError, ~r/canonical decimal string/, fn ->
        DeltaCalc.Decimal.cast!("12.34oops")
      end

      assert_raise ArgumentError, ~r/canonical decimal string/, fn ->
        DeltaCalc.Decimal.cast!(0.1)
      end
    end
  end

  describe "modules/0" do
    test "returns the calculator module list" do
      assert Manifest.modules() == [
               DeltaCalc.Decimal,
               DeltaCalc.Leverage,
               DeltaCalc.Liquidation,
               DeltaCalc.Allocation,
               DeltaCalc.Safety,
               DeltaCalc.Presets,
               DeltaCalc.DCAPlanner,
               DeltaCalc.Quantization,
               DeltaCalc.PositionCalculator,
               DeltaCalc.Hedging,
               DeltaCalc.Funding,
               DeltaCalc.AccountMetrics,
               DeltaCalc.Concentration,
               DeltaCalc.MarginBridge,
               DeltaCalc.FundingProjection,
               DeltaCalc.OptionLadder,
               DeltaCalc.OptionsRisk,
               DeltaCalc.Pnl,
               DeltaCalc.DeltaNeutral,
               DeltaCalc.PortfolioMargin,
               DeltaCalc.StressScenario,
               DeltaCalc.Fees,
               DeltaCalc.Carry
             ]
    end
  end

  defp manifest_function!(manifest, module_name, function_name) do
    manifest.modules
    |> Enum.find(&(&1.module == module_name))
    |> Map.fetch!(:functions)
    |> Enum.find(&(&1.name == function_name))
  end
end
