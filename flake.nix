{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs {inherit system;};
    in
      with pkgs; rec {
        packages.lib = callPackage ./sops-bwrap.nix {};

        packages.demo = packages.lib.wrapApplication {
          package = writeShellScriptBin "demo" ''
            echo "foo is $foo"
          '';
          secretsYaml = ./demo-secrets.yaml;
          templates = [
            {
              template = "%V%A%c%z";
              argTemplate = ''%k=\"%v\"'';
              namespaces = ["other"];
              allow = ["^foo$"];
            }
          ];
        };

        ## Demo shell
        devShells.demo = with packages.lib;
          mkShell {
            packages = [
              nushell
              sops
              packages.demo
              (
                wrapApplication {
                  package = docker;
                  subcommand = "run";
                  secretsYaml = ./demo-secrets.yaml;
                  templates = [
                    {
                      template = "%A%c%v%z";
                      argTemplate = ''-e \"%k=%v\"'';
                      namespaces = ["db"];
                      allow = ["PASSWORD"];
                    }
                  ];
                }
              )
            ];
          };
        devShells.default = devShells.demo;
      });
}
