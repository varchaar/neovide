{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem =
        { config
        , self'
        , pkgs
        , lib
        , system
        , ...
        }:
        let
          libDeps = with pkgs; [
            libglvnd
            libxkbcommon
            xorg.libXcursor
            xorg.libXext
            xorg.libXrandr
            xorg.libXi
            wayland
          ];
          runtimeDeps = with pkgs;[
            SDL2
            fontconfig
            rustPlatform.bindgenHook
          ];
          buildDeps = with pkgs; [
            makeWrapper
            pkg-config
            python3 # skia
            removeReferencesTo
          ];
          devDeps = with pkgs; [ gdb ];

          cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
          msrv = cargoToml.package.rust-version;

          rustPackage = features:
            (pkgs.makeRustPlatform {
              cargo = pkgs.rust-bin.stable.latest.minimal;
              rustc = pkgs.rust-bin.stable.latest.minimal;
            }).buildRustPackage.override
              { stdenv = pkgs.clangStdenv; }
              rec {
                inherit (cargoToml.package) name version;
                src = ./.;
                cargoLock.lockFile = ./Cargo.lock;

                SKIA_SOURCE_DIR =
                  let
                    repo = pkgs.fetchFromGitHub {
                      owner = "rust-skia";
                      repo = "skia";
                      # see rust-skia:skia-bindings/Cargo.toml#package.metadata skia
                      rev = "m126-0.74.2";
                      hash = "sha256-4l6ekAJy+pG27hBGT6A6LLRwbsyKinJf6PP6mMHwaAs=";
                    };
                    # The externals for skia are taken from skia/DEPS
                    externals = pkgs.linkFarm "skia-externals" (lib.mapAttrsToList
                      (name: value: { inherit name; path = pkgs.fetchgit value; })
                      (lib.importJSON ./skia-externals.json));
                  in
                  pkgs.runCommand "source" { } ''
                    cp -R ${repo} $out
                    chmod -R +w $out
                    ln -s ${externals} $out/third_party/externals
                  ''
                ;

                SKIA_GN_COMMAND = "${pkgs.gn}/bin/gn";
                SKIA_NINJA_COMMAND = "${pkgs.ninja}/bin/ninja";

                nativeBuildInputs = buildDeps;

                buildInputs = runtimeDeps;
                postFixup =
                  let
                    libPath = lib.makeLibraryPath (libDeps);
                  in
                  ''
                    # library skia embeds the path to its sources
                    remove-references-to -t "$SKIA_SOURCE_DIR" \
                      $out/bin/neovide

                    wrapProgram $out/bin/neovide \
                      --prefix LD_LIBRARY_PATH : ${libPath}
                  '';

                postInstall = lib.optionalString pkgs.stdenv.isDarwin ''
                  mkdir -p $out/Applications
                  cp -r extra/osx/Neovide.app $out/Applications
                  ln -s $out/bin $out/Applications/Neovide.app/Contents/MacOS
                '' + lib.optionalString pkgs.stdenv.isLinux ''
                  for n in 16x16 32x32 48x48 256x256; do
                    install -m444 -D "assets/neovide-$n.png" \
                      "$out/share/icons/hicolor/$n/apps/neovide.png"
                  done
                  install -m444 -Dt $out/share/icons/hicolor/scalable/apps assets/neovide.svg
                  install -m444 -Dt $out/share/applications assets/neovide.desktop
                '';
                doCheck = false;

                disallowedReferences = [ SKIA_SOURCE_DIR ];

                meta = with lib; {
                  description = "This is a simple graphical user interface for Neovim";
                  mainProgram = "neovide";
                  homepage = "https://github.com/neovide/neovide";
                  changelog = "https://github.com/neovide/neovide/releases/tag/${version}";
                  license = with licenses; [ mit ];
                  maintainers = with maintainers; [ ck3d ];
                  platforms = platforms.linux ++ [ "aarch64-darwin" ];
                };
              };

          mkDevShell = rustc:
            pkgs.mkShell {
              shellHook = ''
                export RUST_SRC_PATH=${pkgs.rustPlatform.rustLibSrc}
              '';
              LD_LIBRARY_PATH = lib.makeLibraryPath libDeps;
              buildInputs = runtimeDeps;
              nativeBuildInputs = buildDeps ++ devDeps ++ [ rustc ];
            };
        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ (import inputs.rust-overlay) ];
          };

          packages.default = rustPackage "";
          devShells.default = self'.devShells.nightly;

          devShells.nightly =
            mkDevShell (pkgs.rust-bin.selectLatestNightlyWith
              (toolchain: toolchain.default));
          devShells.stable = mkDevShell pkgs.rust-bin.stable.latest.default;
          devShells.msrv = mkDevShell pkgs.rust-bin.stable.${msrv}.default;
        };
    };
}
