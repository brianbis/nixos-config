from BaseClasses import MultiWorld


def set_rules(multiworld: MultiWorld, player: int) -> None:
    room_count = multiworld.worlds[player].options.room_count.value
    # Room 1 is the bootstrap: always accessible, so the player has a starting
    # point (its checks can hold the keys to the other rooms). Rooms 2..N each
    # require their own key.
    for i in range(2, room_count + 1):
        multiworld.get_entrance(f"Room {i} Door", player).access_rule = \
            lambda state, i=i: state.has(f"Room {i} Key", player)

    multiworld.get_entrance("Vault Door", player).access_rule = \
        lambda state: state.has("Master Key", player)


def set_completion_rules(multiworld: MultiWorld, player: int) -> None:
    multiworld.completion_condition[player] = \
        lambda state: state.has("Final Check", player)
