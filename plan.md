# nix integration layer — plan

## goal

make the elixir driver a drop-in replacement for the python nixos-test-driver:
nix defines machines → CLI parses args → Driver starts VMs → test script runs

## what's done

### StartCommand (committed)
- `StartCommand.name/1` — extracts machine name from `run-<name>-vm` paths
- `StartCommand.build/2` — builds full QEMU command with runtime args (QMP, virtconsole, serial, env vars)
- `StartCommand.to_machine_config/1` — bridges to Driver's machine config format
- 13 tests, all green

### CLI.parse_args/1 (staged, not committed)
- parses `--start-scripts`, `--vlans`, `--test-script`, `--global-timeout`, `--keep-vm-state`, `--output-dir`, `--interactive`
- env var fallbacks (`startScripts`, `vlans`, `testScript`, `globalTimeout`) for nix wrapProgram
- space-separated string parsing (matches python driver's format)
- 14 tests, all green

### TestScript (staged, not committed)
- `TestScript.eval_string/2` — evals elixir code with machine bindings (each machine name as a variable, plus `driver` and `start_all`)
- `TestScript.eval_file/2` — reads file then eval_string
- uses `:sys.get_state/1` to extract machine map from Driver
- 5 tests, all green

## what broke

the old CLI had `eval` and `eval-file` subcommands. the new CLI replaces them with `--test-script` / positional arg. the **integration tests** in `integration-tests/default.nix` still call:

```
nixos-test eval-file ${./run-test.exs}
nixos-test eval-file ${./multi-vm-test.exs}
```

these need updating to use the new CLI format. two options:
1. **keep backwards compat**: add `eval-file` as a subcommand that delegates to TestScript.eval_file (but without driver bindings — just raw Code.eval_file like before)
2. **update integration tests**: change the nix scripts to use `nixos-test ${./run-test.exs}` or `nixos-test --test-script ${./run-test.exs}`

option 1 is probably right for now — the integration tests use their own Driver setup inside the .exs files, they don't need the new CLI's driver wiring. keep `eval`/`eval-file` as escape hatches for scripts that manage their own Driver.

## what's next

### immediate (finish this PR)
1. fix CLI to keep `eval`/`eval-file` subcommands for backwards compat
2. commit CLI + TestScript
3. wire `run_test/1` so the new `nixos-test --start-scripts ... test.exs` path works end-to-end
4. `nix flake check` green

### then: Driver.run_tests/1 wiring
- Driver currently has a stub `run_tests/1` that returns `:ok`
- wire it to call `TestScript.eval_string/2` or `eval_file/2` with the driver's bindings
- or keep it in CLI (current approach) — CLI creates driver, then calls TestScript directly

### then: nix wrapper (driver.nix equivalent)
- a nix derivation that takes `nodes`, `testScript`, `vlans` and:
  - collects all `run-*-vm` start scripts
  - wraps the escript with env vars (`startScripts`, `testScript`, `vlans`, `globalTimeout`)
  - the wrapped binary "just works" with no args
- this is what lets `nix flake check` run a NixOS test defined the normal nix way but using our driver

### then: run.nix equivalent
- a `rawTestDerivation` that invokes the wrapped driver in a nix build sandbox
- `requiredSystemFeatures = ["nixos-test" "kvm"]`

### future
- test DSL as an alternative to raw elixir scripts
- firecracker nix integration (vmlinux + ext4 rootfs + vsock backdoor service)
- Backend.CloudHypervisor

## files touched

```
lib/nixos_test/start_command.ex          # NEW, committed
lib/nixos_test/cli.ex                    # rewritten, staged
lib/nixos_test/test_script.ex            # NEW, staged
test/nixos_test/start_command_test.exs   # NEW, committed
test/nixos_test/cli_test.exs             # NEW, staged
test/nixos_test/test_script_test.exs     # NEW, staged
```
