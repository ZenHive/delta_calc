defmodule DeltaCalc.DiscoverableTest do
  @moduledoc """
  Progressive disclosure over the registered agent surface.

  Asserts every module in `DeltaCalc.Manifest.modules/0` resolves at all three
  levels, so a discovery walk (L1 → L2 → L3) never dead-ends on a module that was
  registered for the manifest but is unreachable by short name.
  """

  use ExUnit.Case, async: true

  alias DeltaCalc.Manifest

  describe "level 1 — library overview" do
    test "covers exactly the manifest module list, all Descripex-annotated" do
      overview = DeltaCalc.describe()

      assert Enum.map(overview, & &1.module) == Manifest.modules()
      assert Enum.all?(overview, & &1.annotated?)
      assert Enum.all?(overview, &(&1.function_count > 0))
      assert Enum.all?(overview, &is_binary(&1.description))
    end

    test "short names are unique, so every module is addressable at level 2" do
      short_names = Enum.map(DeltaCalc.describe(), & &1.short_name)

      assert length(Enum.uniq(short_names)) == length(short_names)
      assert "hedging" in short_names
      # Acronym segments underscore per `Macro.underscore/1`: DCAPlanner -> dca_planner.
      assert "dca_planner" in short_names
    end

    test "the discovery surface reads from the manifest registry" do
      assert DeltaCalc.__descripex_modules__() == Manifest.modules()
    end
  end

  describe "level 2 — module functions" do
    test "every module resolves by short name, full atom, and short atom alike" do
      for %{module: module, short_name: short_name} <- DeltaCalc.describe() do
        by_string = DeltaCalc.describe(short_name)

        assert by_string != [], "#{inspect(module)} advertises no functions at level 2"
        assert by_string == DeltaCalc.describe(module)
        assert by_string == DeltaCalc.describe(String.to_atom(short_name))
      end
    end

    test "every advertised function carries name, arity, description, and spec" do
      for %{short_name: short_name} <- DeltaCalc.describe(),
          func <- DeltaCalc.describe(short_name) do
        assert is_atom(func.name)
        assert is_integer(func.arity)
        assert is_binary(func.description) and func.description != ""
        assert is_binary(func.spec)
      end
    end

    test "an unknown short name raises with the available names" do
      assert_raise ArgumentError, ~r/no module found for short name "nope"/, fn ->
        DeltaCalc.describe("nope")
      end
    end
  end

  describe "level 3 — function detail" do
    test "every function of every module resolves with callable param detail" do
      for %{short_name: short_name} <- DeltaCalc.describe(),
          %{name: name, arity: arity} <- DeltaCalc.describe(short_name) do
        detail = DeltaCalc.describe(short_name, name)

        assert detail.name == name
        assert detail.arity == arity
        assert is_binary(detail.description)
        assert is_map(detail.returns)

        # Zero-arity functions legitimately have no params; anything else must
        # document each one, or an agent cannot construct the call.
        if arity - detail.defaults > 0 do
          assert map_size(detail.params) > 0,
                 "#{short_name}.#{name}/#{arity} advertises no params"
        end
      end
    end

    test "param kinds are the agent-facing vocabulary" do
      detail = DeltaCalc.describe("hedging", :check_hedge_coverage)

      assert Enum.all?(detail.params, fn {_name, param} ->
               param[:kind] in [:value, :exchange_data]
             end)
    end

    test "an unknown function name returns nil rather than raising" do
      assert DeltaCalc.describe("hedging", :no_such_function) == nil
    end
  end
end
