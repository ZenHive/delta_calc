defmodule DeltaCalc.ManifestConsistencyTest do
  @moduledoc """
  Global invariants for `DeltaCalc.Manifest` that per-module review cannot see.

  Enforces uniqueness of public function name+arity across registered modules,
  full registration of every api()-bearing module under `lib/delta_calc/`,
  `:hints` metadata on every advertised function, and complete api() coverage
  of every public function in registered modules.

  Note: the review convention that an advertised option must actually change output
  is not checked here — that would require mutation testing or behavioral fixtures.
  """

  use ExUnit.Case, async: true

  alias DeltaCalc.Manifest

  @lib_delta_calc Path.expand("../../lib/delta_calc", __DIR__)

  describe "registered module surface" do
    test "public function name+arity is unique across all registered modules" do
      collisions =
        Manifest.modules()
        |> Enum.flat_map(fn mod ->
          Enum.map(mod.__api__(), fn entry -> {entry.name, entry.arity, mod} end)
        end)
        |> Enum.group_by(fn {name, arity, _mod} -> {name, arity} end)
        |> Enum.reject(fn {_key, [_single]} -> true end)
        |> Enum.map(fn {{name, arity}, entries} ->
          modules = Enum.map(entries, &elem(&1, 2))
          {name, arity, modules}
        end)
        |> Enum.sort()

      assert collisions == [],
             """
             Duplicate public function name+arity across registered modules:
             #{format_collisions(collisions)}
             """
    end

    test "every lib/delta_calc module with api() functions is registered in Manifest" do
      registered = MapSet.new(Manifest.modules())
      api_modules = api_modules_from_lib()

      unregistered =
        api_modules
        |> Enum.reject(&MapSet.member?(registered, &1))
        |> Enum.sort()

      assert unregistered == [],
             """
             Modules exposing api() functions are missing from DeltaCalc.Manifest @modules:
             #{Enum.map_join(unregistered, "\n", &"  - #{inspect(&1)}")}
             """
    end

    test "every publicly documented lib/delta_calc module is registered in Manifest" do
      registered = MapSet.new(Manifest.modules())

      unregistered =
        documented_modules_from_lib()
        |> Enum.reject(&MapSet.member?(registered, &1))
        |> Enum.sort()

      assert unregistered == [],
             """
             Publicly documented lib/delta_calc modules missing from DeltaCalc.Manifest @modules
             (annotate with api() and register, or hide with @moduledoc false):
             #{Enum.map_join(unregistered, "\n", &"  - #{inspect(&1)}")}
             """
    end

    test "every public function in a registered module carries :hints metadata" do
      missing =
        Manifest.modules()
        |> Enum.flat_map(&missing_hints_for_module/1)
        |> Enum.sort()

      assert missing == [],
             """
             Registered public functions missing api() :hints metadata:
             #{Enum.map_join(missing, "\n", &"  - #{&1}")}
             """
    end

    test "every public function in a registered module is advertised via api()" do
      unadvertised =
        Manifest.modules()
        |> Enum.flat_map(&unadvertised_public_functions/1)
        |> Enum.sort()

      assert unadvertised == [],
             """
             Registered public functions missing api() advertisement:
             #{Enum.map_join(unadvertised, "\n", &"  - #{&1}")}
             """
    end

    test "advertised arity set includes default-argument arities" do
      entries = [%{name: :funding_apr, arity: 2, defaults: 1}]
      arities = advertised_arities(entries)

      assert MapSet.member?(arities, {:funding_apr, 1})
      assert MapSet.member?(arities, {:funding_apr, 2})
      refute MapSet.member?(arities, {:funding_apr, 3})
    end

    test "position sizing advertises only its behavior-driving input map" do
      [api] = DeltaCalc.PositionCalculator.__api__()

      assert api.arity == 1
      assert api.param_order == [:params]
      assert Map.keys(api.hints.params) == [:params]
      refute api.hints.params.params.description =~ "fee_rate"
      refute api.hints.params.params.description =~ "mode"
      refute api.hints.params.params.description =~ "config"
    end

    test "DCA metadata distinguishes side-specific prices from side-driven liquidation" do
      api = DeltaCalc.Calc.__api__(:dca_ladder)

      assert api.hints.params.ladder_preset.description =~ "side-specific"
      assert api.hints.params.side.description =~ "liquidation"
      assert api.hints.params.opts.description =~ ":mark_buffer"
    end

    test "multi-leg position advertises its side-aware public arity" do
      api = DeltaCalc.Calc.__api__(:multi_leg_position)

      assert api.arity == 4
      assert api.defaults == 1
      assert api.param_order == [:legs, :current_price, :initial_equity, :side]
      assert api.hints.params.side.default == :long
      assert api.hints.params.side.description =~ ":short"
      assert function_exported?(DeltaCalc.Calc, :multi_leg_position, 4)
    end

    test "MCP input schemas never advertise exact values as JSON numbers" do
      offenders =
        Manifest.tools()
        |> Enum.flat_map(fn tool ->
          number_schema_paths(tool.inputSchema)
          |> Enum.map(&{tool.name, &1})
        end)

      assert offenders == [],
             "JSON-number input schemas permit inexact binary floats: #{inspect(offenders)}"
    end

    test "structured exact fields retain natural schemas for non-exact values" do
      tool =
        Enum.find(
          Manifest.tools(),
          &(&1.name == "options_risk__calculate_negative_funding_impact")
        )

      properties = get_in(tool, [:inputSchema, :properties, :params, "properties"])

      assert properties["negative_rate"] == %{"type" => "string"}
      assert properties["position_size"] == %{"type" => "string"}
      assert properties["periods_per_day"] == %{"type" => "integer", "minimum" => 1}
      assert properties["capital_protected"] == %{"type" => "boolean"}
    end
  end

  defp number_schema_paths(value, path \\ [])

  defp number_schema_paths(%{"type" => "number"}, path), do: [Enum.reverse(path)]

  defp number_schema_paths(value, path) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} -> number_schema_paths(nested, [key | path]) end)
  end

  defp number_schema_paths(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested, index} -> number_schema_paths(nested, [index | path]) end)
  end

  defp number_schema_paths(_value, _path), do: []

  defp api_modules_from_lib do
    @lib_delta_calc
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reject(&(&1 == "manifest.ex"))
    |> Enum.map(&module_from_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&api_module?/1)
    |> Enum.sort()
  end

  defp module_from_file(filename) do
    path = Path.join(@lib_delta_calc, filename)

    with {:ok, source} <- File.read(path),
         [_, mod_str] <- Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, source) do
      Module.concat([mod_str])
    else
      _ -> nil
    end
  end

  defp documented_modules_from_lib do
    @lib_delta_calc
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reject(&(&1 == "manifest.ex"))
    |> Enum.map(&module_from_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&publicly_documented?/1)
    |> Enum.sort()
  end

  defp publicly_documented?(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        case Code.fetch_docs(mod) do
          {:docs_v1, _, _, _, moduledoc, _, _} -> is_map(moduledoc)
          _ -> false
        end

      {:error, _} ->
        false
    end
  end

  defp api_module?(mod) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        function_exported?(mod, :__api__, 0) and mod.__api__() != []

      {:error, _} ->
        false
    end
  end

  @generated_functions [:__api__]

  defp unadvertised_public_functions(mod) do
    advertised = advertised_arities(mod.__api__())

    mod.__info__(:functions)
    |> Enum.reject(fn {name, arity} ->
      name in @generated_functions or MapSet.member?(advertised, {name, arity})
    end)
    |> Enum.map(fn {name, arity} -> "#{inspect(mod)}.#{name}/#{arity}" end)
  end

  defp advertised_arities(api_entries) do
    api_entries
    |> Enum.flat_map(fn %{name: name, arity: arity, defaults: defaults} ->
      min_arity = arity - defaults

      for a <- min_arity..arity do
        {name, a}
      end
    end)
    |> MapSet.new()
  end

  defp missing_hints_for_module(mod) do
    docs = fetch_module_docs!(mod)

    mod.__api__()
    |> Enum.reject(&function_has_hints?(&1, docs))
    |> Enum.map(fn %{name: name, arity: arity} ->
      "#{inspect(mod)}.#{name}/#{arity}"
    end)
  end

  defp fetch_module_docs!(mod) do
    case Code.fetch_docs(mod) do
      {:docs_v1, _, _, _, _, _, docs} -> docs
      other -> flunk("Expected docs for #{inspect(mod)}, got: #{inspect(other)}")
    end
  end

  defp function_has_hints?(%{name: name, arity: arity}, docs) do
    Enum.any?(docs, fn
      {{:function, ^name, ^arity}, _, _, _, meta} -> Map.has_key?(meta, :hints)
      _ -> false
    end)
  end

  defp format_collisions(collisions) do
    Enum.map_join(collisions, "\n", fn {name, arity, modules} ->
      module_names = Enum.map_join(modules, ", ", &inspect/1)
      "  - #{name}/#{arity} in #{module_names}"
    end)
  end
end
