defmodule DeltaCalc.UsageRulesTest do
  use ExUnit.Case, async: true

  @skill_names ["igniter", "sobelow"]

  test "declares usage_rules as a dev-only dependency" do
    deps = DeltaCalc.MixProject.project()[:deps]
    assert {:usage_rules, "~> 1.2", only: :dev, runtime: false} in deps
  end

  test "builds skills only for rule-shipping deps a current model knows poorly" do
    config = DeltaCalc.MixProject.project()[:usage_rules]
    skills = config[:skills]
    build = skills[:build]

    assert skills[:location] == ".agents/skills"
    assert Keyword.keys(build) == [:igniter, :sobelow]
    assert build[:igniter][:usage_rules] == [:igniter]
    assert build[:sobelow][:usage_rules] == [:sobelow]
  end

  test "generated skills are present and reachable from both agent skill roots" do
    assert {:ok, "../.agents/skills"} = File.read_link(".claude/skills")

    agents = Path.expand(".agents/skills")
    claude = Path.expand(".claude/skills")
    assert Path.expand(File.read_link!(claude), Path.dirname(claude)) == agents

    Enum.each(@skill_names, fn name ->
      skill = Path.join([agents, name, "SKILL.md"])
      assert File.exists?(skill), "missing generated skill #{skill}"
      assert File.exists?(Path.join([claude, name, "SKILL.md"]))
    end)
  end
end
