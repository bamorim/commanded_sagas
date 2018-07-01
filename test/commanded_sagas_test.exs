defmodule CommandedSagasTest do
  use ExUnit.Case
  doctest CommandedSagas

  test "greets the world" do
    assert CommandedSagas.hello() == :world
  end
end
