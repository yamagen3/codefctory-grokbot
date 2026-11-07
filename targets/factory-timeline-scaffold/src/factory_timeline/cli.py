"""CLI entry — empty scaffold; OpenCode fills implementation."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    """factory-timeline CLI (events / summary / html). Not implemented yet."""
    _ = argv if argv is not None else sys.argv[1:]
    print("factory-timeline: not implemented", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
