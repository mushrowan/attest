{
  lib,
  beamPackages,
  overrides ? (x: y: { }),
}:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {
      bunt = buildMix rec {
        name = "bunt";
        version = "1.0.0";

        src = fetchHex {
          pkg = "bunt";
          version = "${version}";
          sha256 = "dc5f86aa08a5f6fa6b8096f0735c4e76d54ae5c9fa2c143e5a1fc7c1cd9bb6b5";
        };

        beamDeps = [ ];
      };

      castore = buildMix rec {
        name = "castore";
        version = "1.0.19";

        src = fetchHex {
          pkg = "castore";
          version = "${version}";
          sha256 = "3669e6cab13f54c2df26b3e6833745d647f35b6e30d8ddd5975df0d5c842ca98";
        };

        beamDeps = [ ];
      };

      credo = buildMix rec {
        name = "credo";
        version = "1.7.18";

        src = fetchHex {
          pkg = "credo";
          version = "${version}";
          sha256 = "a189d164685fd945809e862fe76a7420c4398fa288d76257662aecb909d6b3e5";
        };

        beamDeps = [
          bunt
          file_system
          jason
        ];
      };

      dialyxir = buildMix rec {
        name = "dialyxir";
        version = "1.4.7";

        src = fetchHex {
          pkg = "dialyxir";
          version = "${version}";
          sha256 = "b34527202e6eb8cee198efec110996c25c5898f43a4094df157f8d28f27d9efe";
        };

        beamDeps = [ erlex ];
      };

      erlex = buildMix rec {
        name = "erlex";
        version = "0.2.9";

        src = fetchHex {
          pkg = "erlex";
          version = "${version}";
          sha256 = "8cfffc0ec7159e6d73de2ab28a588064de80f88b2798d5cbe4482cbbc200178b";
        };

        beamDeps = [ ];
      };

      excoveralls = buildMix rec {
        name = "excoveralls";
        version = "0.18.5";

        src = fetchHex {
          pkg = "excoveralls";
          version = "${version}";
          sha256 = "523fe8a15603f86d64852aab2abe8ddbd78e68579c8525ae765facc5eae01562";
        };

        beamDeps = [
          castore
          jason
        ];
      };

      file_system = buildMix rec {
        name = "file_system";
        version = "1.1.1";

        src = fetchHex {
          pkg = "file_system";
          version = "${version}";
          sha256 = "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d";
        };

        beamDeps = [ ];
      };

      jason = buildMix rec {
        name = "jason";
        version = "1.4.5";

        src = fetchHex {
          pkg = "jason";
          version = "${version}";
          sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
        };

        beamDeps = [ ];
      };
    };
in
self
