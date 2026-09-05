from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest

from script.verify_public_privacy import check_commits, check_tree, content_issues, safe_commit_email


class PublicPrivacyTests(unittest.TestCase):
    def test_private_values_are_detected_without_returning_them(self):
        email = "synthetic.person" + "@" + "gmail.com"
        home = "/Users/" + "synthetic-owner/project"
        address = ".".join(["8", "8", "4", "4"])
        key = "-----" + "BEGIN PRIVATE KEY" + "-----"
        text = "\n".join([email, home, address, key])
        issues = content_issues("docs/report.md", text)
        self.assertEqual({kind for _, kind in issues}, {
            "personal email", "personal home path", "public IP in documentation", "private-key header"
        })
        rendered = str(issues)
        for secret in (email, home, address, key):
            self.assertNotIn(secret, rendered)

    def test_documentation_examples_and_product_links_remain_usable(self):
        text = "\n".join([
            "/Users/example/TokenFleet", "/home/runner/work/project",
            "admin@example.com", "maintainer@users.noreply.github.com",
            "https://token.ipwriter.com/install", "https://u.wechat.com/example",
            "127.0.0.1", "192.0.2.10", "198.51.100.10", "203.0.113.10", "172.30.50.1",
        ])
        self.assertEqual(content_issues("README.md", text), [])

    def test_new_commits_are_checked_without_rejecting_existing_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def run(*args, env=None):
                return subprocess.check_output(["git", "-C", str(root), *args], env=env).decode().strip()
            run("init", "-q")
            run("config", "user.name", "Fixture")
            private_email = "old.person" + "@" + "gmail.com"
            run("config", "user.email", private_email)
            (root / "README.md").write_text("Public example\n")
            run("add", "README.md")
            run("commit", "-qm", "Existing history")
            base = run("rev-parse", "HEAD")
            run("config", "user.email", "fixture@users.noreply.github.com")
            run("commit", "--allow-empty", "-qm", "Safe new commit")
            self.assertEqual(check_commits(root, base), [])
            run("config", "user.email", private_email)
            run("commit", "--allow-empty", "-qm", "Unsafe new commit")
            errors = check_commits(root, base)
            self.assertEqual(len(errors), 2)
            self.assertNotIn(private_email, str(errors))
            self.assertEqual(check_tree(root), [])

    def test_tree_fails_for_a_tracked_private_document(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "notes.md").write_text("/Users/" + "synthetic-owner/project")
            subprocess.run(["git", "-C", str(root), "add", "notes.md"], check=True)
            self.assertEqual(check_tree(root), ["notes.md:1: personal home path"])

    def test_commit_email_policy_and_invalid_base_fail_closed(self):
        self.assertTrue(safe_commit_email("123+maintainer@users.noreply.github.com"))
        self.assertTrue(safe_commit_email("noreply@github.com"))
        self.assertFalse(safe_commit_email("maintainer@company.invalid.evil"))
        self.assertFalse(safe_commit_email("not-an-email"))
        with self.assertRaises(ValueError):
            check_commits(Path("."), "--all")
        with self.assertRaises(ValueError):
            check_commits(Path("."), "0" * 40)


if __name__ == "__main__":
    unittest.main()
