defmodule DeltaCalc.ReadmeExamplesTest do
  @moduledoc """
  Executes README examples using the README's own alias setup.

  Expected values are parsed and inspected to canonicalize map order and multiline
  layout; Decimal scale remains significant. `#Decimal<x>` in `#=>` comments is
  converted to `Decimal.new/1` only to parse the literal — asserted README results
  must stay in IEx inspect form. Tail elisions compare every documented position;
  only `...` positions are skipped. The census distinguishes partial elisions
  from whole-result elisions so neither can silently weaken the gate.
  """

  use ExUnit.Case, async: true

  @readme Path.expand("../../README.md", __DIR__)
  @decimal ~r/#Decimal<([^>]+)>/
  @elision :__readme_elision__
  @tail :__readme_tail__

  test "README examples match their documented results" do
    blocks = @readme |> File.read!() |> blocks()
    [setup] = Enum.filter(blocks, &Regex.match?(~r/^alias /m, &1.code))
    examples = Enum.flat_map(blocks, &examples/1)
    {elided, asserted} = Enum.split_with(examples, &elided?/1)

    {whole, partial} = Enum.split_with(elided, &(parse_subset(&1.documented) == @elision))

    assert {length(asserted), length(partial), length(whole)} == {39, 14, 0},
           "README census changed: #{length(asserted)} full, #{length(partial)} partial, #{length(whole)} whole elisions"

    # 44 concrete map values plus three :ok tuple tags.
    concrete = Enum.sum(Enum.map(partial, &concrete_count(parse_subset(&1.documented))))

    assert concrete == 47,
           "README partial-elision census changed: #{concrete} concrete positions inside elisions"

    dialect_drift = Enum.filter(examples, &String.contains?(&1.documented, "Decimal.new("))

    assert dialect_drift == [],
           """
           asserted README #=> results must document IEx inspect form (#Decimal<...>), not Decimal.new/1:
           #{Enum.map_join(dialect_drift, "\n", &"README.md:#{&1.line}")}
           """

    Enum.each(examples, &check_example(&1, setup.code))
  end

  test "extracts multiple results, multiline comments and setup in an Elixir fence only" do
    markdown = """
    ```text
    ignored()
    #=> 99
    ```
    ```elixir
    x = Decimal.new("1.00")
    {x, :ok}
    #=> {#Decimal<1.00>, :ok}

    [x, Decimal.add(x, 1)]
    #=> [
    #     #Decimal<1.00>,
    #     #Decimal<2.00>
    #   ]
    ```
    """

    [first, second] = markdown |> blocks() |> Enum.flat_map(&examples/1)
    assert first.line == 8
    assert second.line == 11
    check_example(first, "")
    check_example(second, "")
  end

  test "reports numeric and nested Decimal precision drift with README location and values" do
    error = assert_raise ExUnit.AssertionError, fn -> check_fixture("1", "2") end
    assert error.message =~ "README.md:3"
    assert error.message =~ "Documented: 2"
    assert error.message =~ "Evaluated:  1"

    error =
      assert_raise ExUnit.AssertionError, fn ->
        check_fixture(
          "{:ok, %{value: Decimal.new(\"1.0000000000000001\")}}",
          "{:ok, %{value: #Decimal<1.0000000000000002>}}"
        )
      end

    assert error.message =~ "Decimal value/precision mismatch"
    assert error.message =~ "1.0000000000000001"
    assert error.message =~ "#Decimal<1.0000000000000002>"
  end

  test "scale-only drift fails the rendering comparison" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        check_fixture("Decimal.new(\"1.0\")", "#Decimal<1.00>")
      end

    assert error.message =~ "rendering mismatch"
    refute error.message =~ "precision mismatch"
  end

  test "missing keys, extra values and changed types fail the full comparison" do
    for {code, documented} <- [
          {"%{}", "%{value: nil}"},
          {"[Decimal.new(1), 2]", "[Decimal.new(1)]"},
          {"%{}", "Decimal.new(1)"},
          {"Decimal.new(1)", "1"}
        ] do
      error = assert_raise ExUnit.AssertionError, fn -> check_fixture(code, documented) end
      assert error.message =~ "Result rendering mismatch"
      assert error.message =~ "README.md:3"
    end
  end

  test "exceptions fail even for elided results" do
    for documented <- ["42", "#Decimal<...>"] do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          check_fixture("raise ArgumentError, \"bad input\"", documented)
        end

      assert error.message =~ "README.md:3"
      assert error.message =~ "Documented: #{documented}"
      assert error.message =~ "ArgumentError"
      assert error.message =~ "bad input"
    end
  end

  test "elision is explicit and inline explanations are not part of the result" do
    check_fixture("Decimal.new(1)", "#Decimal<...>")
    check_fixture("%{a: 1, b: 2}", "%{a: 1, ...}")
    check_fixture("{:ok, Decimal.new(1)}", "{:ok, #Decimal<1>} # explanation")
  end

  test "partial elisions check concrete values, missing keys and container shapes" do
    for {code, documented} <- [
          {"%{a: 2}", "%{a: 1, ...}"},
          {"%{}", "%{a: nil, ...}"},
          {"%{}", "%{a: ..., ...}"},
          {"%{a: [2, 3]}", "%{a: [1, ...], ...}"},
          {"%{a: []}", "%{a: [1, ...], ...}"},
          {"%{a: nil}", "%{a: [...], ...}"},
          {"%{a: %{b: 2}}", "%{a: %{b: 1, ...}, ...}"},
          {"{:error, %{a: 1}}", "{:ok, %{a: 1, ...}}"},
          {"{:ok}", "{:ok, %{...}}"},
          {"nil", "%{...}"},
          {"%{a: 1, b: 2}", "%{a: ...}"}
        ] do
      error = assert_raise ExUnit.AssertionError, fn -> check_fixture(code, documented) end
      assert error.message =~ "README.md:3"
    end
  end

  test "partial elisions retain Decimal value and rendering checks" do
    for {value, message} <- [
          {"1.01", "Decimal value/precision mismatch"},
          {"1.0", "rendering mismatch"}
        ] do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          check_fixture("%{a: Decimal.new(\"#{value}\")}", "%{a: #Decimal<1.00>, ...}")
        end

      assert error.message =~ message
    end
  end

  test "elided positions accept arbitrary values and tails while keeping concrete siblings" do
    for code <- ["nil", "42", "Decimal.new(\"1.00\")", "%{nested: [1, 2]}"] do
      check_fixture("%{a: #{code}, b: 1}", "%{a: ..., b: 1}")
      check_fixture("%{a: #{code}, b: 1}", "%{a: #Decimal<...>, b: 1}")
    end

    check_fixture("[%{a: 1, b: 2}, :extra]", "[%{a: 1, ...}, ...]")
    check_fixture("[1]", "[1, ...]")
    check_fixture("[]", "[...]")
    check_fixture("%{}", "%{...}")
    check_fixture("{:ok, %{a: 1, b: 2}}", "{:ok, %{a: 1, ...}}")
    check_fixture("nil", "...")
  end

  test "census distinguishes whole-result elisions from partial ones" do
    for documented <- ["...", "#Decimal<...>"] do
      assert parse_subset(documented) == @elision
    end

    for documented <- ["%{...}", "[...]", "%{a: ...}", "{:ok, #Decimal<...>}"] do
      refute parse_subset(documented) == @elision
    end
  end

  defp blocks(markdown) do
    ~r/^```elixir\r?\n(.*?)^```[ \t]*\r?$/ms
    |> Regex.scan(markdown, return: :index)
    |> Enum.map(fn [_, {offset, length}] ->
      %{code: binary_part(markdown, offset, length), line: line_at(markdown, offset)}
    end)
  end

  defp examples(block) do
    ~r/^#=>[^\n]*(?:\n#[ \t]{2,}[^\n]*)*/m
    |> Regex.scan(block.code, return: :index)
    |> Enum.map(fn [{offset, length}] ->
      documented =
        block.code
        |> binary_part(offset, length)
        |> String.replace(~r/^#(?:=>)?[ \t]*/m, "")

      %{
        code: binary_part(block.code, 0, offset),
        code_line: block.line,
        line: block.line + line_at(block.code, offset) - 1,
        documented: documented
      }
    end)
  end

  defp line_at(source, offset) do
    source |> binary_part(0, offset) |> String.split("\n") |> length()
  end

  defp elided?(example), do: String.contains?(example.documented, "...")

  defp check_example(example, aliases) do
    actual = evaluate(example, aliases)
    actual_text = render(actual)

    diagnostic = """
    README.md:#{example.line}
    Documented: #{example.documented}
    Evaluated:  #{actual_text}
    """

    if elided?(example) do
      assert_subset(actual, parse_subset(example.documented), diagnostic)
    else
      expected_code = Regex.replace(@decimal, example.documented, ~S|Decimal.new("\1")|)
      {expected, _} = Code.eval_string(expected_code, [], file: "README.md", line: example.line)

      assert_decimals(actual, expected, diagnostic)
      assert actual_text == render(expected), "#{diagnostic}Result rendering mismatch"
    end
  end

  defp parse_subset(documented) do
    expected_code =
      documented
      |> String.replace("#Decimal<...>", ":__readme_elision__")
      |> then(&Regex.replace(@decimal, &1, ~S|Decimal.new("\1")|))
      # A bare map tail needs a key before Elixir can parse it.
      |> String.replace(~r/([{,])\s*\.\.\.\s*(?=})/, "\\1 __readme_tail__: :__readme_elision__")
      |> String.replace("...", ":__readme_elision__")

    {expected, _} = Code.eval_string(expected_code)
    expected
  end

  defp concrete_count(@elision), do: 0
  defp concrete_count(%Decimal{}), do: 1

  defp concrete_count(value) when is_map(value) do
    value |> Map.delete(@tail) |> Map.values() |> concrete_count()
  end

  defp concrete_count(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> concrete_count()

  defp concrete_count(value) when is_list(value),
    do: value |> Enum.map(&concrete_count/1) |> Enum.sum()

  defp concrete_count(_value), do: 1

  defp assert_subset(_actual, @elision, _diagnostic), do: :ok

  defp assert_subset(actual, %Decimal{} = expected, diagnostic) do
    assert_concrete(actual, expected, diagnostic)
  end

  defp assert_subset(actual, expected, diagnostic) when is_map(expected) do
    assert is_map(actual), "#{diagnostic}Result rendering mismatch: expected map"

    unless Map.has_key?(expected, @tail) do
      assert Map.keys(actual) |> Enum.sort() == Map.keys(expected) |> Enum.sort(),
             "#{diagnostic}Result rendering mismatch: map keys"
    end

    for {key, value} <- Map.delete(expected, @tail) do
      assert Map.has_key?(actual, key), "#{diagnostic}Missing documented key: #{inspect(key)}"
      assert_subset(Map.fetch!(actual, key), value, diagnostic)
    end
  end

  defp assert_subset(actual, expected, diagnostic) when is_tuple(expected) do
    assert is_tuple(actual) and tuple_size(actual) == tuple_size(expected),
           "#{diagnostic}Result rendering mismatch: tuple shape"

    Enum.zip_with(Tuple.to_list(actual), Tuple.to_list(expected), fn actual, expected ->
      assert_subset(actual, expected, diagnostic)
    end)
  end

  defp assert_subset(actual, [@elision], diagnostic) do
    assert is_list(actual), "#{diagnostic}Result rendering mismatch: expected list tail"
  end

  defp assert_subset([actual | actual_tail], [expected | expected_tail], diagnostic) do
    assert_subset(actual, expected, diagnostic)
    assert_subset(actual_tail, expected_tail, diagnostic)
  end

  defp assert_subset(actual, expected, diagnostic) do
    assert_concrete(actual, expected, diagnostic)
  end

  defp assert_concrete(actual, expected, diagnostic) do
    assert_decimals(actual, expected, diagnostic)
    assert render(actual) == render(expected), "#{diagnostic}Result rendering mismatch"
  end

  defp evaluate(example, aliases) do
    # Re-evaluate the block prefix so bindings before earlier results stay in scope.
    # These library examples are pure; blocks never inherit another block's bindings.
    prefix = aliases <> "\n"

    {actual, _} =
      Code.eval_string(prefix <> example.code, [],
        file: "README.md",
        line: example.code_line - length(String.split(prefix, "\n")) + 1
      )

    actual
  rescue
    exception ->
      flunk("""
      README.md:#{example.line}
      Documented: #{example.documented}
      Evaluated: raised #{Exception.format(:error, exception, __STACKTRACE__)}
      """)
  end

  defp assert_decimals(%Decimal{} = actual, %Decimal{} = expected, diagnostic) do
    assert Decimal.equal?(actual, expected), "#{diagnostic}Decimal value/precision mismatch"
  end

  defp assert_decimals(actual, expected, diagnostic) when is_map(actual) and is_map(expected) do
    expected
    |> Map.to_list()
    |> Enum.each(fn {key, value} ->
      assert_decimals(Map.get(actual, key), value, diagnostic)
    end)
  end

  defp assert_decimals(actual, expected, diagnostic)
       when is_tuple(actual) and is_tuple(expected) do
    assert_decimals(Tuple.to_list(actual), Tuple.to_list(expected), diagnostic)
  end

  defp assert_decimals(actual, expected, diagnostic) when is_list(actual) and is_list(expected) do
    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {actual, expected} -> assert_decimals(actual, expected, diagnostic) end)
  end

  # Shape and non-Decimal differences are checked by the full rendering assertion.
  defp assert_decimals(_actual, _expected, _diagnostic), do: :ok

  defp render(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp check_fixture(code, documented) do
    [example] =
      "```elixir\n#{code}\n#=> #{documented}\n```\n"
      |> blocks()
      |> Enum.flat_map(&examples/1)

    check_example(example, "")
  end
end
