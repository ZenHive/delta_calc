defmodule DeltaCalc.MixAliasesTest do
  use ExUnit.Case, async: true

  test "dispatch expands only to formatting and compilation" do
    assert expand("check.dispatch") == [
             "format --check-formatted",
             "compile --warnings-as-errors"
           ]

    assert DeltaCalc.MixProject.cli()[:preferred_envs][:"check.dispatch"] == :test
  end

  test "CI retains the full suite and analyzers independently of dispatch" do
    assert expand("ci") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test",
             "credo --strict",
             "dialyzer",
             "ex_dna --max-clones 0",
             "reach.check --arch --smells"
           ]

    assert DeltaCalc.MixProject.project()[:test_coverage][:summary][:threshold] == 80
  end

  test "legacy full precommit retains documentation, coverage and dev Dialyzer" do
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

  defp expand(task) do
    aliases = DeltaCalc.MixProject.project()[:aliases]

    case Enum.find(aliases, fn {name, _steps} -> Atom.to_string(name) == task end) do
      {_, steps} -> Enum.flat_map(steps, &expand/1)
      nil -> [task]
    end
  end
end
