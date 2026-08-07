{
  lib,
  stdenv,
  python,
  ast-grep,
}:

let
  # The latest ast-grep 0.44.1 wheel was pulled from PyPI due to a compromise,
  # so we ship the previous 0.44.0 as the shim version.
  shimVersion = "0.44.0";
in
stdenv.mkDerivation {
  pname = "ast-grep-cli";
  version = shimVersion;

  dontUnpack = true;

  installPhase = ''
    mkdir -p "$out/${python.sitePackages}/ast_grep_cli"
    touch "$out/${python.sitePackages}/ast_grep_cli/__init__.py"

    mkdir -p "$out/${python.sitePackages}/ast_grep_cli-${shimVersion}.dist-info"

    cat > "$out/${python.sitePackages}/ast_grep_cli-${shimVersion}.dist-info/METADATA" <<EOF
Metadata-Version: 2.1
Name: ast-grep-cli
Version: ${shimVersion}
EOF
  '';

  propagatedBuildInputs = [
    ast-grep
  ];

  meta = {
    description = "Python distribution shim providing the ast-grep CLI using nixpkgs ast-grep";
    license = lib.licenses.mit;
  };
}