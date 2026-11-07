"""CLI: python -m factory_github <cmd> ..."""
from __future__ import annotations

import json
import sys
from .client import get_backend


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: factory_github status-set|status-get|status-required-ok|labels-set-round|labels-get-round|pr-create|pr-merge ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    b = get_backend()
    try:
        if cmd == "status-set":
            _, _, repo, sha, ctx, state, *rest = argv
            desc = rest[0] if rest else ""
            print(json.dumps(b.status_set(repo, sha, ctx, state, desc)))
        elif cmd == "status-get":
            repo, sha = argv[2], argv[3]
            ctx = argv[4] if len(argv) > 4 else None
            print(json.dumps(b.status_get(repo, sha, ctx), indent=2))
        elif cmd == "status-required-ok":
            repo, sha = argv[2], argv[3]
            ok = b.status_required_ok(repo, sha)
            print("required-ok: PASS" if ok else "required-ok: FAIL")
            return 0 if ok else 1
        elif cmd == "labels-set-round":
            repo, id_, n = argv[2], argv[3], int(argv[4])
            pr = int(argv[5]) if len(argv) > 5 else None
            print(b.labels_set_round(repo, id_, n, pr))
        elif cmd == "labels-get-round":
            print(b.labels_get_round(argv[2], argv[3]))
        elif cmd == "pr-create":
            repo, id_, title = argv[2], argv[3], argv[4]
            body = argv[5] if len(argv) > 5 else ""
            print(json.dumps(b.pr_create(repo, id_, title, body), indent=2))
        elif cmd == "pr-merge":
            repo, id_ = argv[2], argv[3]
            sha = argv[4] if len(argv) > 4 else None
            print(json.dumps(b.pr_merge(repo, id_, sha), indent=2))
        else:
            print(f"unknown cmd {cmd}", file=sys.stderr)
            return 2
    except Exception as e:
        print(f"factory_github: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
