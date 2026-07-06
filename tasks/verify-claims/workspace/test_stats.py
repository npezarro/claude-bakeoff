import unittest

from stats import mean, median, value_range


class TestStats(unittest.TestCase):
    def test_mean(self):
        self.assertEqual(mean([1, 2, 3, 4]), 2.5)

    def test_median_odd(self):
        self.assertEqual(median([5, 1, 3]), 3)

    def test_median_even(self):
        self.assertEqual(median([1, 2, 3, 4]), 2.5)

    def test_range(self):
        self.assertEqual(value_range([7, 2, 9]), 7)


if __name__ == "__main__":
    unittest.main()
