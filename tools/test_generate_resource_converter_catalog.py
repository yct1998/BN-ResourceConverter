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


if __name__ == "__main__":
    unittest.main()
