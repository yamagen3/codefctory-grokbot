import unittest

from csv2md import __version__


class ScaffoldTest(unittest.TestCase):
    def test_version(self) -> None:
        self.assertEqual(__version__, "0.0.0")


if __name__ == "__main__":
    unittest.main()
