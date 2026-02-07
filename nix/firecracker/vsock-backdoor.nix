# vsock backdoor service for firecracker VMs
#
# replaces the virtconsole-based backdoor from test-instrumentation.nix
# with a vsock listener. the elixir driver connects via firecracker's
# vsock UDS using the CONNECT protocol (Transport.Vsock)
#
# the service listens on vsock port 1234 and spawns a root shell for
# each connection, matching the protocol expected by Shell GenServer
{
  config,
  lib,
  pkgs,
  ...
}:

let
  # wrapper script spawned by socat for each connection
  # sends the ready banner then execs bash on the socket
  backdoorHandler = pkgs.writeShellScript "vsock-backdoor-handler" ''
    export USER=root
    export HOME=/root
    export DISPLAY=:0.0
    export PAGER=

    if [[ -e /etc/profile ]]; then
      set +o nounset
      source /etc/profile 2>/dev/null || true
    fi

    cd /tmp
    echo "Spawning backdoor root shell..."
    exec ${pkgs.bashNonInteractive}/bin/bash --norc
  '';
in
{
  options.testing.vsockBackdoor = lib.mkEnableOption "vsock backdoor service for firecracker" // {
    default = false;
  };

  config = lib.mkIf config.testing.vsockBackdoor {
    # load vsock kernel modules
    boot.kernelModules = [
      "vsock"
      "vmw_vsock_virtio_transport"
    ];

    # the backdoor service
    systemd.services.vsock-backdoor = {
      description = "vsock backdoor shell for test driver";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        # socat forks a handler process per connection
        ExecStart = "${pkgs.socat}/bin/socat VSOCK-LISTEN:1234,reuseaddr,fork EXEC:${backdoorHandler}";
        Restart = "always";
        KillSignal = "SIGHUP";
      };
    };

    # prevent agetty on serial console (same as test-instrumentation)
    systemd.services."serial-getty@ttyS0".enable = false;
  };
}
