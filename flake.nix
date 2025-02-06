{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    zls-overlay = {
      url = "github:zigtools/zls";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig-overlay";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { nixpkgs, zig-overlay, zls-overlay, flake-utils, self, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        zig = zig-overlay.packages.${system}.master;
        zls = zls-overlay.packages.${system}.zls.overrideAttrs { nativeBuildInputs = [ zig ]; };
        pkgs = import nixpkgs { inherit system; };
        mibu = pkgs.fetchFromGitHub {
          owner = "xyaman";
          repo = "mibu";
          rev = "b001662c929e2719ee24be585a3120640f946337";
          hash = "sha256-fuvrK5IfToYrWuEMZmaic70X5j294+rVUgcSR+7PB6k=";
        };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation (finalAttrs: {
          src = ./.;
          name = "mountui";

          nativeBuildInputs = [
            zig
            pkgs.pkg-config
            pkgs.wrapGAppsHook
            pkgs.gobject-introspection
            pkgs.dbus
          ];

          buildInputs = [ pkgs.udisks.dev pkgs.glib ];

          buildPhase = ''
            cp -r ${mibu} mibu
            mkdir -p .cache
            zig build install --prefix $out -Doptimize=ReleaseFast -Dtarget=native-native-gnu.2.40 --cache-dir $(pwd)/.zig-cache --global-cache-dir $(pwd)/.cache'';

          preFixup =
            let
              libPath = pkgs.lib.makeLibraryPath [
                pkgs.udisks
                pkgs.glib
              ];
            in
            ''
              patchelf \
                --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
                --set-rpath "${libPath}" \
                $out/bin/mountui
            '';
        });

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/mountui";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.pkg-config zig pkgs.udisks.dev pkgs.glib ];
          buildInputs = [ pkgs.udisks.dev pkgs.glib ];
          packages = [ zls ];
        };
      });
}
