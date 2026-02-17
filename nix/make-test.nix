# create a NixOS integration test using the elixir driver
#
# builds VMs from NixOS module configs, generates a backend-agnostic
# JSON machine config, and produces a derivation that runs the test
#
# usage:
#   test = import ./make-test.nix {
#     inherit pkgs attest;
#     name = "my-test";
#     nodes = {
#       server = { pkgs, ... }: {
#         services.nginx.enable = true;
#       };
#     };
#     testScript = ''
#       start_all.()
#       server |> Attest.wait_for_unit("nginx.service")
#     '';
#   };
{
  pkgs,
  attest,
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

  # evaluate a NixOS config, returning both the full config and the VM drv
  evalNode =
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
    {
      config = nixos.config;
      vm = nixos.config.system.build.vm;
    };

  # evaluate all nodes
  evaluatedNodes = lib.mapAttrs evalNode nodes;

  # extract just the VM derivations (for passthru)
  vms = lib.mapAttrs (_: node: node.vm) evaluatedNodes;

  # build machine config list from evaluated NixOS configs
  # binary name is run-${config.system.name}-vm (set by qemu-vm.nix)
  machines = lib.mapAttrsToList (
    nodeName: node:
    let
      systemName = node.config.system.name;
    in
    {
      name = nodeName;
      backend = "qemu";
      start_command = "${node.vm}/bin/run-${systemName}-vm";
    }
  ) evaluatedNodes;

  driver = import ./driver.nix {
    inherit
      pkgs
      attest
      vlans
      globalTimeout
      extraDriverArgs
      name
      machines
      ;
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
