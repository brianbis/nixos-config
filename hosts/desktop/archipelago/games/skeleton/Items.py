import typing

from BaseClasses import Item

# Superset bounds: the room_count / checks_per_room options scale the world
# size, so the id tables cover the maximum possible size.
MAX_ROOMS = 10
MAX_CHECKS = 5


class ItemData(typing.NamedTuple):
    code: int
    progression: bool = True


class SkeletonItem(Item):
    game: str = "Skeleton"


# One key per keyed room (progression, required to enter the matching room)
# plus the master key (progression, required for the vault). Room 1 is the
# free bootstrap, so "Room 1 Key" is part of the superset but never placed.
# The superset covers the maximum room_count so item_name_to_id is stable
# across option values.
item_table = {
    **{f"Room {i} Key": ItemData(10000 + i) for i in range(1, MAX_ROOMS + 1)},
    "Master Key": ItemData(10000 + MAX_ROOMS + 1),
    # Filler items.
    "Bone": ItemData(10000 + MAX_ROOMS + 2, progression=False),
    "Skull Shard": ItemData(10000 + MAX_ROOMS + 3, progression=False),
    "Ribbon": ItemData(10000 + MAX_ROOMS + 4, progression=False),
}

# Event item placed at the Vault location (not part of the item pool).
event_code = 10000 + MAX_ROOMS + 5

lookup_id_to_name: typing.Dict[int, str] = {
    data.code: name for name, data in item_table.items()
}
