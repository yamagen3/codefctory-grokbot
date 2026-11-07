import unittest

from factory_timeline import __version__


class ScaffoldTest(unittest.TestCase):
    def test_version(self) -> None:
        self.assertEqual(__version__, "0.0.0")


if __name__ == "__main__":
    unittest.main()
