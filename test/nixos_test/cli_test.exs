defmodule NixosTest.CLITest do
  use ExUnit.Case, async: true

  alias NixosTest.CLI

  describe "parse_args/1" do
    test "parses --start-scripts from space-separated string" do
      opts =
        CLI.parse_args([
          "--start-scripts",
          "/nix/store/a/bin/run-server-vm /nix/store/b/bin/run-client-vm"
        ])

      assert opts.start_scripts == [
               "/nix/store/a/bin/run-server-vm",
               "/nix/store/b/bin/run-client-vm"
             ]
    end

    test "parses --start-scripts from env var style" do
      opts = CLI.parse_args(["--start-scripts", "/nix/store/a/bin/run-single-vm"])
      assert opts.start_scripts == ["/nix/store/a/bin/run-single-vm"]
    end

    test "parses --vlans" do
      opts = CLI.parse_args(["--vlans", "1 2 3"])
      assert opts.vlans == [1, 2, 3]
    end

    test "parses --vlans empty" do
      opts = CLI.parse_args(["--vlans", ""])
      assert opts.vlans == []
    end

    test "parses --global-timeout" do
      opts = CLI.parse_args(["--global-timeout", "600"])
      assert opts.global_timeout == 600_000
    end

    test "defaults global-timeout to 3600s" do
      opts = CLI.parse_args([])
      assert opts.global_timeout == 3_600_000
    end

    test "parses --keep-vm-state flag" do
      opts = CLI.parse_args(["--keep-vm-state"])
      assert opts.keep_vm_state == true
    end

    test "defaults keep-vm-state to false" do
      opts = CLI.parse_args([])
      assert opts.keep_vm_state == false
    end

    test "parses --output-dir" do
      opts = CLI.parse_args(["--output-dir", "/tmp/out"])
      assert opts.output_dir == "/tmp/out"
    end

    test "parses positional test script path" do
      opts = CLI.parse_args(["path/to/test-script.exs"])
      assert opts.test_script == "path/to/test-script.exs"
    end

    test "parses --test-script" do
      opts = CLI.parse_args(["--test-script", "path/to/test.exs"])
      assert opts.test_script == "path/to/test.exs"
    end

    test "parses --interactive flag" do
      opts = CLI.parse_args(["--interactive"])
      assert opts.interactive == true
    end

    test "parses -i shorthand" do
      opts = CLI.parse_args(["-i"])
      assert opts.interactive == true
    end

    test "full example matching python driver args" do
      opts =
        CLI.parse_args([
          "--start-scripts",
          "/nix/store/a/bin/run-server-vm /nix/store/b/bin/run-client-vm",
          "--vlans",
          "1 2",
          "--global-timeout",
          "1800",
          "--output-dir",
          "/build/out",
          "/build/test-script.exs"
        ])

      assert opts.start_scripts == [
               "/nix/store/a/bin/run-server-vm",
               "/nix/store/b/bin/run-client-vm"
             ]

      assert opts.vlans == [1, 2]
      assert opts.global_timeout == 1_800_000
      assert opts.output_dir == "/build/out"
      assert opts.test_script == "/build/test-script.exs"
    end
  end

  describe "parse_args/1 with subcommands" do
    test "recognises eval subcommand" do
      opts = CLI.parse_args(["eval", "1 + 1"])
      assert opts.subcommand == {:eval, "1 + 1"}
    end

    test "recognises eval-file subcommand" do
      opts = CLI.parse_args(["eval-file", "/tmp/test.exs"])
      assert opts.subcommand == {:eval_file, "/tmp/test.exs"}
    end

    test "no subcommand by default" do
      opts = CLI.parse_args(["--interactive"])
      assert opts.subcommand == nil
    end
  end
end
