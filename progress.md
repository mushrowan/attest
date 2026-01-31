# progress log

## 2026-01-31: project setup

### done
- created project structure with flake-parts + treefmt
- mix.exs with elixir 1.17, jason dep, credo/dialyxir/excoveralls for dev
- nix/package.nix with mixRelease + escript wrapper
- nix/devshell.nix with elixir toolchain
- lib/ modules: NixosTest, Application, CLI, Driver, Machine (stubs)
- test/ with basic unit tests
- AGENTS.md with TDD protocol
- ARCHITECTURE.md with full design doc

### working
- `nix build` produces working escript
- `nix develop` gives dev shell with elixir 1.17 + erlang 27
- `mix test` passes (6 tests)
- `nix fmt` formats nix + elixir files

### issues encountered
- nixpkgs hex 2.3.1 incompatible with elixir 1.17 (Protocol.__concat__ undefined)
  - workaround: install hex locally via `mix local.hex --force`
- mixRelease postFixup corrupts escripts in bin/
  - fix: put escript in libexec/, create wrapper script

### next steps
1. fix test check in flake (needs all deps including test deps)
2. commit initial project
3. implement Machine.QMP (QEMU Machine Protocol client)
4. implement Machine.Shell (virtconsole backdoor)
5. implement actual VM lifecycle in Machine
6. implement Driver test coordination
7. add integration tests with real QEMU

## architecture

see ARCHITECTURE.md for full design. key components:
- Driver (GenServer) - coordinates test execution
- Machine (GenServer) - per-VM process
- Machine.QMP - JSON-RPC over unix socket to QEMU
- Machine.Shell - command execution via virtconsole
