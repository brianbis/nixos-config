# zomboid/plugins.nix
# Produces a script that, when executed at RUNTIME (in a systemd oneshot),
# fetches the Steam Workshop collection(s) and renders the full
# <SERVERNAME>.ini (WorkshopItems=, Mods=, Map=, and any extra settings) into
# the target path given as $1.
#
# The network fetch happens at runtime, NOT at build time: the Nix build
# sandbox blocks network, and a failed Steam fetch must not block the system
# build. If the fetch fails at boot, the oneshot fails but the system still
# boots and the server starts with the previous (or empty) mod list.
#
# The script is built from:
#   * the collection URL(s) — fetched at runtime;
#   * the static ini lines (Map=, extraSettings) — pure Nix, baked in.
#
# Runtime cost is one page GET per URL plus one batched Steam Web API POST
# (GetPublishedFileDetails supports itemcount batching, so all items in a
# collection are resolved in a single request).

{ pkgs, collectionUrls, maps, extraSettings }:

let
  lib = pkgs.lib;
  python = pkgs.python3;

  # Static ini lines (Map=, extraSettings) — pure Nix, no web.
  staticFragment = pkgs.writeText "zomboid-static.ini" (
    (lib.optionalString (maps != [ ])
      ("Map=" + (lib.concatStringsSep ";" maps) + "\n"))
    + (lib.concatStringsSep "\n"
      (lib.mapAttrsToList (k: v: "${k}=${v}") extraSettings))
  );

  # The resolver: fetches the collection(s) at runtime and renders the mod
  # lines, then appends the static fragment. Writes the full ini to $1. On any
  # fetch failure the target is left untouched (the previous ini, if any,
  # remains).
  resolver = pkgs.writeText "zomboid-plugins-resolver.py" ''
    import json, os, re, sys, urllib.request

    target = sys.argv[1]
    static = sys.argv[2]
    urls = ${builtins.toJSON collectionUrls}
    ua = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) zomboid-nix/1.0"}

    workshop_ids = []
    for url in urls:
        html = urllib.request.urlopen(
            urllib.request.Request(url, headers=ua), timeout=60
        ).read().decode("utf-8", "replace")
        # The collection page embeds its items as CollectionItem( '<id>', '108600' ).
        for m in re.findall(r"CollectionItem\(\s*'(\d+)',\s*'108600'\s*\)", html):
            if m not in workshop_ids:
                workshop_ids.append(m)

    mod_ids = []
    if workshop_ids:
        # One batched POST resolves every item's description at once.
        body = "itemcount={}".format(len(workshop_ids)).encode()
        for i, wid in enumerate(workshop_ids):
            body += ("&publishedfileids[{}]={}".format(i, wid)).encode()
        req = urllib.request.Request(
            "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/",
            data=body, method="POST",
        )
        resp = json.load(urllib.request.urlopen(req, timeout=60))
        for p in resp.get("response", {}).get("publishedfiledetails", []):
            for m in re.findall(r"Mod ID:\s*([A-Za-z0-9_]+)", p.get("description", "")):
                if m not in mod_ids:
                    mod_ids.append(m)

    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(target, "w") as f:
        if workshop_ids:
            f.write("WorkshopItems=" + ";".join(workshop_ids) + "\n")
        if mod_ids:
            f.write("Mods=" + ";".join(mod_ids) + "\n")
        with open(static) as s:
            f.write(s.read())
  '';
in
# The rendered script: `zomboid-plugins <target-ini-path>`.
pkgs.writeShellScript "zomboid-plugins" ''
  exec ${python}/bin/python3 ${resolver} "$1" ${staticFragment}
''
