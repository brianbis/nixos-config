# ripwire (redhat-et): "the ripgrep of AI context" — a zero-dependency C++23
# CLI + MCP server giving coding agents a ranked, deterministic repo map
# (signatures, blast radius, tests-to-run, quality deltas). Built from the
# flakeless `ripwire` input (`nix flake update ripwire` re-pins); nixpkgs
# carries 0.5.0 but the input tracks upstream HEAD. Prebuilt release binaries
# are unusable here (linked against /lib64/ld-linux-x86-64.so.2, absent on
# NixOS), so the source build is the only route. All C deps (tree-sitter core
# + 25 grammars) are vendored under third_party/deps/; CMake FetchContent
# points at them and hard-fails on a missing sentinel (never a network clone),
# so the build is fully offline.
{ lib, stdenv, cmake, versionCheckHook, src }:

let
  # Read the version from the single project() call in CMakeLists.txt so a
  # re-pin updates it (builtins.match is a full match, so filter to that line).
  versionLine = lib.head
    (lib.filter (l: builtins.match "project\\(ripwire VERSION ([0-9.]+).*" l != null)
      (lib.splitString "\n" (builtins.readFile (src + "/CMakeLists.txt"))));
  version = builtins.head (builtins.match "project\\(ripwire VERSION ([0-9.]+).*" versionLine);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ripwire";
  inherit version src;

  # CMake drives the build; the default Makefiles generator + makeBuildPhase
  # (make -j in the build/ dir the cmake setup hook configures) builds it.
  nativeBuildInputs = [ cmake ];

  # The cmake setup hook configures with CMAKE_BUILD_TYPE=Release by default:
  # upstream's shipped-binary configuration (LTO ON, the "fast binary").

  # stdenv's "format" hardening adds -Werror=format-security, which trips on
  # upstream's code (same workaround as the nixpkgs ripwire recipe).
  hardeningDisable = [ "format" ];

  # Scope the install to the ripwire component (bin/ripwire + share/ripwire/
  # skills + hooks); without --component, cmake --install would also run the
  # vendored tree-sitter subproject's install rules (headers + static lib,
  # linked statically and never needed at runtime). The cwd is the build/ dir,
  # so `cmake --install .` targets the build tree.
  installPhase = ''
    runHook preInstall
    cmake --install . "--prefix=$out" --component ripwire
    runHook postInstall
  '';

  # doCheck = false to keep the build lean (upstream CI runs the doctest gate
  # suite); the installed binary is smoke-checked instead: --version must
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
