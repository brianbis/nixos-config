import typing

from BaseClasses import Location

from .Items import MAX_CHECKS, MAX_ROOMS


class LocationData(typing.NamedTuple):
    id: int
    region: str


class SkeletonLocation(Location):
    game: str = "Skeleton"


base_id = 20000
location_table = {
    f"Room {i} Check {j}": LocationData(base_id + (i - 1) * MAX_CHECKS + (j - 1), f"Room {i}")
    for i in range(1, MAX_ROOMS + 1)
    for j in range(1, MAX_CHECKS + 1)
}
location_table["Vault"] = LocationData(base_id + MAX_ROOMS * MAX_CHECKS, "Vault")

lookup_id_to_name: typing.Dict[int, str] = {data.id: name for name, data in location_table.items()}
