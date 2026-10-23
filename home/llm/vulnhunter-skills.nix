# vulnhunter (github.com/capitalone/VulnHunter) -> dsh skill bundles.
#
# VulnHunter is an agentic AI security tool that ships as three Claude Code
# skills — vulnhunt (the attacker-first scanner), vulnhunter-fix (test-driven
# remediation), and vulnhunt-fix-verify (an independent read-only verifier).
# Each is a top-level directory whose root carries its own SKILL.md (plus
# phases/, scripts/, references/, templates/, tests/ and the vulnhunter_fix/
# python package that ride along with the directory).
#
# dsh's filesystem skill provider (dsh-skill-filesystem, mounted by dsh-base
# with default roots + watch) scans skill roots one level deep for
# <name>/SKILL.md bundles, so the three skill dirs are copied wholesale into
# $out — the same shape upstream's install.sh produces under ~/.claude/skills.
# Only a directory that actually carries a SKILL.md is copied, so harness/ and
# vulnhunter-agent/ (README-only support dirs) are skipped, mirroring install.sh.
#
# `nix flake update vulnhunter` re-pins to upstream's default branch; the locked
# rev is the exact source of the store derivation.
{ pkgs, lib, src, version ? "0.0.0" }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "vulnhunter-skills";
  inherit version;
  src = src;

  dontBuild = true;

  installPhase = ''
    # This environment's builder does not pre-create $out (observed: mkdir via
    # cp fails with EACCES on a missing parent), so create it explicitly.
    mkdir -p $out

    # 1) native skill bundles: copy each top-level dir that carries its own
    #    SKILL.md (sub-bundle dirs ride along with the directory).
    for d in $src/*/; do
      [ -f "$d/SKILL.md" ] || continue
      cp -r "$d" $out/
    done

    # 2) drift tripwire: $out must be exactly "one dir per bundle, SKILL.md
    #    present" — the shape the provider's one-level scan expects.
    for d in $out/*/; do
      [ -f "$d/SKILL.md" ] || { echo "vulnhunter-skills: bundle without SKILL.md: $d" >&2; exit 1; }
    done

    # 3) the core scanner must be present — a branch without it is not a usable
    #    VulnHunter install (mirrors install.sh's hard-fail on vulnhunt).
    [ -f "$out/vulnhunt/SKILL.md" ] \
      || { echo "vulnhunter-skills: core vulnhunt skill missing from source" >&2; exit 1; }
  '';

  meta = with lib; {
    description = "VulnHunter (capitalone) security skills flattened into dsh skill bundles (vulnhunt, vulnhunter-fix, vulnhunt-fix-verify)";
    homepage = "https://github.com/capitalone/vulnhunter";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
