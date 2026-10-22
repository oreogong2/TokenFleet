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
        self.temp = tempfile.TemporaryDirectory()
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

if __name__ == "__main__": unittest.main()
