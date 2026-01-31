defmodule NixosTestTest do
  use ExUnit.Case
  doctest NixosTest

  describe "NixosTest" do
    test "module exists" do
      assert Code.ensure_loaded?(NixosTest)
    end
  end
end
