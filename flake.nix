{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig2nix = {
      url = "github:Cloudef/zig2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
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
      };
    };
  };

  outputs =
    {
      nixpkgs,
      zig-overlay,
      zls-overlay,
      flake-utils,
      zig2nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        zig = zig-overlay.packages.${system}.master;
        zls = zls-overlay.packages.${system}.zls.overrideAttrs { nativeBuildInputs = [ zig ]; };
        pkgs = import nixpkgs { inherit system; };
        zig-env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig-master;
        };
      in
      rec {
        packages.default = zig-env.package rec {
          src = zig-env.pkgs.lib.cleanSource ./.;

          nativeBuildInputs = with zig-env.pkgs; [
            pkg-config
            wrapGAppsHook
            gobject-introspection
            dbus
          ];

          buildInputs = with zig-env.pkgs; [
            udisks.dev
            udisks
            glib
          ];

          zigWrapperLibs = buildInputs;

          zigBuildFlags = [ "-Doptimize=ReleaseFast" ];

          zigBuildZonLock = ./build.zig.zon2json-lock;
        };

        apps.default = {
          type = "app";
          program = "${packages.default}/bin/mountui";
        };

        apps.zig2nix = zig-env.app [ ] "zig2nix \"$@\"";
        apps.zon2lock = zig-env.app [ ] "zig2nix zon2lock \"$@\"";

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.pkg-config
            zig
            pkgs.udisks.dev
            pkgs.glib
          ];
          buildInputs = [
            pkgs.udisks.dev
            pkgs.glib
          ];
          packages = [ zls ];
        };
      }
    );
}
