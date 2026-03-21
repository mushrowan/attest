# TDD Protocol

You are a strict TDD pair programmer. You must operate in 3 distinct steps.

**STEP 1: RED** - Write test only, run `mix test` to prove it fails.

**STEP 2: GREEN** - Write minimal code to pass, run `mix test` to verify.

**STEP 3: REFACTOR** - `jj commit`, `mix format`, run `nix flake check --quiet`. Update progress.md, condense older entries.

STOP after step 3 and notify user that progress log is updated.

**Rules**: If stuck after 2 attempts, ask user.

# attest - NixOS Test Driver in Elixir

OTP-based reimplementation of the NixOS test driver, leveraging supervision trees for VM lifecycle management.

## Project Structure

```
lib/
├── attest.ex                  # public API
├── attest/
│   ├── application.ex         # OTP application, supervisors
│   ├── cli.ex                 # escript CLI
│   ├── driver.ex              # test coordinator GenServer
│   ├── dsl.ex                 # test script DSL (subtest, assertions, retry)
│   ├── machine.ex             # VM GenServer
│   ├── machine_config.ex      # JSON config parser
│   ├── start_command.ex       # legacy start script builder
│   ├── test_script.ex         # test script evaluator
│   ├── vlan.ex                # VDE switch manager
│   └── machine/
│       ├── backend.ex         # backend behaviour + shared helpers
│       ├── backend/
│       │   ├── api.ex         # HTTP/1.1 over UDS (shared)
│       │   ├── micro_vm.ex    # shared microVM macro
│       │   ├── qemu.ex        # QEMU backend
│       │   ├── firecracker.ex # Firecracker backend
│       │   ├── cloud_hypervisor.ex # Cloud Hypervisor backend
│       │   ├── ssh.ex         # SSH backend (remote hosts)
│       │   └── mock.ex        # test mock backend
│       ├── guest_screenshot.ex # in-guest screenshot capture
│       ├── keyboard.ex        # key mapping
│       ├── ocr.ex             # OCR via tesseract
│       ├── qmp.ex             # QEMU Machine Protocol client
│       ├── shell.ex           # command protocol GenServer
│       └── shell/
│           ├── transport.ex   # transport behaviour
│           └── transport/
│               ├── virtconsole.ex
│               ├── vsock.ex
│               └── ssh.ex     # SSH channel + bridge GenServer
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
- Driver manages machines, VLANs, and global timeout
- Test script execution happens outside the driver (via TestScript module)
- Pluggable backends (QEMU, firecracker, cloud-hypervisor, SSH, mock)
- Pluggable transports (virtconsole, vsock, SSH)
- Shell protocol is transport-agnostic (base64-encoded commands)

## VCS

jj (jujutsu) colocated with git. use `jj` for all version control.

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
