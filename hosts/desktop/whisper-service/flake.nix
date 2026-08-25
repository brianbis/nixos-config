{
  description = "GPU-accelerated Whisper transcription service — model weights live in VRAM only while running";

  # Pinned to the host's nixpkgs channel revision.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a831408e6378bc02ebf8cc09b52c96ca86f6bab4";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];

      # Import the nixpkgs *source* with config.allowUnfree set explicitly (the
      # CUDA runtime libraries are "unfree" in nixpkgs). Hermetic — no --impure
      # or NIXPKGS_ALLOW_UNFREE — since the flake's legacyPackages ignores `config`.
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

          # CTranslate2 4.8.1 (official PyPI wheel). Built with the CUDA backend,
          # but the CUDA libraries are dlopen()ed at runtime, so it imports
          # cleanly on machines without a GPU and uses the GPU when /dev/nvidia* is visible.
          ctranslate2-cuda = pypkgs.buildPythonApplication {
            pname = "ctranslate2";
            version = "4.8.1";
            format = "wheel";
            src = pypkgs.fetchPypi {
              pname = "ctranslate2";
              version = "4.8.1";
              format = "wheel";
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
            # lib.getLib is required: libcublas/libcurand are multi-output "redist"
            # packages whose .so files live in the `lib` output, not the meta `out`.
            propagatedBuildInputs = [
              # The prebuilt wheel's C++ lib needs libstdc++ at import time.
              pkgs.stdenv.cc.cc.lib
              (pkgs.lib.getLib pkgs.cudaPackages_12.cuda_cudart)
              (pkgs.lib.getLib pkgs.cudaPackages_12.libcublas)
              (pkgs.lib.getLib pkgs.cudaPackages_12.libcurand)
            ];
            # The prebuilt wheel's .so files keep their auditwheel RPATH and the
            # standard autoPatchelfHook is not applied, so libstdc++/CUDA libs (and
            # libgomp) are unresolvable; explicitly prepend $ORIGIN, gccLib, cudaLibs.
            postFixup = ''
              gccLib="${pkgs.stdenv.cc.cc.lib}/lib"
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
              # `./.` (this flake's source dir) instead of `self.outPath`: nested
              # as a path input, `self.outPath` becomes a subpath of the parent's
              # store copy, and sourceByRegex's relPath fails to match — the filter drops everything.
              pkgs.lib.sourceByRegex ./. [
              # lib.match is a full match, so the directory and its contents need
              # separate regexes; "whisper_service/.*\.py" keeps only .py files (a
              # broad .* would sweep in __pycache__/*.pyc and ship stale bytecode).
              "whisper_service"
              "whisper_service/.*\.py"
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
          whisper-service = {
            type = "app";
            program = "${self.packages.${system}.whisper-service}/bin/whisper-serve";
          };
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