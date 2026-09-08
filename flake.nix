{
  description = "file_bash flake containing its package and a devShell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;}
    {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem = {
        self',
        inputs',
        system,
        pkgs,
        ...
      }: let
        zig = inputs'.zig.packages."0.16.0";
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [(final: prev: {inherit zig;})];
        };

        packages = {
          default = self'.packages.fb;
          fb = pkgs.callPackage ({
            lib,
            stdenv,
            zig,
          }:
            stdenv.mkDerivation {
              pname = "fb";
              version = "0.0.1";

              src = ./.;

              nativeBuildInputs = [zig.hook];

              meta = {
                homepage = "https://github.com/Sc3l3t0n/file_bash";
                description = "Run a shell command and save its output to files";
                license = lib.licenses.mit;
                mainProgram = "fb";
                inherit (zig.meta) platforms;
              };
            }) {};
          file_bash = self'.packages.fb;
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig
            zls
          ];
        };
      };
    };
}
