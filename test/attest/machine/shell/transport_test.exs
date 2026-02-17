defmodule Attest.Machine.Shell.TransportTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.Shell.Transport

  describe "Transport behaviour" do
    test "module exists and defines callbacks" do
      assert Code.ensure_loaded?(Transport)

      callbacks = Transport.behaviour_info(:callbacks)
      assert {:connect, 2} in callbacks
      assert {:close, 1} in callbacks
    end
  end
end
