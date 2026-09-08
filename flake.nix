{
  description = "file_bash Zig development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig.url = "github:mitchellh/zig-overlay";
    # zls.url = "github:zigtools/zls";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;}
    {
      systems = ["x86_64-linux"];
      perSystem = {
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

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zig
            zls
          ];
        };
      };
    };
}
