"""Focused checks for reproducible generation and explicit policy refresh."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class SyncAgentsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix=".agent-sync-test-", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/sync-agents-md.py", self.repo / "scripts")
        shutil.copytree(ROOT / "agent-instructions", self.repo / "agent-instructions")
        shutil.copy(ROOT / "CLAUDE.md", self.repo)
        shutil.copy(ROOT / "AGENTS.md", self.repo)

    def run_sync(self, *args, host=None):
        env = os.environ.copy()
        if host is not None:
            env["HOME"] = str(host)
        return subprocess.run(
            [sys.executable, str(self.repo / "scripts/sync-agents-md.py"), *args],
            cwd=self.base, env=env, text=True, capture_output=True, check=False,
        )

    def test_different_host_versions_and_absent_installation_are_identical(self):
        expected = (self.repo / "AGENTS.md").read_text(encoding="utf-8")
        for version in ("retired audit-review fast path", "different current policy", None):
            host = self.base / f"host-{version}"
            if version is not None:
                includes = host / ".claude/includes"
                includes.mkdir(parents=True)
                for path in (self.repo / "agent-instructions/includes").glob("*.md"):
                    (includes / path.name).write_text(version)
            result = self.run_sync("--dry-run", host=host)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
            self.assertEqual(self.run_sync("--check", host=host).returncode, 0)

    def test_stale_and_missing_generated_content_fail_without_writing(self):
        target = self.repo / "AGENTS.md"
        target.write_text("stale policy\n")
        self.assertEqual(self.run_sync("--check").returncode, 1)
        self.assertEqual(target.read_text(encoding="utf-8"), "stale policy\n")
        target.unlink()
        self.assertEqual(self.run_sync("--check").returncode, 1)
        self.assertFalse(target.exists())
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.run_sync("--check").returncode, 0)

    def test_transitive_input_drift_is_detected(self):
        includes = self.repo / "agent-instructions/includes"
        with (includes / "critical-rules.md").open("a") as file:
            file.write("\n@agent-instructions/includes/nested.md\n")
        nested = includes / "nested.md"
        nested.write_text("nested policy\n")
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.run_sync("--check").returncode, 0)
        nested.write_text("changed policy\n")
        self.assertEqual(self.run_sync("--check").returncode, 1)

    def test_explicit_refresh_updates_snapshots_and_output(self):
        source = self.base / "reviewed"
        shutil.copytree(self.repo / "agent-instructions/includes", source)
        policy = source / "verification-policy.md"
        policy.write_text(policy.read_text(encoding="utf-8") + "\nReviewed policy addition.\n")
        result = self.run_sync("--refresh-includes", str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.repo / "agent-instructions/includes/verification-policy.md").read_bytes(),
            policy.read_bytes(),
        )
        self.assertIn("Reviewed policy addition.", (self.repo / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertEqual(self.run_sync("--check").returncode, 0)

    def test_invalid_refresh_leaves_all_files_unchanged(self):
        pinned = self.repo / "agent-instructions/includes"
        before = {path: path.read_bytes() for path in pinned.glob("*.md")}
        target = self.repo / "AGENTS.md"
        before[target] = target.read_bytes()
        source = self.base / "invalid"
        shutil.copytree(pinned, source)
        (source / "agent-economy.md").write_text("candidate change\n")
        for invalid in ("@~/.claude/includes/old.md\n", "@agent-instructions/includes/critical-rules.md\n"):
            (source / "critical-rules.md").write_text(invalid)
            self.assertEqual(self.run_sync("--refresh-includes", str(source)).returncode, 1)
            self.assertEqual({path: path.read_bytes() for path in before}, before)
        (source / "critical-rules.md").unlink()
        self.assertEqual(self.run_sync("--refresh-includes", str(source)).returncode, 1)
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_external_import_cannot_use_host_or_parent_files(self):
        outside = self.base / "outside.md"
        outside.write_text("external policy\n")
        for name in (str(outside), "../outside.md", "~/.claude/includes/old.md"):
            (self.repo / "CLAUDE.md").write_text(f"@{name}\n")
            result = self.run_sync()
            self.assertEqual(result.returncode, 1, result.stdout)


if __name__ == "__main__":
    unittest.main()
