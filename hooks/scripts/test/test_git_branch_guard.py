#!/usr/bin/env python3
"""Test suite for hooks/scripts/git_branch_guard.py (og plugin).

Runs the hook as a subprocess (exactly as Claude Code's PreToolUse hook would)
against real throwaway git repos and worktrees built in a temp directory.
Never touches a real repo and makes no network calls.

Run with:
    python3 hooks/scripts/test/test_git_branch_guard.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "git_branch_guard.py")

pass_count = 0
fail_count = 0


def ok(label):
    global pass_count
    pass_count += 1
    print(f"  ok   {label}")


def bad(label, detail=""):
    global fail_count
    fail_count += 1
    print(f"  FAIL {label}")
    if detail:
        print(f"       {detail}")


def run_guard(command, cwd, env=None):
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})
    full_env = dict(os.environ)
    # Guard-affecting vars must not leak in from the environment running this suite.
    for var in ("OG_BRANCH_GUARD_OFF", "OG_ALLOW_MERGE", "OG_PROTECTED_BRANCHES"):
        full_env.pop(var, None)
    if env:
        full_env.update(env)
    result = subprocess.run(
        [sys.executable, GUARD],
        input=payload,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=full_env,
        timeout=10,
    )
    return result.returncode, result.stderr


def assert_verdict(label, command, cwd, expect_block, env=None):
    rc, stderr = run_guard(command, cwd, env)
    blocked = rc == 2
    want = "block" if expect_block else "allow"
    got = "block" if blocked else "allow"
    if blocked == expect_block:
        ok(f"{label} -> {want}")
    else:
        bad(f"{label}: expected {want}, got {got}", stderr.strip())


def git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def build_fixtures(tmp):
    """A main checkout on 'main' with a protected-branch worktree ('develop')
    and a feature-branch worktree ('feature/x'), plus a file literally named
    'og-push' so read-only commands have a realistic push-shaped path to cite."""
    main_repo = os.path.join(tmp, "main_repo")
    os.makedirs(main_repo)
    git("init", "-q", "-b", "main", cwd=main_repo)
    git("config", "user.email", "t@t", cwd=main_repo)
    git("config", "user.name", "t", cwd=main_repo)
    git("commit", "-q", "--allow-empty", "-m", "init", cwd=main_repo)

    os.makedirs(os.path.join(main_repo, "bin"))
    for verb in ("push", "merge", "reset"):
        with open(os.path.join(main_repo, "bin", f"og-{verb}"), "w") as f:
            f.write(f"#!/bin/sh\necho {verb}\n")
    git("add", "bin", cwd=main_repo)
    git("commit", "-q", "-m", "add bin/og-* helper scripts", cwd=main_repo)

    feature_wt = os.path.join(tmp, "wt_feature")
    git("worktree", "add", "-q", "-b", "feature/x", feature_wt, "main", cwd=main_repo)

    git("branch", "develop", cwd=main_repo)
    develop_wt = os.path.join(tmp, "wt_develop")
    git("worktree", "add", "-q", develop_wt, "develop", cwd=main_repo)

    return main_repo, feature_wt, develop_wt


def run_all(tmp):
    main_repo, feature_wt, develop_wt = build_fixtures(tmp)

    # --- Evidence table: all nine rows ---
    assert_verdict("show a file named og-push", "git show HEAD:bin/og-push", main_repo, False)
    assert_verdict("log of a file named og-push", "git log --oneline -- bin/og-push", main_repo, False)
    assert_verdict("diff of a file named og-push", "git diff HEAD -- bin/og-push", main_repo, False)
    assert_verdict("control: real push to protected branch", "git push origin main", main_repo, True)
    assert_verdict("worktree push via cd (feature branch)", f"cd {feature_wt} && git push", main_repo, False)
    assert_verdict("worktree push via -C (workaround)", f"git -C {feature_wt} push", main_repo, False)
    assert_verdict("gh pr merge --admin --squash", "gh pr merge 19 --admin --squash", main_repo, True)
    assert_verdict("gh api REST merge endpoint", "gh api -X PUT repos/o/r/pulls/19/merge", main_repo, True)
    assert_verdict("gh pr merge --auto (enabling auto-merge)", "gh pr merge 19 --auto", main_repo, True)

    # --- Read-only subcommands must never trip on a path merely NAMED after a verb ---
    for verb in ("push", "merge", "reset"):
        path = f"bin/og-{verb}"
        for sub, cmd in [
            ("show", f"git show HEAD:{path}"),
            ("log", f"git log --oneline -- {path}"),
            ("diff", f"git diff HEAD -- {path}"),
            ("cat-file", f"git cat-file -p HEAD:{path}"),
            ("ls-tree", f"git ls-tree HEAD -- {path}"),
            ("rev-parse", f"git rev-parse HEAD:{path}"),
        ]:
            assert_verdict(f"read-only 'git {sub}' naming a {verb}-shaped path", cmd, main_repo, False)

    # --- Bare `git push` depends on the CURRENT branch ---
    assert_verdict("bare 'git push' on protected branch (main)", "git push", main_repo, True)
    assert_verdict("bare 'git push' on a feature branch", "git push", feature_wt, False)

    # --- Explicit force-push forms to a protected branch ---
    assert_verdict("git push --force origin main", "git push --force origin main", main_repo, True)
    assert_verdict("git push -f origin main (short form)", "git push -f origin main", main_repo, True)

    # --- Worktree resolution via a leading `cd ... &&` ---
    assert_verdict("cd feature worktree && git push", f"cd {feature_wt} && git push", main_repo, False)
    assert_verdict("cd develop (protected) worktree && git push", f"cd {develop_wt} && git push", main_repo, True)

    # --- `git merge` is ordinary local work, never a PR merge ---
    assert_verdict("git merge --ff-only origin/main (not a PR merge)", "git merge --ff-only origin/main", main_repo, False)
    assert_verdict("git merge --abort (not a PR merge)", "git merge --abort", main_repo, False)

    # --- Every OG-0 merge vector: blocked by default, allowed under OG_ALLOW_MERGE ---
    merge_vectors = [
        ("gh pr merge --admin --squash", "gh pr merge 19 --admin --squash"),
        ("gh pr merge --rebase", "gh pr merge 19 --rebase"),
        ("gh pr merge --merge", "gh pr merge 19 --merge"),
        ("gh pr merge --auto (enable auto-merge)", "gh pr merge 19 --auto"),
        ("gh api REST merge endpoint (-X PUT)", "gh api -X PUT repos/o/r/pulls/19/merge"),
        ("gh api REST merge endpoint (--method PUT)", "gh api --method PUT repos/o/r/pulls/19/merge"),
    ]
    for label, cmd in merge_vectors:
        assert_verdict(f"{label}", cmd, main_repo, True)
        assert_verdict(f"{label} [OG_ALLOW_MERGE=1]", cmd, main_repo, False, env={"OG_ALLOW_MERGE": "1"})

    # --- OG_BRANCH_GUARD_OFF disables everything, including the merge rules ---
    assert_verdict(
        "OG_BRANCH_GUARD_OFF=1 disables the push block",
        "git push origin main", main_repo, False, env={"OG_BRANCH_GUARD_OFF": "1"},
    )
    assert_verdict(
        "OG_BRANCH_GUARD_OFF=1 disables the merge block",
        "gh pr merge 19 --admin", main_repo, False, env={"OG_BRANCH_GUARD_OFF": "1"},
    )


def main():
    tmp = tempfile.mkdtemp(prefix="og-branch-guard-test-")
    try:
        run_all(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    print(f"pass={pass_count} fail={fail_count}")
    sys.exit(0 if fail_count == 0 else 1)


if __name__ == "__main__":
    main()
