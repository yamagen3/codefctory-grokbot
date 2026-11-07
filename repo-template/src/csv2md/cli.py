"""CLI entry — empty scaffold; OpenCode fills implementation."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    """Convert CSV file(s) to a Markdown table on stdout.

    Not implemented yet. Spec and acceptance tests live under spec/ and
    tests/acceptance/ once the factory spec step completes.
    """
    _ = argv if argv is not None else sys.argv[1:]
    print("csv2md: not implemented", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
