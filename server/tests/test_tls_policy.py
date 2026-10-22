import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

POLICY_PATH = Path(__file__).resolve().parents[1] / "app" / "tls_policy.py"
POLICY = runpy.run_path(str(POLICY_PATH))
FIXTURE = Path(__file__).parent / "fixtures/tls-source.txt"

class TLSPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.pem"
        self.source.write_bytes(FIXTURE.read_bytes())
        self.output = self.root / "policy"

    def test_keeps_other_roots_and_removes_both_incident_roots(self):
        original = POLICY["roots"](self.source.read_bytes())
        self.assertEqual(len(set(original) & POLICY["DENIED"]), 2)
        POLICY["prepare"](self.source, self.output)
        actual = POLICY["roots"]((self.output / "ca-bundle.pem").read_bytes())
        self.assertEqual(actual, {h:b for h,b in original.items() if h not in POLICY["DENIED"]})

    def test_repeated_and_concurrent_preparation_is_consistent(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            rows = list(pool.map(lambda _: POLICY["prepare"](self.source, self.output), range(8)))
        self.assertTrue(all(row == rows[0] for row in rows))
        bundle = self.output / "ca-bundle.pem"
        before = bundle.stat().st_mtime_ns
        POLICY["prepare"](self.source, self.output)
        self.assertEqual(bundle.stat().st_mtime_ns, before)

    def test_check_rejects_reintroduced_root(self):
        POLICY["prepare"](self.source, self.output)
        (self.output / "ca-bundle.pem").write_bytes(self.source.read_bytes())
        with self.assertRaises(ValueError): POLICY["check"](self.output)

    def test_check_rejects_manifest_change(self):
        POLICY["prepare"](self.source, self.output)
        (self.output / "manifest.json").write_text('{"schema":1,"sha256":"wrong"}')
        with self.assertRaises(ValueError): POLICY["check"](self.output)

    def test_legacy_certificate_directory_cannot_be_reused(self):
        POLICY["prepare"](self.source, self.output)
        (self.output / "empty-ca-dir/legacy.pem").write_bytes(self.source.read_bytes())
        with self.assertRaises(ValueError): POLICY["prepare"](self.source, self.output)

    def test_refuses_symlink_output_without_overwriting_target(self):
        victim = self.root / "victim"; victim.mkdir()
        self.output.symlink_to(victim, target_is_directory=True)
        with self.assertRaises(ValueError): POLICY["prepare"](self.source, self.output)
        self.assertEqual(list(victim.iterdir()), [])

    def test_run_replaces_all_three_inherited_ca_variables(self):
        keys = ["SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"]
        env = dict(os.environ, **{key:"old-ca-location" for key in keys})
        code = "import os,json; print(json.dumps({k:os.environ[k] for k in " + repr(keys) + "}))"
        result = subprocess.run([sys.executable, str(POLICY_PATH), "run", "--source", str(self.source),
                                 "--output", str(self.output), "--", sys.executable, "-c", code],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), POLICY["check"](self.output))

    def test_refuses_output_as_its_own_refresh_source(self):
        POLICY["prepare"](self.source, self.output)
        with self.assertRaises(ValueError): POLICY["prepare"](self.output / "ca-bundle.pem", self.output)

    def test_rejects_writable_output_and_parent(self):
        self.output.mkdir(mode=0o700)
        self.output.chmod(0o777)
        with self.assertRaises(ValueError): POLICY["prepare"](self.source, self.output)
        self.output.chmod(0o700)
        self.root.chmod(0o777)
        try:
            with self.assertRaises(ValueError): POLICY["prepare"](self.source, self.output)
        finally:
            self.root.chmod(0o700)

    def test_check_rejects_permissions_changed_after_prepare(self):
        POLICY["prepare"](self.source, self.output)
        self.output.chmod(0o777)
        with self.assertRaises(ValueError): POLICY["check"](self.output)

    def test_new_output_is_private(self):
        POLICY["prepare"](self.source, self.output)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.output.stat().st_uid, os.geteuid())

    def test_creates_missing_protected_state_parents(self):
        output = self.root / "state" / "application" / "tls-policy"
        POLICY["prepare"](self.source, output)
        self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(output.parent.parent.stat().st_mode & 0o777, 0o700)
        POLICY["check"](output)

    def test_shared_sticky_parent_is_rejected_even_if_root_owned(self):
        # On Linux /tmp is normally root-owned sticky; on macOS it resolves
        # through a root-owned sticky ancestor. Neither is a durable state root.
        with tempfile.TemporaryDirectory(dir="/tmp") as shared:
            with self.assertRaises(ValueError):
                POLICY["prepare"](self.source, Path(shared) / "policy")

    def test_relative_output_is_rejected(self):
        with self.assertRaises(ValueError):
            POLICY["prepare"](self.source, Path("relative-policy"))

    def test_check_rejects_writable_bundle_manifest_and_empty_directory(self):
        POLICY["prepare"](self.source, self.output)
        for name in ("ca-bundle.pem", "manifest.json", "empty-ca-dir"):
            with self.subTest(name=name):
                entry = self.output / name
                original = entry.stat().st_mode & 0o777
                entry.chmod(original | 0o022)
                try:
                    with self.assertRaises(ValueError): POLICY["check"](self.output)
                finally:
                    entry.chmod(original)

    def test_check_rejects_symlinked_manifest(self):
        POLICY["prepare"](self.source, self.output)
        manifest = self.output / "manifest.json"
        saved = self.root / "saved-manifest.json"
        manifest.rename(saved)
        manifest.symlink_to(saved)
        with self.assertRaises(ValueError): POLICY["check"](self.output)

    def test_lock_with_shared_write_access_is_rejected(self):
        POLICY["prepare"](self.source, self.output)
        (self.output / ".lock").chmod(0o666)
        with self.assertRaises(ValueError): POLICY["prepare"](self.source, self.output)

    def test_bootstrap_reuses_persistent_home_state_across_processes(self):
        env = {k:v for k,v in os.environ.items() if k not in {"TOKENFLEET_TLS_OUTPUT", "XDG_STATE_HOME"}}
        env.update(HOME=str(self.root), TOKENFLEET_TLS_SOURCE=str(self.source), PYTHONDONTWRITEBYTECODE="1")
        code = "from app.tls_bootstrap import initialize_tls_policy; initialize_tls_policy(); import os; print(os.environ['SSL_CERT_FILE'])"
        outputs = []
        for _ in range(2):
            result = subprocess.run([sys.executable, "-c", code], env=env,
                                    cwd=POLICY_PATH.parents[1], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            outputs.append(result.stdout.strip())
        expected = self.root / ".local/state/tokenfleet/tls-policy/ca-bundle.pem"
        self.assertEqual(outputs, [str(expected), str(expected)])
        POLICY["check"](expected.parent)

    def test_bootstrap_rejects_shared_or_relative_state_location(self):
        for state in ("relative-state", "/tmp"):
            with self.subTest(state=state):
                env = {k:v for k,v in os.environ.items() if k != "TOKENFLEET_TLS_OUTPUT"}
                env.update(HOME=str(self.root), TOKENFLEET_TLS_SOURCE=str(self.source), XDG_STATE_HOME=state)
                result = subprocess.run([sys.executable, "-B", "-c",
                                         "from app.tls_bootstrap import initialize_tls_policy; initialize_tls_policy()"],
                                        env=env, cwd=POLICY_PATH.parents[1], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("ValueError", result.stderr)

if __name__ == "__main__": unittest.main()
