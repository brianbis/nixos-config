from ..Items import MAX_CHECKS, MAX_ROOMS
from ..Locations import location_table
from . import SkeletonTestBase


class TestSkeleton(SkeletonTestBase):
    def test_pool_matches_locations(self):
        room_count = self.world.options.room_count.value
        checks_per_room = self.world.options.checks_per_room.value
        expected = room_count * checks_per_room + 1  # + vault event location
        self.assertEqual(len(self.multiworld.itempool) + 1, expected)

    def test_id_tables_are_supersets(self):
        self.assertEqual(len(self.world.item_name_to_id), MAX_ROOMS + 4)
        self.assertEqual(
            len(self.world.location_name_to_id), MAX_ROOMS * MAX_CHECKS + 1
        )

    def test_room1_is_bootstrap(self):
        # Room 1 needs no key: it is the player's starting point.
        entrance = self.multiworld.get_entrance("Room 1 Door", 1)
        self.assertTrue(entrance.can_reach(self.multiworld.state))

    def test_keys_gate_rooms(self):
        for i in range(2, self.world.options.room_count.value + 1):
            entrance = self.multiworld.get_entrance(f"Room {i} Door", 1)
            self.assertFalse(entrance.can_reach(self.multiworld.state))
            self.multiworld.state.collect(self.world.create_item(f"Room {i} Key"))
            self.assertTrue(entrance.can_reach(self.multiworld.state))

    def test_vault_needs_master_key(self):
        entrance = self.multiworld.get_entrance("Vault Door", 1)
        self.assertFalse(entrance.can_reach(self.multiworld.state))
        self.multiworld.state.collect(self.world.create_item("Master Key"))
        self.assertTrue(entrance.can_reach(self.multiworld.state))

    def test_completion_is_vault_event(self):
        vault = self.multiworld.get_location("Vault", 1)
        self.assertIsNotNone(vault.item)
        self.assertEqual(vault.item.name, "Final Check")
        self.assertFalse(self.multiworld.has_beaten_game(self.multiworld.state, 1))
        self.multiworld.state.collect(vault.item)
        self.assertTrue(self.multiworld.has_beaten_game(self.multiworld.state, 1))

    def test_start_with_keys(self):
        self.options = {"start_with_keys": 1}
        self.world_setup()
        # Room 1 is always reachable; rooms 2..N and the vault are reachable
        # because the player starts with all the keys.
        for i in range(1, self.world.options.room_count.value + 1):
            entrance = self.multiworld.get_entrance(f"Room {i} Door", 1)
            self.assertTrue(entrance.can_reach(self.multiworld.state))
        self.assertTrue(
            self.multiworld.get_entrance("Vault Door", 1).can_reach(
                self.multiworld.state
            )
        )
