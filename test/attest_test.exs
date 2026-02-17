defmodule AttestTest do
  use ExUnit.Case

  describe "Attest" do
    test "module exists" do
      assert Code.ensure_loaded?(Attest)
    end
  end
end
