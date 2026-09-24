# ripwire: "the ripgrep of AI context" (redhat-et/ripwire): a zero-dependency
# C++23 CLI + MCP server that gives coding agents a ranked, deterministic map
# of a repo — signatures, blast radius, tests-to-run, quality deltas.
#
# Built from the flakeless `ripwire` input (see flake.nix); `nix flake update
# ripwire` re-pins the source. nixpkgs carries 0.5.0; the flakeless input
# tracks upstream HEAD instead. The prebuilt release binaries are not usable
# on this host (they are dynamically linked against
# /lib64/ld-linux-x86-64.so.2, which does not exist on NixOS), so the source
# build is the only route.
#
# All C dependencies (the tree-sitter core + 25 language grammars) are
# vendored under third_party/deps/ in the source tree. CMake points
# FetchContent at those vendored trees and hard-fails at configure time if a
# sentinel file is missing — it never falls back to a network clone — so the
# build is fully offline (no network in the sandbox, by design).
{ lib, stdenv, cmake, versionCheckHook, src }:

let
  # Read the version from the single project() call in CMakeLists.txt so a
  # re-pin updates it (mirrors the bend.nix "read the manifest" convention).
  # builtins.match is a full match, so filter to the project() line first.
  versionLine = lib.head
    (lib.filter (l: builtins.match "project\\(ripwire VERSION ([0-9.]+).*" l != null)
      (lib.splitString "\n" (builtins.readFile (src + "/CMakeLists.txt"))));
  version = builtins.head (builtins.match "project\\(ripwire VERSION ([0-9.]+).*" versionLine);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ripwire";
  inherit version src;

  # CMake (>= 3.24 required; nixpkgs ships 4.x) drives the build. The
  # Makefiles generator is the default, so the default makeBuildPhase (make -j
  # in the build/ dir the cmake setup hook configures into) builds it.
  nativeBuildInputs = [ cmake ];

  # The cmake setup hook configures with CMAKE_BUILD_TYPE=Release by default:
  # upstream's shipped-binary configuration (LTO ON, the "fast binary" — see
  # the RIPWIRE_LTO block in CMakeLists.txt).

  # stdenv's "format" hardening adds -Werror=format-security, which trips on
  # upstream's code (same workaround as the nixpkgs ripwire recipe).
  hardeningDisable = [ "format" ];

  # Scope the install to the ripwire component (bin/ripwire + share/ripwire/
  # skills + hooks). Without --component, cmake --install would also run the
  # vendored tree-sitter subproject's install rules (headers + static lib
  # into $out), which ripwire links statically and never needs at runtime.
  # The cwd is the build/ dir (the cmake setup hook cd's into it at configure
  # time), so `cmake --install .` targets the build tree.
  installPhase = ''
    runHook preInstall
    cmake --install . "--prefix=$out" --component ripwire
    runHook postInstall
  '';

  # doCheck = false to keep the build lean; upstream CI runs the doctest gate
  # suite (RIPWIRE_TESTS=ON), mirroring the difftastic doCheck = false
  # precedent. The installed binary is smoke-checked instead: --version must
  # report the derivation's version.
  doCheck = false;
  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = with lib; {
    description = "The ripgrep of AI context: a zero-dependency C++23 CLI + MCP server for coding agents";
    homepage = "https://github.com/redhat-et/ripwire";
    license = licenses.asl20;
    platforms = platforms.all;
    mainProgram = "ripwire";
    maintainers = [ ];
  };
})
