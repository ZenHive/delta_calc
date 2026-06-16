defmodule DeltaCalcTest do
  use ExUnit.Case
  doctest DeltaCalc

  test "library module loads" do
    assert Code.ensure_loaded?(DeltaCalc)
  end
end
