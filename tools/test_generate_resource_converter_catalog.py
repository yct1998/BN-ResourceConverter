import importlib.util
import pathlib
import sys
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parent / "generate_resource_converter_catalog.py"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("rcgen_test", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class CatalogGenerationTests(unittest.TestCase):
    def test_ammo_items_shadowed_by_ammo_types_are_kept_buyable(self):
        module = load_generator_module()
        module.build_registry()

        meta, category_items, items = module.build_catalog()

        self.assertIn("thread", items)
        self.assertEqual("AMMO", items["thread"]["type"])
        self.assertEqual("ammo", items["thread"]["category"])

        self.assertIn("battery", items)
        self.assertEqual("AMMO", items["battery"]["type"])
        self.assertEqual("ammo", items["battery"]["category"])

    def test_zero_price_material_ammo_items_are_included(self):
        module = load_generator_module()
        module.build_registry()

        meta, category_items, items = module.build_catalog()

        self.assertIn("glass_shard", items)
        self.assertEqual("AMMO", items["glass_shard"]["type"])
        self.assertEqual("ammo", items["glass_shard"]["category"])
        self.assertGreater(items["glass_shard"]["price"], 0)

    def test_only_charge_based_items_use_spawn_charges(self):
        module = load_generator_module()
        module.build_registry()

        meta, category_items, items = module.build_catalog()

        self.assertTrue(items["battery"]["charge_based"])
        self.assertEqual(100, items["battery"]["spawn_charges"])

        self.assertFalse(items["2x4"]["charge_based"])
        self.assertEqual(0, items["2x4"]["spawn_charges"])

        self.assertFalse(items["UPS_off"]["charge_based"])
        self.assertEqual(0, items["UPS_off"]["spawn_charges"])


if __name__ == "__main__":
    unittest.main()
