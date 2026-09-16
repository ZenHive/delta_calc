defmodule DeltaCalc.ReadmeExamplesTest do
  @moduledoc """
  Executes README examples using the README's own alias setup.

  Expected values are parsed and inspected to canonicalize map order and multiline
  layout; Decimal scale remains significant. `#Decimal<x>` in `#=>` comments is
  converted to `Decimal.new/1` only to parse the literal — asserted README results
  must stay in IEx inspect form. Any result containing `...` is explicitly elided:
  it still executes, but its output is not asserted. The census below pins both
  counts so adding an elision requires a deliberate test change.
  """

  use ExUnit.Case, async: true

  @readme Path.expand("../../README.md", __DIR__)
  @decimal ~r/#Decimal<([^>]+)>/

  test "README examples match their documented results" do
    blocks = @readme |> File.read!() |> blocks()
    [setup] = Enum.filter(blocks, &Regex.match?(~r/^alias /m, &1.code))
    examples = Enum.flat_map(blocks, &examples/1)
    {elided, asserted} = Enum.split_with(examples, &elided?/1)

    assert {length(asserted), length(elided)} == {35, 17},
           "README example census changed: #{length(asserted)} asserted, #{length(elided)} elided"

    dialect_drift = Enum.filter(asserted, &String.contains?(&1.documented, "Decimal.new("))

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

    unless elided?(example) do
      expected_code = Regex.replace(@decimal, example.documented, ~S|Decimal.new("\1")|)
      {expected, _} = Code.eval_string(expected_code, [], file: "README.md", line: example.line)
      actual_text = render(actual)
      expected_text = render(expected)

      diagnostic = """
      README.md:#{example.line}
      Documented: #{example.documented}
      Evaluated:  #{actual_text}
      """

      assert_decimals(actual, expected, diagnostic)
      assert actual_text == expected_text, "#{diagnostic}Result rendering mismatch"
    end
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
