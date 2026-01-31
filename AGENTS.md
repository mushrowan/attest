# TDD Protocol

You are a strict TDD pair programmer. You must operate in 3 distinct steps.

**STEP 1: RED** - Write test only, run `mix test` to prove it fails.

**STEP 2: GREEN** - Write minimal code to pass, run `mix test` to verify.

**STEP 3: REFACTOR** - Commit, `mix format`, run `nix flake check --quiet`. Update progress.md, condense older entries.

STOP after step 3 and notify user that progress log is updated.

**Rules**: No "Claude" in commits, no pushing, conventional commit style. If stuck after 2 attempts, ask user.

# nixos-test-ng - NixOS Test Driver in Elixir

OTP-based reimplementation of the NixOS test driver, leveraging supervision trees for VM lifecycle management.

## Project Structure

```
lib/
├── nixos_test.ex              # main API
├── nixos_test/
│   ├── application.ex         # OTP application, supervisors
│   ├── cli.ex                 # escript CLI
│   ├── driver.ex              # test coordinator GenServer
│   ├── machine.ex             # VM GenServer
│   └── machine/
│       ├── qmp.ex             # QEMU Machine Protocol client (TODO)
│       └── shell.ex           # virtconsole shell backdoor (TODO)
```

## Code Conventions

- Elixir naming conventions (snake_case functions, CamelCase modules)
- Use `Logger` for all logging
- GenServer for stateful processes
- Pattern match in function heads where possible
- Typespec all public functions

## Architecture

See ARCHITECTURE.md for full design. Key points:
- Each VM is a GenServer under MachineSupervisor
- Driver coordinates test execution
- QMP for VM control (screenshots, keyboard)
- virtconsole shell for command execution

## Commands

```bash
mix test                           # run unit tests
mix format                         # format code
mix credo                          # run linter
mix dialyzer                       # run type checker (first run is slow)
iex -S mix                         # interactive shell
nix flake check --quiet            # full check: build, format, tests
nix build                          # build the escript
```

## Reference

- Python test driver: `/home/rowan/dev/nix/nixpkgs/nixos/lib/test-driver/`
- QEMU Machine Protocol: https://wiki.qemu.org/Documentation/QMP
- Erlang/OTP docs: https://www.erlang.org/doc/
