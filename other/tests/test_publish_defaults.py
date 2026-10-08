import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO / "other" / "publish_defaults.py"
SPEC = importlib.util.spec_from_file_location("publish_defaults", MODULE_PATH)
publish_defaults = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publish_defaults)


class PublishDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.payload = json.loads(publish_defaults.CONFIG.read_text())

    def validate_payload(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "defaults.json"
            path.write_text(json.dumps(payload))
            return publish_defaults.validate(path)

    def test_checked_in_defaults_validate(self):
        self.assertTrue(publish_defaults.validate(publish_defaults.CONFIG))

    def test_unknown_key_is_rejected(self):
        payload = json.loads(json.dumps(self.payload))
        payload["defaults"]["unexpectedSetting"] = True
        with self.assertRaises(ValueError):
            self.validate_payload(payload)

    def test_boolean_cannot_be_replaced_by_number(self):
        payload = json.loads(json.dumps(self.payload))
        key = next(key for key, value in payload["defaults"].items() if type(value) is bool)
        payload["defaults"][key] = 1
        with self.assertRaises(ValueError):
            self.validate_payload(payload)

    def test_schema_version_must_be_an_integer(self):
        payload = json.loads(json.dumps(self.payload))
        payload["schemaVersion"] = True
        with self.assertRaises(ValueError):
            self.validate_payload(payload)


if __name__ == "__main__":
    unittest.main()
