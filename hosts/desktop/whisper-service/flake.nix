{
  description = "GPU-accelerated Whisper transcription service — model weights live in VRAM only while running";

  # Pinned to the host's nixpkgs channel revision (nixos-unstable, 2026-08-21).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a831408e6378bc02ebf8cc09b52c96ca86f6bab4";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];

      # Import the nixpkgs *source* with config.allowUnfree set explicitly.
      # The CUDA runtime libraries (libcudart / libcublas / libcurand) carry the
      # CUDA EULA and are "unfree" in nixpkgs. This is hermetic — it does not
      # rely on --impure or the NIXPKGS_ALLOW_UNFREE environment variable, and
      # it works because the nixpkgs flake's `legacyPackages` ignores the flake
      # input `config` attribute (its outputs only take `self`).
      mkPkgs = system: import nixpkgs.outPath {
        inherit system;
        config.allowUnfree = true;
      };

      pkgsFor = nixpkgs.lib.genAttrs systems mkPkgs;
      forAll = f: nixpkgs.lib.genAttrs systems (system: f pkgsFor.${system});
    in
    {
      packages = forAll (pkgs:
        let
          python = pkgs.python313;
          pypkgs = python.pkgs;

          # CTranslate2 4.8.1 from the official PyPI wheel.
          # It is built with the CUDA backend, but the CUDA libraries are
          # dlopen()ed at runtime, so it imports cleanly on machines without a
          # GPU and transparently uses the GPU when /dev/nvidia* is visible.
          ctranslate2-cuda = pypkgs.buildPythonApplication {
            pname = "ctranslate2";
            version = "4.8.1";
            format = "wheel";
            src = pypkgs.fetchPypi {
              pname = "ctranslate2";
              version = "4.8.1";
              format = "wheel";
              # ctranslate2-4.8.1-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl
              dist = "cp313";
              python = "cp313";
              abi = "cp313";
              platform = "manylinux_2_27_x86_64.manylinux_2_28_x86_64";
              hash = "sha256-QkKn+OKF+SJSX0z/1bH7Q8usxh0GEc9Ugy6cRH0DCEA=";
            };
            build-system = [ pypkgs.setuptools ];
            nativeBuildInputs = [ pkgs.patchelf ];
            # Runtime deps declared by the wheel (checked by pythonRuntimeDepsCheckHook).
            dependencies = [
              pypkgs.numpy
              pypkgs.pyyaml
            ];
            # CUDA runtime libraries, dlopen()ed by ctranslate2 when a GPU is present.
            #
            # lib.getLib is required: cuda_cudart is a single-output package
            # (its lib/ with libcudart.so.12 lives in `out`), but libcublas and
            # libcurand are multi-output "redist" packages whose `out` output
            # is a thin meta package (LICENSE + src only) — the actual .so
            # files live in their `lib` outputs. Referencing the packages bare
            # would keep the meta package (fine for the store closure) but put
            # a nonexistent /lib directory on the RUNPATH below, so the
            # runtime dlopen of libcublas.so.12 / libcurand.so.10 fails with
            # "Library ... is not found or cannot be loaded".
            propagatedBuildInputs = [
              # The prebuilt wheel's C++ lib needs libstdc++ at import time.
              pkgs.stdenv.cc.cc.lib
              (pkgs.lib.getLib pkgs.cudaPackages_12.cuda_cudart)
              (pkgs.lib.getLib pkgs.cudaPackages_12.libcublas)
              (pkgs.lib.getLib pkgs.cudaPackages_12.libcurand)
            ];
            # The prebuilt wheel's .so files keep their auditwheel RPATH
            # ($ORIGIN/../ctranslate2.libs for the _ext extension); the
            # standard autoPatchelfHook is not applied to them, so neither
            # libstdc++ nor the CUDA runtime libraries are resolvable from
            # their RPATH. libctranslate2 has no RPATH at all, so its
            # same-directory dependency libgomp is also unresolvable.
            # Explicitly prepend to every .so's rpath:
            #   $ORIGIN  - so the bundled ctranslate2.libs (libgomp) resolve
            #   gccLib   - libstdc++/libgcc_s needed at import time
            #   cudaLibs - libcudart/libcublas/libcurand, which libctranslate2
            #              dlopen()s by soname when a GPU is present
            postFixup = ''
              gccLib="${pkgs.stdenv.cc.cc.lib}/lib"
              # Every entry below must be a directory that actually contains the
              # .so files: for the multi-output redists (libcublas/libcurand)
              # that is their `lib` output (see lib.getLib above); for
              # cuda_cudart (single output) it is the `out` itself.
              cudaLibs="${pkgs.lib.concatStringsSep ":" (map (p: "${p}/lib") [
                (pkgs.lib.getLib pkgs.cudaPackages_12.cuda_cudart)
                (pkgs.lib.getLib pkgs.cudaPackages_12.libcublas)
                (pkgs.lib.getLib pkgs.cudaPackages_12.libcurand)
              ])}"
              for so in $(find $out/lib -name "*.so*" -type f); do
                current=$(patchelf --print-rpath "$so" 2>/dev/null || true)
                patchelf --set-rpath '$ORIGIN:'"$gccLib:$cudaLibs:$current" "$so"
              done
            '';
            doCheck = false;
            pythonImportsCheck = [ "ctranslate2" ];
            meta = {
              description = "Fast inference engine for Transformer models (CUDA-enabled)";
              license = pkgs.lib.licenses.mit;
            };
          };

          # faster-whisper wired against the CUDA-enabled ctranslate2.
          faster-whisper-cuda = pypkgs."faster-whisper".override {
            ctranslate2 = ctranslate2-cuda;
          };

          whisper-service = pypkgs.buildPythonApplication {
            pname = "whisper-service";
            version = "1.0.0";
            format = "setuptools";
            src =
              # `./.` (this flake's own source dir, resolved to the original
              # path) instead of `self.outPath`: when this flake is consumed
              # as a path input nested inside another flake's source tree,
              # `self.outPath` becomes a subpath of the parent flake's store
              # copy (e.g. /nix/store/<parent>-source/./hosts/desktop/
              # whisper-service). sourceByRegex computes relPath via
              # removePrefix on that string, which then fails to match the
              # normalized paths the filter is actually called with — the
              # filter silently drops *everything* and the build dies with
              # "setup.py: No such file or directory".
              pkgs.lib.sourceByRegex ./. [
              # lib.match is a full match, so the directory itself and its
              # contents need separate regexes:
              #   "whisper_service"      -> keeps the package directory
              #   "whisper_service/.*"   -> keeps the .py files inside it
              "whisper_service"
              "whisper_service/.*"
              "setup.py"
              "README.md"
            ];
            nativeBuildInputs = [ pypkgs.setuptools ];
            dependencies = [
              faster-whisper-cuda
              ctranslate2-cuda
              pypkgs.fastapi
              pypkgs.uvicorn
              pypkgs.python-multipart
            ];
            pythonImportsCheck = [ "whisper_service" "faster_whisper" ];
            doCheck = false;
            meta = {
              description = "Whisper transcription service with on-demand VRAM residency";
              mainProgram = "whisper-serve";
              license = pkgs.lib.licenses.mit;
              platforms = pkgs.lib.platforms.linux;
            };
          };

          # CLI entry point (same environment, different default program).
          whisper-cli = pkgs.runCommand "whisper-cli" { } ''
            mkdir -p $out/bin
            ln -s ${whisper-service}/bin/whisper $out/bin/whisper
          '';
        in
        {
          default = whisper-service;
          inherit whisper-service whisper-cli ctranslate2-cuda;
        }
      );

      apps = forAll (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          # nix run .#whisper-service            -> HTTP service
          # nix run .#whisper-service -- --port 9000
          whisper-service = {
            type = "app";
            program = "${self.packages.${system}.whisper-service}/bin/whisper-serve";
          };
          # nix run .#whisper-cli -- transcribe audio.mp3
          whisper-cli = {
            type = "app";
            program = "${self.packages.${system}.whisper-cli}/bin/whisper";
          };
        }
      );

      devShells = forAll (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          default = pkgs.mkShell {
            packages = [ self.packages.${system}.whisper-service ];
          };
        }
      );
    };
}