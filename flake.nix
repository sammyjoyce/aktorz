{
  description = "aktorz - durable actor runtime for Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_17
            pkgs.ziglint # `zig build lint` runs it from PATH
            pkgs.sqlite
          ];
        };
      }
    );
}
