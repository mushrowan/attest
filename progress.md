# progress log

## 2026-01-31: implement QMP and Shell

### done
- **Machine.QMP** (GenServer): QMP protocol client
  - parse_message/1: greeting, success, error, event messages
  - encode_command/2: command encoding with args
  - start_link/1: connect to socket, negotiate capabilities
  - command/3: send command, receive response
  - 12 tests with real unix sockets
- **Machine.Shell** (GenServer): shell backdoor client
  - format_command/1: wrap command with base64 encoding
  - parse_output/2: decode base64 output + exit code
  - start_link/1: create listen socket
  - wait_for_connection/2: accept, wait for backdoor ready
  - execute/2: send command, receive output
  - 8 tests with real unix sockets

### next steps
1. integrate QMP + Shell into Machine GenServer
2. implement actual VM lifecycle (start QEMU process)
3. implement Driver test coordination
4. add integration tests with real QEMU

---

## 2026-01-31: earlier (condensed)

- fix flake test check: added mixFodDepsAll, removed broken doctest
- project setup: flake-parts + treefmt, elixir 1.17, module stubs, 6 tests
