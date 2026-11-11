"""Backends: local (default) | github (Statuses / PR labels / PR / merge).

Env:
  FACTORY_BACKEND=local|github  (default local)
  FACTORY_GITHUB_TOKEN_GROK, FACTORY_GITHUB_TOKEN_CC, FACTORY_GITHUB_REPO
  FACTORY_GITHUB_API  (default https://api.github.com) — override for mocks
  FACTORY_STATUS_DIR, FACTORY_LABELS_DIR, FACTORY_PR_DIR
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

REQUIRED = ("guard", "ci", "gate/claude", "gate/grok")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _factory_root() -> Path:
    env = os.environ.get("FACTORY_ROOT")
    if env:
        return Path(env)
    # lib/factory_github/client.py → repo root. Original host: /workspace/factory.
    return Path(__file__).resolve().parents[2]


@dataclass
class HttpResponse:
    status: int
    body: Any
    headers: dict


class HttpClient:
    """Minimal JSON HTTP client; FACTORY_GITHUB_API base for tests."""

    def __init__(self, token: str, api_base: Optional[str] = None):
        self.token = token
        self.api_base = (api_base or os.environ.get("FACTORY_GITHUB_API") or "https://api.github.com").rstrip("/")

    def request(self, method: str, path: str, payload: Optional[dict] = None) -> HttpResponse:
        url = path if path.startswith("http") else f"{self.api_base}{path}"
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
                "User-Agent": "factory-local",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode() or "{}"
                body = json.loads(raw) if raw.strip() else {}
                return HttpResponse(resp.status, body, dict(resp.headers))
        except urllib.error.HTTPError as e:
            err_body = e.read().decode() if e.fp else ""
            try:
                parsed = json.loads(err_body) if err_body else {"message": str(e)}
            except json.JSONDecodeError:
                parsed = {"message": err_body or str(e)}
            raise RuntimeError(f"GitHub API {method} {path} -> {e.code}: {parsed}") from e


class Backend:
    name: str

    def status_set(self, repo: str, sha: str, context: str, state: str, description: str = "") -> dict: ...
    def status_get(self, repo: str, sha: str, context: Optional[str] = None) -> Any: ...
    def status_required_ok(self, repo: str, sha: str) -> bool: ...
    def labels_set_round(self, repo: str, id_: str, n: int, pr: Optional[int] = None) -> str: ...
    def labels_get_round(self, repo: str, id_: str, pr: Optional[int] = None) -> int: ...
    def pr_create(self, repo: str, id_: str, title: str, body: str = "") -> dict: ...
    def pr_merge(self, repo: str, id_: str, sha: Optional[str] = None) -> dict: ...


class LocalBackend(Backend):
    name = "local"

    def __init__(self) -> None:
        root = _factory_root()
        self.status_dir = Path(os.environ.get("FACTORY_STATUS_DIR", root / "local/status"))
        self.labels_dir = Path(os.environ.get("FACTORY_LABELS_DIR", root / "local/labels"))
        self.pr_dir = Path(os.environ.get("FACTORY_PR_DIR", root / "local/prs"))
        self.status_dir.mkdir(parents=True, exist_ok=True)
        self.labels_dir.mkdir(parents=True, exist_ok=True)
        self.pr_dir.mkdir(parents=True, exist_ok=True)

    def _status_path(self, sha: str) -> Path:
        return self.status_dir / f"{sha}.json"

    def _read_status(self, sha: str) -> dict:
        p = self._status_path(sha)
        return json.loads(p.read_text()) if p.exists() else {}

    def status_set(self, repo: str, sha: str, context: str, state: str, description: str = "") -> dict:
        if state not in ("success", "failure", "pending", "error"):
            raise ValueError(f"bad state {state}")
        data = self._read_status(sha)
        entry = {"state": state, "description": description, "updated_at": _now()}
        data[context] = entry
        self._status_path(sha).write_text(json.dumps(data, indent=2) + "\n")
        # best-effort git notes
        notes = self._status_path(sha).read_text()
        os.system(
            f'git -C "{repo}" notes --ref=refs/notes/factory-statuses add -f -m {json.dumps(notes)} {sha} >/dev/null 2>&1'
        )
        return entry

    def status_get(self, repo: str, sha: str, context: Optional[str] = None) -> Any:
        data = self._read_status(sha)
        if context:
            return data.get(context, {})
        return data

    def status_required_ok(self, repo: str, sha: str) -> bool:
        data = self._read_status(sha)
        return all(data.get(c, {}).get("state") == "success" for c in REQUIRED)

    def _label_path(self, id_: str) -> Path:
        return self.labels_dir / f"{id_}.json"

    def labels_set_round(self, repo: str, id_: str, n: int, pr: Optional[int] = None) -> str:
        p = self._label_path(id_)
        data = json.loads(p.read_text()) if p.exists() else {"id": id_, "labels": []}
        labels = [x for x in data.get("labels", []) if not str(x).startswith("round-")]
        labels.append(f"round-{n}")
        data = {"id": id_, "labels": labels, "pr": pr, "updated_at": _now()}
        p.write_text(json.dumps(data, indent=2) + "\n")
        Path(repo, ".factory-round").write_text(str(n) + "\n")
        return f"round-{n}"

    def labels_get_round(self, repo: str, id_: str, pr: Optional[int] = None) -> int:
        p = self._label_path(id_)
        if not p.exists():
            return 0
        data = json.loads(p.read_text())
        rounds = [int(x.split("-", 1)[1]) for x in data.get("labels", []) if str(x).startswith("round-")]
        return max(rounds) if rounds else 0

    def pr_create(self, repo: str, id_: str, title: str, body: str = "") -> dict:
        branch = f"factory/{id_}"
        prs = sorted(self.pr_dir.glob("*.json"))
        num = (max(int(x.stem) for x in prs) + 1) if prs else 1
        rec = {
            "number": num,
            "id": id_,
            "title": title,
            "body": body,
            "head": branch,
            "base": "main",
            "state": "open",
            "created_at": _now(),
        }
        (self.pr_dir / f"{num}.json").write_text(json.dumps(rec, indent=2) + "\n")
        # also index by id
        (self.pr_dir / f"id-{id_}.json").write_text(json.dumps(rec, indent=2) + "\n")
        return rec

    def pr_find(self, id_: str) -> Optional[dict]:
        p = self.pr_dir / f"id-{id_}.json"
        return json.loads(p.read_text()) if p.exists() else None

    def pr_merge(self, repo: str, id_: str, sha: Optional[str] = None) -> dict:
        import subprocess

        branch = f"factory/{id_}"
        if sha is None:
            sha = subprocess.check_output(["git", "-C", repo, "rev-parse", branch], text=True).strip()
        if not self.status_required_ok(repo, sha):
            raise RuntimeError(f"required checks not all success for {sha}")
        # local git merge
        subprocess.check_call(["git", "-C", repo, "checkout", "main"])
        subprocess.check_call(
            [
                "git",
                "-C",
                repo,
                "-c",
                "user.email=factory@localhost",
                "-c",
                "user.name=factory",
                "merge",
                "--no-ff",
                "-m",
                f"merge {branch}",
                branch,
            ]
        )
        # push local origin if any
        remotes = subprocess.run(["git", "-C", repo, "remote"], capture_output=True, text=True)
        if "origin" in remotes.stdout.split():
            subprocess.run(["git", "-C", repo, "push", "origin", "main"], check=False)
        pr = self.pr_find(id_) or {}
        if pr:
            pr["state"] = "merged"
            pr["merged_sha"] = sha
            pr["merged_at"] = _now()
            (self.pr_dir / f"{pr['number']}.json").write_text(json.dumps(pr, indent=2) + "\n")
            (self.pr_dir / f"id-{id_}.json").write_text(json.dumps(pr, indent=2) + "\n")
        return {"merged": True, "sha": sha, "backend": "local", "pr": pr}


class GitHubBackend(Backend):
    name = "github"

    def __init__(self) -> None:
        self.repo_slug = os.environ.get("FACTORY_GITHUB_REPO") or ""
        if not self.repo_slug or "/" not in self.repo_slug:
            raise RuntimeError("FACTORY_GITHUB_REPO=owner/name required for github backend")
        self.token_grok = os.environ.get("FACTORY_GITHUB_TOKEN_GROK") or ""
        self.token_cc = os.environ.get("FACTORY_GITHUB_TOKEN_CC") or ""
        if not self.token_grok and not self.token_cc:
            raise RuntimeError("FACTORY_GITHUB_TOKEN_GROK or FACTORY_GITHUB_TOKEN_CC required")
        # Also mirror locally for required-ok when GH listing is awkward
        self.local = LocalBackend()

    def _http(self, for_status: bool = False) -> HttpClient:
        # statuses: prefer CC token (statuses-only), else Grok
        if for_status and self.token_cc:
            tok = self.token_cc
        else:
            tok = self.token_grok or self.token_cc
        if not tok:
            raise RuntimeError("missing GitHub token for this operation")
        return HttpClient(tok)

    def status_set(self, repo: str, sha: str, context: str, state: str, description: str = "") -> dict:
        # Always mirror local for required-ok / offline inspect
        entry = self.local.status_set(repo, sha, context, state, description)
        http = self._http(for_status=True)
        http.request(
            "POST",
            f"/repos/{self.repo_slug}/statuses/{sha}",
            {"state": state, "context": context, "description": description[:140]},
        )
        return entry

    def status_get(self, repo: str, sha: str, context: Optional[str] = None) -> Any:
        # Prefer local mirror; optionally refresh from GH combined status
        return self.local.status_get(repo, sha, context)

    def status_required_ok(self, repo: str, sha: str) -> bool:
        # Local mirror is source for orchestration; GH is push-side
        return self.local.status_required_ok(repo, sha)

    def labels_set_round(self, repo: str, id_: str, n: int, pr: Optional[int] = None) -> str:
        label = self.local.labels_set_round(repo, id_, n, pr)
        if pr is None:
            found = self.local.pr_find(id_)
            pr = found.get("number") if found else None
        if pr is None:
            return label
        http = self._http(for_status=False)
        # remove other round-* then add
        try:
            cur = http.request("GET", f"/repos/{self.repo_slug}/issues/{pr}/labels")
            names = [x["name"] for x in cur.body] if isinstance(cur.body, list) else []
            for name in names:
                if name.startswith("round-") and name != label:
                    http.request("DELETE", f"/repos/{self.repo_slug}/issues/{pr}/labels/{name}")
        except RuntimeError:
            pass
        http.request("POST", f"/repos/{self.repo_slug}/issues/{pr}/labels", {"labels": [label]})
        return label

    def labels_get_round(self, repo: str, id_: str, pr: Optional[int] = None) -> int:
        return self.local.labels_get_round(repo, id_, pr)

    def pr_create(self, repo: str, id_: str, title: str, body: str = "") -> dict:
        http = self._http(for_status=False)
        branch = f"factory/{id_}"
        resp = http.request(
            "POST",
            f"/repos/{self.repo_slug}/pulls",
            {"title": title, "head": branch, "base": "main", "body": body},
        )
        rec = {
            "number": resp.body.get("number"),
            "id": id_,
            "title": title,
            "body": body,
            "head": branch,
            "base": "main",
            "state": "open",
            "html_url": resp.body.get("html_url"),
            "created_at": _now(),
        }
        # mirror
        self.local.pr_dir.mkdir(parents=True, exist_ok=True)
        if rec["number"] is not None:
            (self.local.pr_dir / f"{rec['number']}.json").write_text(json.dumps(rec, indent=2) + "\n")
            (self.local.pr_dir / f"id-{id_}.json").write_text(json.dumps(rec, indent=2) + "\n")
        return rec

    def pr_merge(self, repo: str, id_: str, sha: Optional[str] = None) -> dict:
        import subprocess

        branch = f"factory/{id_}"
        if sha is None:
            sha = subprocess.check_output(["git", "-C", repo, "rev-parse", branch], text=True).strip()
        if not self.status_required_ok(repo, sha):
            raise RuntimeError(f"required checks not all success for {sha}")
        pr = self.local.pr_find(id_)
        if not pr or not pr.get("number"):
            raise RuntimeError(f"no PR number for id={id_}; create PR first")
        http = self._http(for_status=False)
        resp = http.request(
            "PUT",
            f"/repos/{self.repo_slug}/pulls/{pr['number']}/merge",
            {"commit_title": f"merge {branch}", "merge_method": "merge", "sha": sha},
        )
        pr["state"] = "merged"
        pr["merged_at"] = _now()
        (self.local.pr_dir / f"id-{id_}.json").write_text(json.dumps(pr, indent=2) + "\n")
        return {"merged": True, "sha": sha, "backend": "github", "api": resp.body, "pr": pr}


def get_backend(name: Optional[str] = None) -> Backend:
    backend = (name or os.environ.get("FACTORY_BACKEND") or "local").strip().lower()
    if backend == "local":
        return LocalBackend()
    if backend == "github":
        return GitHubBackend()
    raise ValueError(f"unknown FACTORY_BACKEND={backend} (use local|github)")
