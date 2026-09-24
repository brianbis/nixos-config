from dataclasses import dataclass

from Options import PerGameCommonOptions, Range, Toggle


class RoomCount(Range):
    """
    Number of rooms in the crypt. Each room holds checks_per_room checks and
    is locked behind its own key.
    """

    display_name = "Room Count"
    range_start = 1
    range_end = 10
    default = 5


class ChecksPerRoom(Range):
    """
    Number of checks in each room.
    """

    display_name = "Checks per Room"
    range_start = 1
    range_end = 5
    default = 3


class StartWithKeys(Toggle):
    """
    Start with all room keys and the master key. Rooms are open from the
    beginning; only the checks remain to find.
    """

    display_name = "Start With Keys"
    default = 0


@dataclass
class SkeletonOptions(PerGameCommonOptions):
    room_count: RoomCount
    checks_per_room: ChecksPerRoom
    start_with_keys: StartWithKeys
