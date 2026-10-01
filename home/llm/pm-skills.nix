# pm-skills (github.com/phuryn/pm-skills) -> dsh skill bundles.
#
# dsh's filesystem skill provider (dsh-skill-filesystem, mounted by dsh-base
# with default roots + watch) scans skill roots one level deep for
# `<name>/SKILL.md` bundles, so the marketplace's pm-*/skills/<name>/ bundles
# are flattened directly into $out. Its 42 slash commands are a Claude Code
# surface (dsh registers commands programmatically — no file discovery), so
# their workflows are converted to workflow skills: command frontmatter
# (name/description) + body wrapped in a SKILL.md. A command whose name is
# already held by a skill is skipped — its skill twin already exposes the
# workflow (business-model, draft-nda, pre-mortem, privacy-policy,
# review-resume, stakeholder-map, test-scenarios, value-proposition).
#
# `nix flake update pm-skills` re-pins to upstream's default branch; the
# locked rev is the exact source of the store derivation.
{ pkgs, lib, src, version ? "2.1.0" # marketplace manifest version (.claude-plugin/marketplace.json)
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "pm-skills";
  inherit version;
  src = src;

  dontBuild = true;

  installPhase = ''
    # This environment's builder does not pre-create $out (observed: mkdir via
    # cp fails with EACCES on a missing parent), so create it explicitly.
    mkdir -p $out
    # 1) native skill bundles (each carries its own SKILL.md; sub-bundle dirs
    # such as references/ ride along with the directory).
    for d in $src/pm-*/skills/*/; do
      cp -r "$d" $out/
    done

    # 2) command workflows -> workflow skills (skip names a skill holds).
    for f in $src/pm-*/commands/*.md; do
      name=$(basename "$f" .md)
      [ -e "$out/$name" ] && continue
      mkdir -p "$out/$name"
      desc=$(sed -n 's/^description:[[:space:]]*//p' "$f" | sed -n 1p)
      [ -n "$desc" ] || { echo "pm-skills: $f has no frontmatter description" >&2; exit 1; }
      close=$(grep -n '^---$' "$f" | sed -n 2p | cut -d: -f1)
      [ -n "$close" ] || { echo "pm-skills: $f has no frontmatter close" >&2; exit 1; }
      {
        printf -- '---\n'
        printf 'name: %s\n' "$name"
        printf 'description: %s\n' "$desc"
        printf -- '---\n'
        tail -n +"$((close + 1))" "$f"
      } > "$out/$name/SKILL.md"
    done

    # 3) drift tripwire: $out must be exactly "one dir per bundle, SKILL.md
    # present" — the shape the provider's one-level scan expects.
    for d in $out/*/; do
      [ -f "$d/SKILL.md" ] || { echo "pm-skills: bundle without SKILL.md: $d" >&2; exit 1; }
    done
    for d in $src/pm-*/skills/*/; do
      [ -f "$out/$(basename "$d")/SKILL.md" ] \
        || { echo "pm-skills: upstream skill missing from output: $d" >&2; exit 1; }
    done
  '';

  meta = with lib; {
    description = "PM Skills Marketplace flattened into dsh skill bundles (69 skills + command workflow skills)";
    homepage = "https://github.com/phuryn/pm-skills";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}