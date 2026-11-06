"""Check readable text colors against the surfaces on which the UI uses them."""
from pathlib import Path
import re
import unittest


class ContrastTests(unittest.TestCase):
    def test_active_text_tokens_meet_normal_text_contrast(self):
        source = (Path(__file__).resolve().parents[2] / "App/Views/DesignSystem.swift").read_text()
        colors = {name: (int(light, 16), int(dark, 16)) for name, light, dark in
                  re.findall(r"static let (\w+) = adaptive\(0x([0-9A-F]+), dark: 0x([0-9A-F]+)\)", source)}

        def luminance(value):
            channels = [(value >> bit & 255) / 255 for bit in (16, 8, 0)]
            linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in channels]
            return sum(v * weight for v, weight in zip(linear, [.2126, .7152, .0722]))

        for foreground in ("text", "secondary", "teal", "gold"):
            for background in ("surface", "background", "sidebar"):
                for mode in (0, 1):
                    with self.subTest(foreground=foreground, background=background, mode=mode):
                        high, low = sorted([luminance(colors[foreground][mode]), luminance(colors[background][mode])], reverse=True)
                        self.assertGreaterEqual((high + .05) / (low + .05), 4.5)
