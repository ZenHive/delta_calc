defmodule DeltaCalc.ManifestTest do
  use ExUnit.Case, async: true

  alias DeltaCalc.Manifest

  @expected_modules [
    "DeltaCalc.Calc",
    "DeltaCalc.Presets",
    "DeltaCalc.DCAPlanner",
    "DeltaCalc.PositionCalculator",
    "DeltaCalc.Hedging",
    "DeltaCalc.Funding",
    "DeltaCalc.AccountMetrics",
    "DeltaCalc.Concentration",
    "DeltaCalc.MarginBridge",
    "DeltaCalc.FundingProjection",
    "DeltaCalc.OptionLadder",
    "DeltaCalc.OptionsRisk"
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

      assert "calc__effective_leverage" in tool_names
      assert "hedging__calculate_required_cex_balance" in tool_names
      assert "position_calculator__calculate_position" in tool_names
      assert "funding__funding_apr" in tool_names
      assert "account_metrics__calculate" in tool_names
      assert "concentration__hhi" in tool_names
      assert "margin_bridge__margin_ratio" in tool_names
      assert "funding_projection__project_payback_timeline" in tool_names
      assert "option_ladder__optimal_expiries" in tool_names
      assert "options_risk__max_loss" in tool_names
    end
  end

  describe "modules/0" do
    test "returns the calculator module list" do
      assert Manifest.modules() == [
               DeltaCalc.Calc,
               DeltaCalc.Presets,
               DeltaCalc.DCAPlanner,
               DeltaCalc.PositionCalculator,
               DeltaCalc.Hedging,
               DeltaCalc.Funding,
               DeltaCalc.AccountMetrics,
               DeltaCalc.Concentration,
               DeltaCalc.MarginBridge,
               DeltaCalc.FundingProjection,
               DeltaCalc.OptionLadder,
               DeltaCalc.OptionsRisk
             ]
    end
  end
end
