# progress log

## 2026-01-31: fix flake test check

### done
- fixed `nix flake check` to include test deps (credo, dialyxir, excoveralls)
- added `mixFodDepsAll` with correct hash in package.nix
- test check now uses `beamPackages.mixRelease` with all deps
- removed doctest that fails in nix builds (no compile-time source info)

### next steps
1. implement Machine.QMP (QEMU Machine Protocol client)
2. implement Machine.Shell (virtconsole backdoor)
3. implement actual VM lifecycle in Machine
4. implement Driver test coordination
5. add integration tests with real QEMU

---

## 2026-01-31: project setup (condensed)

initial project with flake-parts + treefmt, mix.exs with elixir 1.17, module stubs (NixosTest, Application, CLI, Driver, Machine), 6 passing tests. workarounds: local hex install (nixpkgs hex incompatible), escript in libexec/ with wrapper (postFixup corrupts escripts)

## architecture

see ARCHITECTURE.md for full design. key components:
- Driver (GenServer) - coordinates test execution
- Machine (GenServer) - per-VM process
- Machine.QMP - JSON-RPC over unix socket to QEMU
- Machine.Shell - command execution via virtconsole
