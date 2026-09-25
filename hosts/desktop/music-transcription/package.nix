{ python312, fetchurl, lib }:

# Music transcription pipeline env (Demucs -> f0 -> beats/chords -> Sonic Pi JSON).
#
# python312 (not the default python3/3.14) because the torch 2.13.0 CPU build
# is cached for 3.12 (238 MB, no CUDA). nixpkgs 26.11's python module no longer
# exposes `python312.pkgs.mkVirtualEnv`; the modern equivalent is
# `python312.withPackages (ps: [...])`, which wraps the interpreter with the
# listed site-packages and exposes $out/bin/python.
#
# demucs / lameenc / sphn are not in nixpkgs, so they are built here:
#   - demucs 4.1.0 from its PyPI sdist (hatchling backend)
#   - lameenc 1.8.4 + sphn 0.2.1 from their cp312 manylinux x86_64 wheels
#     (lameenc is wheel-only on PyPI)
#
# The `noCheck` overlay (below) strips the test machinery from every python
# package: without it, flaky test suites (e.g. inline-snapshot, a huggingface-hub
# test dep, fails 3 tests) and huge test-dep trees (jupyter/twine/falcon/openai)
# are built and their pytest phases run, stalling/failing the env build.
#
#   nix build --impure --no-link --print-out-paths
#     .#packages.x86_64-linux.music-transcription
#
# The env's python is at $out/bin/python; run the pipeline with:
#   $out/bin/python /home/llm/music-transcription/pipe.py <track.mp3>
let
  # Strip the flaky/heavy test machinery from every python package in the env.
  # In this python module the package-level `doCheck` becomes `doInstallCheck`
  # (the pytest phase) and `nativeCheckInputs` become `nativeInstallCheckInputs`;
  # both are always BUILT (inputs are built even when the check phase is skipped),
  # so clearing `nativeCheckInputs` stops the huge test-dep trees (huggingface-hub
  # -> jupyter/twine/falcon/openai, ...) from being built at all. Applying it to
  # every package (guarded by `? overridePythonAttrs`) is the robust, general fix.
  noCheck = v: if v ? overridePythonAttrs
    then v.overridePythonAttrs { doCheck = false; nativeCheckInputs = [ ]; }
    else v;
  py = python312.override {
    packageOverrides = final: super: lib.mapAttrs (n: v: noCheck v) super;
  };
  p = py.pkgs;
  fetch = fetchurl;

  lameenc = p.buildPythonPackage {
    pname = "lameenc";
    version = "1.8.4";
    format = "wheel";
    doCheck = false;
    src = fetch {
      url = "https://files.pythonhosted.org/packages/49/98/ced7da98fb0c149e80d3a5a97546b5abcec6a06f4187cc8842a737107487/lameenc-1.8.4-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl";
      sha256 = "00d619c0a617f66feccbbd2fa9ed3857958ea503f9fe0038cb8b1d950b8b6452";
    };
  };

  sphn = p.buildPythonPackage {
    pname = "sphn";
    version = "0.2.1";
    format = "wheel";
    doCheck = false;
    src = fetch {
      url = "https://files.pythonhosted.org/packages/16/ad/7fd6ed543362033671e706b9abecd24ba9cd8ac967a9f420e8d515017b94/sphn-0.2.1-cp312-cp312-manylinux_2_24_x86_64.whl";
      sha256 = "27527d82ae2db9fbd8b7cbd787160e5d8002d385c785d217bd1c6fed32c37b06";
    };
  };

  demucs = p.buildPythonPackage {
    pname = "demucs";
    version = "4.1.0";
    format = "pyproject";
    doCheck = false;
    src = fetch {
      url = "https://files.pythonhosted.org/packages/cd/0a/fe873fc9d9576de2b20fd6421857b189dee951b89305977f6c37416a8d42/demucs-4.1.0.tar.gz";
      sha256 = "d94c4f7dac886595b66af405c0fd1756fa00c297183f1cf021fd2eeedeeb67b2";
    };
    nativeBuildInputs = [ p.hatchling ];
    dependencies = [
      p.torch
      p.torchaudio
      p.numpy
      p.scipy
      p.soundfile
      p.einops
      p.julius
      lameenc
      sphn
      p.huggingface-hub
      p.safetensors
      p.pyyaml
      p.tqdm
    ];
  };
in
py.withPackages (ps: [
  ps.torch
  ps.torchaudio
  ps.librosa
  ps.numpy
  ps.scipy
  ps.soundfile
  ps.audioread
  ps.torchcrepe
  demucs
])
