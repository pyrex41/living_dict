{
  description = "Living Dictionary Unikraft organ environment: kraft + qemu + luajit";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    unikraft-nur.url = "github:unikraft/nur";
    unikraft-nur.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      unikraft-nur,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        uk = unikraft-nur.packages.${system};
      in
      {
        packages.kraftkit = uk.kraftkit;
        packages.default = uk.kraftkit;

        apps.kraft = {
          type = "app";
          program = "${uk.kraftkit}/bin/kraft";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            uk.kraftkit
            pkgs.qemu
            pkgs.luajit
            pkgs.gnumake
            pkgs.gawk
            pkgs.gnused
            pkgs.coreutils
            pkgs.socat
            pkgs.git
            pkgs.findutils
            pkgs.cpio
            pkgs.pkgsCross.musl64.stdenv.cc
          ];
          shellHook = ''
            echo "ld-uk: kraft=$(command -v kraft) qemu=$(command -v qemu-system-x86_64) lua=$(command -v luajit)"
          '';
        };
      }
    );
}
