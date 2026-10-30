import unittest

import oralb_protocol as p


class AdvertisementTests(unittest.TestCase):
    def test_eleven_byte_advertisement(self):
        # protocol 3, D700 6-mode, fw 4, running, normal, 1:05, deep clean, sector 2
        adv = p.parse_advertisement(bytes([3, 41, 4, 3, 0x32, 1, 5, 5, 2, 10, 4]))
        s = adv.summary()
        self.assertEqual(s["model"], "D700 Smart/Pro Series (6 mode)")
        self.assertEqual(s["state"], "running")
        self.assertEqual(s["time"], "1:05")
        self.assertEqual(s["mode"], "deep clean")
        self.assertEqual(s["sector"], "sector 2")

    def test_nine_byte_advertisement_has_no_sector_count(self):
        adv = p.parse_advertisement(bytes([1, 0, 1, 2, 0, 0, 0, 1, 0]))
        self.assertIsNone(adv.sector_count)
        self.assertEqual(adv.summary()["state"], "idle")

    def test_other_lengths_are_ignored(self):
        self.assertIsNone(p.parse_advertisement(bytes(10)))

    def test_pressure_flags_button_wins(self):
        self.assertEqual(p.decode_pressure_flags(0x80 | 0x08), "power button pressed")
        self.assertEqual(p.decode_pressure_flags(0x80 | 0x04), "button pressed")
        self.assertEqual(p.decode_pressure_flags(0xF2), "high")
        self.assertEqual(p.decode_pressure_flags(0x72), "normal")

    def test_last_sector_sentinel(self):
        self.assertEqual(p.decode_sector(7, 6), "sector 6")
        self.assertEqual(p.decode_sector(7, None), "sector 4")


class CharacteristicTests(unittest.TestCase):
    def test_uuid(self):
        self.assertEqual(p.CHAR_AVAILABLE_MODES, "a0f0ff25-5047-4d53-8208-4f72616c2d42")

    def test_battery(self):
        self.assertEqual(p.decode_battery(bytes([87, 0x10, 0x0E, 0])), {"percent": 87, "seconds_left": 3600})

    def test_time(self):
        self.assertEqual(p.decode_time((86400).to_bytes(4, "little")), "2000-01-02T00:00:00+00:00")


class AvailableModesTests(unittest.TestCase):
    current = bytes([1, 2, 3, 4, 5, 7, 0xFF, 0xFF])

    def test_pads_with_handles_own_filler(self):
        self.assertEqual(p.encode_available_modes([1, 5], self.current), bytes([1, 5]) + b"\xff" * 6)

    def test_full_list_needs_no_filler(self):
        full = bytes([1, 2, 3, 4, 5, 6, 7, 1])
        self.assertEqual(p.encode_available_modes([7, 6, 5, 4, 3, 2, 1], full[:7]), bytes([7, 6, 5, 4, 3, 2, 1]))

    def test_refuses_to_guess_filler(self):
        with self.assertRaises(ValueError):
            p.encode_available_modes([1], bytes([1, 2, 3, 4, 5, 6, 7, 1]))

    def test_rejects_undocumented_and_duplicate_modes(self):
        for bad in ([9], [0], [255], [1, 1], []):
            with self.assertRaises(ValueError):
                p.encode_available_modes(bad, self.current)


class SessionTests(unittest.TestCase):
    def test_protocol_4_pressure_is_tenths(self):
        rec = (86400).to_bytes(4, "little") + (120).to_bytes(2, "little") + bytes([3, 1]) \
            + (55).to_bytes(2, "little") + bytes([2, 80]) + bytes(4)
        s = p.decode_session(rec, 4)
        self.assertEqual(s["duration_s"], 120)
        self.assertEqual(s["mode"], "daily clean")
        self.assertEqual(s["pressure_time_s"], 5.5)


if __name__ == "__main__":
    unittest.main()
