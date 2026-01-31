defmodule NixosTestTest do
  use ExUnit.Case

  describe "NixosTest" do
    test "module exists" do
      assert Code.ensure_loaded?(NixosTest)
    end
  end
end
