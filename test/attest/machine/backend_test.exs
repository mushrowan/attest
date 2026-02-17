defmodule Attest.Machine.BackendTest do
  use ExUnit.Case, async: true

  alias Attest.Machine.Backend

  describe "Backend behaviour" do
    test "module exists and defines callbacks" do
      assert Code.ensure_loaded?(Backend)

      callbacks = Backend.behaviour_info(:callbacks)
      assert {:init, 1} in callbacks
      assert {:start, 1} in callbacks
      assert {:shutdown, 2} in callbacks
      assert {:halt, 2} in callbacks
      assert {:wait_for_shutdown, 2} in callbacks
      assert {:cleanup, 1} in callbacks
      assert {:screenshot, 2} in callbacks
      assert {:send_key, 2} in callbacks
      assert {:handle_port_exit, 2} in callbacks
      assert {:capabilities, 1} in callbacks
    end
  end
end
