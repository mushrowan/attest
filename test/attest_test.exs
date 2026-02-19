defmodule AttestTest do
  use ExUnit.Case

  describe "Attest" do
    test "module exists" do
      assert Code.ensure_loaded?(Attest)
    end
  end
end

defmodule AttestWaitAllTest do
  use ExUnit.Case

  describe "wait_all/2" do
    test "runs function on all items concurrently" do
      test_pid = self()

      items = [:a, :b, :c]

      Attest.wait_all(items, fn item ->
        send(test_pid, {:started, item})
        Process.sleep(100)
        send(test_pid, {:done, item})
      end)

      # all should have started and completed
      for item <- items do
        assert_received {:started, ^item}
        assert_received {:done, ^item}
      end
    end

    test "runs concurrently not sequentially" do
      start = System.monotonic_time(:millisecond)

      Attest.wait_all(1..4, fn _ ->
        Process.sleep(100)
      end)

      elapsed = System.monotonic_time(:millisecond) - start
      # if sequential would be ~400ms, concurrent should be ~100ms
      assert elapsed < 250
    end

    test "propagates errors from tasks" do
      Process.flag(:trap_exit, true)

      assert catch_exit(
               Attest.wait_all([:a, :b], fn
                 :a -> :ok
                 :b -> raise "boom"
               end)
             )
    end
  end
end
