# bend: a dependently typed, affine language that blocks AI mistakes via proof
# (bendlang/bend). The compiler, interpreter and checker are a TypeScript
# program run by bun; `bend <f> -o` emits C that is compiled by clang (CPU
# lane) at the user's invocation, so both bun and clang only need to be on the
# runtime PATH. The whole bend2/ tree must travel with base.bend: main.ts
# resolves base.bend relative to its own directory (BEND_DIR), and base.bend's
# IO effects are imported as "./effs/*.c|js" relative to that same tree.
{ stdenvNoCC, lib, bun, clang, src }:

# Read the version from main.ts so a re-pin updates it (no hardcoded drift),
# mirroring the knife.nix "read the manifest" convention.
let
  # builtins.match is a full match that returns the list of capture groups, so
  # match the single VERSION line (splitString drops the trailing newline) and
  # take the first capture.
  version = builtins.head
    (builtins.match "const VERSION = \"([^\"]+)\";"
      (builtins.head
        (lib.filter (l: builtins.match "const VERSION = \"([^\"]+)\";" l != null)
          (lib.splitString "\n" (builtins.readFile (src + "/bend2/main.ts"))))));
in
stdenvNoCC.mkDerivation {
  pname = "bend";
  inherit version src;

  # Nothing to compile: installPhase assembles the wrapper + the source tree.
  nativeBuildInputs = [ bun clang ];
  dontConfigure = true;
  dontBuild = true;
  doCheck = false;

  installPhase = ''
    mkdir -p $out/bin $out/lib
    # Preserve the bend2/ layout (main.ts + base.bend + effs/ + comp.ts).
    cp -r $src/bend2 $out/lib/bend2
    # The wrapper puts clang on PATH (Bend's cc_find locates it there) and
    # hands the CLI to bun. bun is invoked by absolute path, so it need not be
    # on PATH itself.
    cat > $out/bin/bend <<'BEND'
    #!/usr/bin/env bash
    set -euo pipefail
    export PATH="${clang}/bin:$PATH"
    # Resolve the source tree relative to this script (bin/ -> ../lib/bend2),
    # so the wrapper works from a profile symlink too.
    HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    exec ${bun}/bin/bun "$HERE/../lib/bend2/main.ts" "$@"
    BEND
    chmod +x $out/bin/bend
  '';

  meta = with lib; {
    description = "Bend: a fast dependently typed affine language that blocks AI mistakes via proof (compiler, interpreter, C/JS backends)";
    homepage = "https://github.com/bendlang/bend";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "bend";
    maintainers = [ ];
  };
}
