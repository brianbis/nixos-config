from BaseClasses import Entrance, Region, MultiWorld


def create_regions(multiworld: MultiWorld, player: int) -> None:
    """Menu -> Room 1 (free bootstrap) + Room 2..N (keyed) and Menu -> Vault (master key)."""
    menu = Region("Menu", player, multiworld)
    multiworld.regions.append(menu)

    room_count = multiworld.worlds[player].options.room_count.value
    for i in range(1, room_count + 1):
        room = Region(f"Room {i}", player, multiworld)
        multiworld.regions.append(room)

        door = Entrance(player, f"Room {i} Door", menu)
        menu.exits.append(door)
        door.connect(room)

    vault = Region("Vault", player, multiworld)
    multiworld.regions.append(vault)

    vault_door = Entrance(player, "Vault Door", menu)
    menu.exits.append(vault_door)
    vault_door.connect(vault)
