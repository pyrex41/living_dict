{
  description = "Pinned Living Dictionary durable Wasm development shell";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: builtins.listToAttrs (map (system: { name = system; value = f system; }) systems);
    in {
      devShells = forAll (system: let
        pkgs = import nixpkgs { inherit system; overlays = [ rust-overlay.overlays.default ]; };
        rust = pkgs.rust-bin.stable."1.95.0".default.override {
          extensions = [ "rustfmt" "clippy" ];
          targets = [ "wasm32-unknown-unknown" "wasm32-wasip1" ];
        };
      in {
        default = pkgs.mkShell { packages = [ rust pkgs.cargo-component ]; CARGO_COMPONENT_VERSION = "0.21.1"; };
      });
    };
}
