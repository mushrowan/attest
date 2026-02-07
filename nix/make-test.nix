# create a NixOS integration test using the elixir driver
#
# builds VMs from NixOS module configs, wraps the driver with
# start scripts, and produces a derivation that runs the test
#
# usage:
#   test = import ./make-test.nix {
#     inherit pkgs nixos-test-ng;
#     name = "my-test";
#     nodes = {
#       server = { pkgs, ... }: {
#         services.nginx.enable = true;
#       };
#     };
#     testScript = ''
#       start_all.()
#       server |> NixosTest.wait_for_unit("nginx.service")
#     '';
#   };
{
  pkgs,
  nixos-test-ng,
  # test name
  name,
  # attrset of node name -> NixOS module (or list of modules)
  nodes,
  # elixir test script string
  testScript,
  # list of VLAN numbers
  vlans ? [ ],
  # global timeout in seconds
  globalTimeout ? 3600,
  # extra CLI args passed to the driver
  extraDriverArgs ? [ ],
}:
let
  inherit (pkgs) lib;

  # build a VM from a NixOS module configuration
  buildVM =
    nodeName: nodeConfig:
    let
      modules = if builtins.isList nodeConfig then nodeConfig else [ nodeConfig ];

      nixos = import "${pkgs.path}/nixos" {
        system = pkgs.stdenv.hostPlatform.system;
        configuration = {
          imports = modules ++ [
            "${pkgs.path}/nixos/modules/virtualisation/qemu-vm.nix"
            "${pkgs.path}/nixos/modules/testing/test-instrumentation.nix"
          ];

          # reasonable defaults for test VMs
          virtualisation.memorySize = lib.mkDefault 512;
          virtualisation.cores = lib.mkDefault 1;
          documentation.enable = false;

          # set hostname to node name
          networking.hostName = lib.mkDefault nodeName;

          # required for qemu-vm module
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader.grub.enable = false;
        };
      };
    in
    nixos.config.system.build.vm;

  # build all VMs
  vms = lib.mapAttrs buildVM nodes;

  driver = import ./driver.nix {
    inherit
      pkgs
      nixos-test-ng
      vlans
      globalTimeout
      extraDriverArgs
      name
      ;
    nodes = vms;
    inherit testScript;
  };

  test = import ./run.nix {
    inherit pkgs driver name;
  };
in
test
// {
  inherit driver;
  inherit vms;
}
