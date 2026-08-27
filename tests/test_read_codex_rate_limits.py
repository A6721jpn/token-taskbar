import unittest

from app import read_codex_rate_limits as reader


class ClassifyRateLimitWindowsTests(unittest.TestCase):
    def test_current_weekly_only_primary_window(self) -> None:
        weekly = {"used_percent": 5, "limit_window_seconds": 604800}

        short_window, weekly_window = reader.classify_rate_limit_windows(weekly, None)

        self.assertIsNone(short_window)
        self.assertIs(weekly_window, weekly)

    def test_legacy_primary_short_secondary_weekly(self) -> None:
        short = {"used_percent": 20, "limit_window_seconds": 18000}
        weekly = {"used_percent": 30, "limit_window_seconds": 604800}

        short_window, weekly_window = reader.classify_rate_limit_windows(short, weekly)

        self.assertIs(short_window, short)
        self.assertIs(weekly_window, weekly)

    def test_duration_wins_when_positions_are_swapped(self) -> None:
        weekly = {"used_percent": 30, "window_minutes": 10080}
        short = {"used_percent": 20, "window_minutes": 300}

        short_window, weekly_window = reader.classify_rate_limit_windows(weekly, short)

        self.assertIs(short_window, short)
        self.assertIs(weekly_window, weekly)

    def test_two_windows_without_duration_keep_legacy_positions(self) -> None:
        primary = {"used_percent": 20}
        secondary = {"used_percent": 30}

        short_window, weekly_window = reader.classify_rate_limit_windows(primary, secondary)

        self.assertIs(short_window, primary)
        self.assertIs(weekly_window, secondary)


if __name__ == "__main__":
    unittest.main()
