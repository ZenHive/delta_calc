defmodule DeltaCalc.MixAliasesTest do
  use ExUnit.Case, async: true

  # Before Task 61, check.dispatch also ran `test`, `credo --strict`, and
  # `ex_dna --max-clones 0`. Those remain in `ci`, listed independently — nested
  # `check.dispatch` would make slimming dispatch silently drop them from QA.

  test "dispatch expands only to formatting and compilation" do
    assert steps("check.dispatch") == [
             "format --check-formatted",
             "compile --warnings-as-errors"
           ]

    refute Enum.any?(expand("check.dispatch"), &analyzer_step?/1)
    assert DeltaCalc.MixProject.cli()[:preferred_envs][:"check.dispatch"] == :test
  end

  test "CI retains the full suite and analyzers independently of dispatch" do
    assert steps("ci") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test",
             "credo --strict",
             "dialyzer",
             "ex_dna --max-clones 0",
             "reach.check --arch --smells"
           ]

    refute "check.dispatch" in steps("ci")
    assert DeltaCalc.MixProject.project()[:test_coverage][:summary][:threshold] == 80
  end

  test "legacy full precommit retains documentation, coverage and dev Dialyzer" do
    assert steps("precommit.full") == [
             "precommit",
             "cmd env MIX_ENV=dev mix dialyzer"
           ]

    refute "check.dispatch" in steps("precommit")
    refute "check.dispatch" in steps("precommit.full")

    assert expand("precommit.full") == [
             "compile --warnings-as-errors",
             "deps.unlock --unused",
             "format",
             "credo --strict --all",
             "doctor",
             "test.json --quiet --cover",
             "cmd env MIX_ENV=dev mix dialyzer"
           ]
  end

  defp analyzer_step?(step) do
    String.contains?(step, [
      "test",
      "credo",
      "dialyzer",
      "doctor",
      "sobelow",
      "ex_dna",
      "reach",
      "cover"
    ])
  end

  defp steps(task) do
    aliases = DeltaCalc.MixProject.project()[:aliases]

    case Enum.find(aliases, fn {name, _steps} -> to_string(name) == task end) do
      {_, nested} -> nested
      nil -> flunk("missing mix alias #{task}")
    end
  end

  defp expand(task) do
    aliases = DeltaCalc.MixProject.project()[:aliases]

    case Enum.find(aliases, fn {name, _steps} -> to_string(name) == task end) do
      {_, nested} -> Enum.flat_map(nested, &expand/1)
      nil -> [task]
    end
  end
end
