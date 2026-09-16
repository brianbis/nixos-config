# Skeleton — Multiworld Setup Guide

Skeleton is a self-contained skeleton world: no ROM, no game files, no client
binary. It exists to demonstrate a complete Archipelago world (items,
locations, regions, rules, options, web integration, tests) and to serve as a
starting point for new worlds.

## How it plays

- The crypt has `Room Count` rooms, each holding `Checks per Room` checks.
- Every room is locked behind its own **Room Key**; the **Vault** is locked
  behind the **Master Key**.
- Collect the **Final Check** in the vault to complete the world.
- With **Start With Keys** enabled, all keys are in your starting inventory.

In a real multiworld, checks and keys are shuffled across all players' worlds
by the Archipelago server; this guide only covers the world's own structure.

## Options

| Option | Default | Description |
| --- | --- | --- |
| Room Count | 5 | Number of rooms (1–10). |
| Checks per Room | 3 | Checks in each room (1–5). |
| Start With Keys | off | Begin with all keys. |

## Building a world from this skeleton

1. Copy `~/.local/share/Archipelago/worlds/skeleton` to a new lowercase
   directory (e.g. `mygame`).
2. Rename the classes (`SkeletonWorld` → `MyGameWorld`), the `game` name, and
   the `archipelago.json` "game" field.
3. Replace the id tables in `Items.py` / `Locations.py` with your game's real
   items and locations.
4. Rebuild regions and rules in `Regions.py` / `Rules.py`.
5. Run `archipelago-generate` with a `Players/<name>.yaml` selecting your game,
   or generate from the web UI at `https://archipelago.local`.
