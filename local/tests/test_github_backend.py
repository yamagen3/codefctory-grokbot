#!/usr/bin/env python3
"""Unit tests for local + github backends with mocked HTTP server."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "lib"))

from factory_github.client import LocalBackend, GitHubBackend, get_backend  # noqa: E402


class MockGH(BaseHTTPRequestHandler):
    store: dict = {"statuses": [], "labels": {}, "pulls": [], "merges": []}

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self._read()
        if "/statuses/" in self.path:
            MockGH.store["statuses"].append({"path": self.path, **body})
            self._json(201, {"state": body.get("state"), "context": body.get("context")})
        elif self.path.endswith("/pulls"):
            num = len(MockGH.store["pulls"]) + 1
            rec = {"number": num, "html_url": f"http://example/pr/{num}", **body}
            MockGH.store["pulls"].append(rec)
            self._json(201, rec)
        elif self.path.endswith("/labels"):
            pr = self.path.split("/")[-2]
            MockGH.store["labels"].setdefault(pr, [])
            for lab in body.get("labels", []):
                MockGH.store["labels"][pr].append({"name": lab})
            self._json(200, MockGH.store["labels"][pr])
        else:
            self._json(404, {"message": "no " + self.path})

    def do_GET(self):
        if self.path.endswith("/labels"):
            pr = self.path.split("/")[-2]
            self._json(200, MockGH.store["labels"].get(pr, []))
        else:
            self._json(404, {"message": "no"})

    def do_DELETE(self):
        self._json(204, {})

    def do_PUT(self):
        body = self._read()
        if self.path.endswith("/merge"):
            MockGH.store["merges"].append({"path": self.path, **body})
            self._json(200, {"merged": True, "sha": body.get("sha")})
        else:
            self._json(404, {"message": "no"})


def test_local_status_and_required():
    with tempfile.TemporaryDirectory() as td:
        os.environ["FACTORY_ROOT"] = td
        os.environ["FACTORY_STATUS_DIR"] = str(Path(td) / "status")
        os.environ["FACTORY_LABELS_DIR"] = str(Path(td) / "labels")
        os.environ["FACTORY_PR_DIR"] = str(Path(td) / "prs")
        os.environ["FACTORY_BACKEND"] = "local"
        b = get_backend()
        assert b.name == "local"
        repo = td  # unused for status files
        sha = "abc123"
        for ctx in ("guard", "ci", "gate/claude", "gate/grok"):
            assert not b.status_required_ok(repo, sha)
            b.status_set(repo, sha, ctx, "success", "ok")
        assert b.status_required_ok(repo, sha)
        assert b.status_get(repo, sha, "guard")["state"] == "success"
        assert b.labels_set_round(repo, "id1", 2) == "round-2"
        assert b.labels_get_round(repo, "id1") == 2
        pr = b.pr_create(repo, "id1", "t")
        assert pr["number"] == 1


def test_github_backend_mocked():
    MockGH.store = {"statuses": [], "labels": {}, "pulls": [], "merges": []}
    server = HTTPServer(("127.0.0.1", 0), MockGH)
    port = server.server_address[1]
    th = threading.Thread(target=server.serve_forever, daemon=True)
    th.start()
    with tempfile.TemporaryDirectory() as td:
        os.environ["FACTORY_ROOT"] = td
        os.environ["FACTORY_STATUS_DIR"] = str(Path(td) / "status")
        os.environ["FACTORY_LABELS_DIR"] = str(Path(td) / "labels")
        os.environ["FACTORY_PR_DIR"] = str(Path(td) / "prs")
        os.environ["FACTORY_BACKEND"] = "github"
        os.environ["FACTORY_GITHUB_API"] = f"http://127.0.0.1:{port}"
        os.environ["FACTORY_GITHUB_REPO"] = "acme/csv2md"
        os.environ["FACTORY_GITHUB_TOKEN_GROK"] = "test-grok-token"
        os.environ["FACTORY_GITHUB_TOKEN_CC"] = "test-cc-token"
        b = GitHubBackend()
        sha = "deadbeef"
        b.status_set(td, sha, "guard", "success", "ok")
        assert MockGH.store["statuses"], "status POST not received"
        assert MockGH.store["statuses"][0]["context"] == "guard"
        assert b.status_required_ok(td, sha) is False  # only one check
        for ctx in ("ci", "gate/claude", "gate/grok"):
            b.status_set(td, sha, ctx, "success", "ok")
        assert b.status_required_ok(td, sha)
        pr = b.pr_create(td, "x1", "title", "body")
        assert pr["number"] == 1
        assert MockGH.store["pulls"]
        b.labels_set_round(td, "x1", 1, pr=1)
        assert any(l["name"] == "round-1" for l in MockGH.store["labels"].get("1", []))
        # merge API (skip local git — call http path via backend after planting pr)
        # Directly exercise merge HTTP by temporary monkey: use incomplete sha check
        # Plant all statuses already done; create fake git repo for rev-parse
        import subprocess
        subprocess.check_call(["git", "init", "-b", "main", td])
        subprocess.check_call(["git", "-C", td, "commit", "--allow-empty", "-m", "m"], env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
        subprocess.check_call(["git", "-C", td, "checkout", "-b", "factory/x1"])
        subprocess.check_call(["git", "-C", td, "commit", "--allow-empty", "-m", "f"], env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})
        sha2 = subprocess.check_output(["git", "-C", td, "rev-parse", "HEAD"], text=True).strip()
        for ctx in ("guard", "ci", "gate/claude", "gate/grok"):
            b.status_set(td, sha2, ctx, "success", "ok")
        out = b.pr_merge(td, "x1", sha2)
        assert out["merged"] is True
        assert MockGH.store["merges"], "merge PUT not received"
    server.shutdown()


def test_default_backend_is_local():
    os.environ.pop("FACTORY_BACKEND", None)
    with tempfile.TemporaryDirectory() as td:
        os.environ["FACTORY_ROOT"] = td
        assert get_backend().name == "local"


if __name__ == "__main__":
    test_local_status_and_required()
    print("test_local: PASS")
    test_github_backend_mocked()
    print("test_github_mocked: PASS")
    test_default_backend_is_local()
    print("test_default_local: PASS")
    print("ALL PASS")
