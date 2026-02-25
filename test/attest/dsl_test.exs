defmodule Attest.DSLTest do
  use ExUnit.Case

  alias Attest.DSL
  import Attest.DSL, only: [retry: 2]

  describe "subtest/2" do
    test "runs the body and logs the label" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          DSL.subtest("my test section", fn ->
            :ok
          end)
        end)

      assert log =~ "subtest: my test section"
      assert log =~ "passed"
    end

    test "returns the body result" do
      result = DSL.subtest("returns", fn -> 42 end)
      assert result == 42
    end

    test "re-raises on failure" do
      assert_raise RuntimeError, "boom", fn ->
        DSL.subtest("my section", fn ->
          raise "boom"
        end)
      end
    end
  end

  describe "assert_contains/2" do
    test "passes when string contains substring" do
      DSL.assert_contains("hello world", "world")
    end

    test "raises when string doesn't contain substring" do
      assert_raise RuntimeError, ~r/expected.*to contain.*missing/s, fn ->
        DSL.assert_contains("hello world", "missing")
      end
    end
  end

  describe "assert_matches/2" do
    test "passes when string matches regex" do
      DSL.assert_matches("hello 123", ~r/\d+/)
    end

    test "raises when string doesn't match regex" do
      assert_raise RuntimeError, ~r/expected.*to match/, fn ->
        DSL.assert_matches("hello", ~r/\d+/)
      end
    end
  end

  describe "retry/2" do
    test "returns on first success" do
      counter = :counters.new(1, [])

      result =
        DSL.retry attempts: 5, delay: 10 do
          :counters.add(counter, 1, 1)
          "ok"
        end

      assert result == "ok"
      assert :counters.get(counter, 1) == 1
    end

    test "retries on failure and eventually succeeds" do
      counter = :counters.new(1, [])

      result =
        DSL.retry attempts: 5, delay: 10 do
          n = :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) < 3 do
            raise "not yet"
          end

          "done"
        end

      assert result == "done"
      assert :counters.get(counter, 1) == 3
    end

    test "raises after exhausting attempts" do
      assert_raise RuntimeError, ~r/not yet/, fn ->
        DSL.retry attempts: 3, delay: 10 do
          raise "not yet"
        end
      end
    end
  end
end
