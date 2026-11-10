#!/usr/bin/env python3
"""Assemble a local-only, pinned candidate and export reviewable check outputs."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys

PR = "8179339d1e1a78715bc4d642d96d990cbc28ba39"
BASE = "edfcf9000c05eb4636b0b3d406c487c5c14decc1"
REMOTE = "https://github.com/vectordotdev/vector.git"
INPUT = Path(os.environ["RUNNER_TEMP"]) / "vector25536-input"
RESULTS = Path(os.environ["RUNNER_TEMP"]) / "vector25536-results"
RESULTS.mkdir(exist_ok=True)


def git(*args):
    return subprocess.check_output(["git", *args]).decode().strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


mode = sys.argv[1]
if mode == "assemble":
    payload_bytes = (INPUT / "vector25536-conflict-resolution.json").read_bytes()
    payload = json.loads(payload_bytes)
    assert payload["pr_head"] == PR and payload["upstream_head"] == BASE
    assert git("rev-parse", "HEAD") == BASE
    assert git("ls-remote", REMOTE, "refs/pull/25536/head").split()[0] == PR, "PR moved; stop"
    git("fetch", "--no-tags", "--depth=1", REMOTE, "refs/pull/25536/head")
    assert git("rev-parse", "FETCH_HEAD") == PR, "PR moved while fetching"
    files = payload["files"]
    assert len(files) == 10 and set(files) == set(payload["sha256"])
    for name, content in files.items():
        path = PurePosixPath(name)
        assert not path.is_absolute() and ".." not in path.parts and ".git" not in path.parts
        assert path.as_posix() == name and isinstance(content, str)
        dest = Path(name)
        assert not any(p.is_symlink() for p in [dest, *dest.parents])
        data = content.encode("utf-8")
        assert sha(data) == payload["sha256"][name], f"Hash mismatch: {name}"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
    git("add", "--", *files)
    changed = set(git("diff", "--cached", "--name-only", BASE).splitlines())
    assert changed == set(files), "Payload does not exactly identify all candidate changes"
    tree = git("write-tree")
    identity = {
        "GIT_AUTHOR_NAME": "Vector Validation", "GIT_COMMITTER_NAME": "Vector Validation",
        "GIT_AUTHOR_EMAIL": "validation@example.invalid", "GIT_COMMITTER_EMAIL": "validation@example.invalid",
    }
    commit = subprocess.check_output(
        ["git", "-c", "commit.gpgsign=false", "commit-tree", tree, "-p", PR, "-p", BASE],
        input=b"Validate pinned Datadog API key conflict resolution\n", env={**os.environ, **identity},
    ).decode().strip()
    git("checkout", "--detach", commit)
    # vdev fmt compares against origin/master; exact-SHA shallow checkout omits it.
    # Pin this local-only reference to the validated base, never the moving remote master.
    git("update-ref", "refs/remotes/origin/master", BASE)
    assert git("merge-base", "origin/master", "HEAD") == BASE
    assert git("rev-parse", "HEAD^1") == PR and git("rev-parse", "HEAD^2") == BASE
    assert git("rev-parse", "HEAD^{tree}") == tree
    assert not git("status", "--porcelain")
    (RESULTS / "provenance.json").write_text(json.dumps({
        "pr_head": PR, "upstream_head": BASE, "candidate_tree": tree,
        "local_merge_commit": commit, "payload_sha256": sha(payload_bytes),
    }, indent=2) + "\n")
elif mode == "snapshot":
    # Include generated JSON and every example, including untracked files.
    paths = sorted(Path("website/generated/example-configs").rglob("*.yaml"))
    paths.append(Path("website/data/docs.json"))
    hashes = {p.as_posix(): sha(p.read_bytes()) for p in paths}
    (RESULTS / f"examples-{sys.argv[2]}.json").write_text(json.dumps(hashes, sort_keys=True, indent=2) + "\n")
elif mode == "collect":
    if not (RESULTS / "provenance.json").exists():
        (RESULTS / "check-result.txt").write_text("Candidate assembly did not complete. Inspect workflow logs.\n")
        sys.exit(0)
    with (RESULTS / "proposed-fixes.patch").open("wb") as output:
        subprocess.run(["git", "diff", "--binary", "HEAD"], stdout=output, check=True)
    names = git("diff", "--name-only", "HEAD").splitlines()
    names += git("ls-files", "--others", "--exclude-standard").splitlines()
    fixes = {n: Path(n).read_text() if Path(n).exists() else None for n in names}
    (RESULTS / "proposed-fixes.json").write_text(json.dumps(fixes, indent=2) + "\n")
    if not (RESULTS / "check-result.txt").exists():
        (RESULTS / "check-result.txt").write_text("Check failed or did not complete. Inspect workflow logs.\n")
else:
    raise SystemExit("Unknown mode")
