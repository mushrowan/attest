# progress

## 2026-03-20

- removed dead `Driver.run_tests/1` and `:test_script` field from driver state. the handler was a no-op with a TODO that could never work due to GenServer deadlock (test scripts call back into the driver). the CLI already handles test script execution correctly via `TestScript.eval_file` from outside the driver. updated moduledoc to document the pattern. 242 tests passing, `nix flake check` green.
