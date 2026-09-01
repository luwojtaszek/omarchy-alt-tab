import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]


class ThemeStyleTests(unittest.TestCase):
    def test_card_follows_omarchy_corner_radius(self):
        qml = (ROOT / "Switcher.qml").read_text()
        card = qml.split("id: card", 1)[1].split("MouseArea", 1)[0]
        self.assertIn("radius: Style.cornerRadius", card)
        self.assertNotRegex(card, r"radius:\s*[1-9][0-9]*")

    def test_change_does_not_add_a_macos_variant(self):
        qml = (ROOT / "Switcher.qml").read_text()
        self.assertNotIn('variant === "macos"', qml)
