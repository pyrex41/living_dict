{
  description = "Pinned Living Dictionary critic compiler toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    shenscript = { url = "github:pyrex41/ShenScript/master"; flake = false; };
    yggdrasil = { url = "github:pyrex41/ratatoskr/main"; flake = false; };
    shen-erl = { url = "github:pyrex41/shen-erl"; flake = false; };
  };

  outputs = { self, nixpkgs, shenscript, yggdrasil, shen-erl }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      packages = eachSystem (pkgs: rec {
        yggdrasil-cli = pkgs.buildGoModule {
          pname = "yggdrasil";
          version = "0.1.0-pinned";
          src = yggdrasil;
          vendorHash = null;
        };

        shenscript-cli = pkgs.buildNpmPackage {
          pname = "shenscript";
          version = "1.0.0-pinned";
          src = shenscript;
          npmDepsHash = "sha256-lj3wfU2bj213fo2SYfFxFA63u4ob6KUjFWXhXDCC1HI=";
          npmBuildScript = "build-kernel";
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib/shenscript $out/bin
            cp -R . $out/lib/shenscript/
            ln -s $out/lib/shenscript/bin/shen.js $out/bin/shen-script
            runHook postInstall
          '';
        };

        shen-erl-cli = pkgs.stdenv.mkDerivation {
          pname = "shen-erl";
          version = "42.0-pinned";
          src = shen-erl;
          nativeBuildInputs = [ pkgs.gnumake pkgs.beamPackages.erlang pkgs.unzip pkgs.gnutar pkgs.gzip ];
          shenArchive = pkgs.fetchurl {
            url = "https://www.shenlanguage.org/Download/S42.zip";
            hash = "sha256-EzVFCCgrR8fYgsdsi3Fo5pIXx76TI8UXJiY52HVyq8M=";
          };
          communityArchive = pkgs.fetchurl {
            url = "https://github.com/Shen-Language/shen-sources/releases/download/shen-42.0/ShenOSKernel-42.0.tar.gz";
            hash = "sha256-MuhvWKH2u8ERcSp3egSlksR05c0Fwtt74BJfJbqPjjU=";
          };
          buildPhase = ''
            runHook preBuild
            substituteInPlace Makefile \
              --replace-fail 30abdc7e5a1e27b7a20109c1ed141e4712885e31f24d9710d16415fbbd4dfb23 \
                             13354508282b47c7d882c76c8b7168e69217c7be9323c517262639d87572abc3
            cp "$shenArchive" S42.0-20260825.zip
            cp "$communityArchive" ShenOSKernel-42.0.tar.gz
            make
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -R . $out/
            runHook postInstall
          '';
        };

        default = pkgs.writeShellApplication {
          name = "ld-build-critic-js";
          runtimeInputs = [ pkgs.nodejs yggdrasil-cli shenscript-cli ];
          text = ''
            if [ "$#" -ne 2 ]; then
              echo "usage: ld-build-critic-js SOURCE OUT_DIR" >&2
              exit 2
            fi
            export YGGDRASIL_SHENSCRIPT_DIR="${shenscript-cli}/lib/shenscript"
            yggdrasil build "$1" "$2" --target js --web --typecheck \
              --host "node ${shenscript-cli}/lib/shenscript/bin/shen.js"
          '';
        };

        erlang-critic = pkgs.writeShellApplication {
          name = "ld-build-critic-erlang";
          runtimeInputs = [ pkgs.beamPackages.erlang pkgs.gnumake pkgs.clang pkgs.curl pkgs.unzip pkgs.gnutar pkgs.coreutils yggdrasil-cli shenscript-cli ];
          text = ''
            if [ "$#" -ne 2 ]; then
              echo "usage: ld-build-critic-erlang SOURCE OUT_DIR" >&2
              exit 2
            fi
            shen_erl_work="$(mktemp -d)"
            trap 'rm -rf "$shen_erl_work"' EXIT
            cp -R "${shen-erl-cli}/." "$shen_erl_work/"
            chmod -R u+w "$shen_erl_work"
            export YGGDRASIL_SHEN_ERL_DIR="$shen_erl_work"
            yggdrasil build "$1" "$2" --target erlang --typecheck \
              --host "node ${shenscript-cli}/lib/shenscript/bin/shen.js"
          '';
        };
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = [ self.packages.${pkgs.system}.default self.packages.${pkgs.system}.erlang-critic ];
        };
      });
    };
}
