defmodule Attest.Machine.BackendTest do
  use ExUnit.Case

  alias Attest.Machine.Backend

  describe "wait_for_file/2" do
    test "returns :ok when file exists" do
      path = Path.join(System.tmp_dir!(), "wait-test-#{:rand.uniform(100_000)}")
      File.write!(path, "ok")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Backend.wait_for_file(path, 1_000)
    end

    test "returns error when file never appears" do
      path = "/tmp/nonexistent-#{:rand.uniform(100_000)}"
      assert {:error, {:file_timeout, ^path}} = Backend.wait_for_file(path, 100)
    end
  end

  describe "wait_for_file_gone/2" do
    test "returns :ok when file is already gone" do
      assert :ok = Backend.wait_for_file_gone("/tmp/nonexistent-#{:rand.uniform(100_000)}", 100)
    end

    test "returns :ok after removing file" do
      path = Path.join(System.tmp_dir!(), "gone-test-#{:rand.uniform(100_000)}")
      File.write!(path, "ok")

      assert :ok = Backend.wait_for_file_gone(path, 1_000)
      refute File.exists?(path)
    end
  end

  describe "close_port/1" do
    test "returns :ok for nil" do
      assert :ok = Backend.close_port(nil)
    end
  end

  describe "stop_shell/1" do
    test "returns :ok for nil" do
      assert :ok = Backend.stop_shell(nil)
    end
  end

  describe "wait_for_process_exit/3" do
    test "returns :ok for nil port" do
      assert :ok = Backend.wait_for_process_exit(nil, false, 100)
    end

    test "returns :ok when already exited" do
      assert :ok = Backend.wait_for_process_exit(:fake_port, true, 100)
    end
  end
end
