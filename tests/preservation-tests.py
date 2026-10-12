"""Run the production preservation guard against disposable, real Git repos.

Linux/Bash test suite; standard library only. Never invokes sbx or the network.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


GUARD = Path(__file__).resolve().parents[1] / "scripts/private/preservation-guard.sh"


class PreservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ocbox-preservation-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")
        self.repo = self.init_repo("repo")

    def git(self, repo, *args):
        return subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@localhost",
             "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", *args],
            cwd=repo, env=self.env, text=True, capture_output=True, check=True,
        ).stdout.strip()

    def init_repo(self, name):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q")
        (repo / "baseline.txt").write_text("baseline\n")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-qm", "baseline")
        return repo

    def guard(self, expected, marker=None, env=None):
        result = subprocess.run([shutil.which("bash"), str(GUARD)], cwd=self.repo,
                                env=env or self.env, text=True, capture_output=True)
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        if marker:
            self.assertIn(marker, result.stdout)

    def restricted_path(self):
        # Prove attribute/pointer detection works without a git-lfs executable.
        bindir = self.root / "bin"
        bindir.mkdir()
        for name in ("git", "mktemp", "rm", "grep"):
            (bindir / name).symlink_to(shutil.which(name))
        return bindir, dict(self.env, PATH=str(bindir))

    def test_plain_repo_allows_snapshot(self):
        (self.repo / "baseline.txt").write_text("changed\n")
        (self.repo / "new file.txt").write_text("untracked work\n")
        self.guard(0)

    def test_plain_repo_without_lfs_client(self):
        _, env = self.restricted_path()
        self.guard(0, env=env)

    def test_ignored_output_preserves_vm(self):
        (self.repo / ".gitignore").write_text("cache/\n")
        (self.repo / "cache").mkdir()
        (self.repo / "cache/valuable.txt").write_text("output\n")
        self.guard(42, "OCBOX_IGNOREDFILES")

    def test_secondary_worktree_preserves_vm(self):
        self.git(self.repo, "worktree", "add", "-qb", "extra", str(self.root / "extra"))
        self.guard(43, "OCBOX_MULTIPLE_WORKTREES")

    def test_clean_submodule_with_local_commit_preserves_vm(self):
        child = self.init_repo("child")
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "add",
                 "-q", str(child), "module")
        module = self.repo / "module"
        (module / "local-only.txt").write_text("valuable local-only output\n")
        self.git(module, "add", ".")
        self.git(module, "commit", "-qm", "local output")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-qm", "record nested output")
        self.assertEqual("", self.git(self.repo, "status", "--porcelain"))
        self.guard(45, "OCBOX_SUBMODULE_UNSUPPORTED")

    def test_gitlink_without_gitmodules_preserves_vm(self):
        sha = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "update-index", "--add", "--cacheinfo", f"160000,{sha},module")
        self.guard(45, "OCBOX_SUBMODULE_UNSUPPORTED")

    def test_lfs_attributes_without_client_preserve_vm(self):
        (self.repo / ".gitattributes").write_text("*.bin filter=lfs\n")
        (self.repo / "asset with spaces.bin").write_bytes(b"valuable data")
        _, env = self.restricted_path()
        self.guard(44, "OCBOX_GIT_LFS_TRACKED", env=env)

    def test_indexed_pointer_without_attributes_preserves_vm(self):
        (self.repo / "asset").write_text("version https://git-lfs.github.com/spec/v1\n"
                                         + "oid sha256:" + "a" * 64 + "\nsize 42\n")
        self.git(self.repo, "add", "asset")
        _, env = self.restricted_path()
        self.guard(44, "OCBOX_GIT_LFS_TRACKED", env=env)

    def test_lfs_inspection_error_preserves_vm(self):
        bindir, env = self.restricted_path()
        client = bindir / "git-lfs"
        client.write_text("#!/bin/sh\nexit 2\n")
        client.chmod(0o700)
        self.guard(46, "OCBOX_LFS_INSPECTION_FAILED", env=env)

    def test_untracked_pointer_without_attributes_preserves_vm(self):
        (self.repo / "asset").write_text("version https://git-lfs.github.com/spec/v1\n"
                                         + "oid sha256:" + "a" * 64 + "\nsize 42\n")
        _, env = self.restricted_path()
        self.guard(44, "OCBOX_GIT_LFS_TRACKED", env=env)

    def test_git_enumeration_error_preserves_vm(self):
        bindir, env = self.restricted_path()
        (bindir / "real-git").symlink_to(shutil.which("git"))
        (bindir / "git").unlink()
        wrapper = bindir / "git"
        wrapper.write_text('#!/bin/sh\nif [ "$1" = ls-files ]; then exit 71; fi\nexec real-git "$@"\n')
        wrapper.chmod(0o700)
        self.guard(71, env=env)


if __name__ == "__main__":
    unittest.main(verbosity=2)
