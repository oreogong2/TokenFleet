from __future__ import annotations

from pathlib import Path
import struct
import tempfile
import unittest
from zipfile import ZIP_DEFLATED, ZipFile

from script.private_markers import load_private_markers
from script.verify_public_source_archive import MAX_MEMBER_BYTES, verify_archive


class PublicSourceArchiveVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenfleet-archive-test-")
        self.root = Path(self.temporary.name)
        self.markers_path = self.root / "markers.txt"
        self.markers_path.write_text(
            "maintainer-private@example.invalid\n"
            "/private/example/home\n"
            "203.0.113.254\n",
            encoding="utf-8",
        )
        self.markers_path.chmod(0o600)
        self.markers = load_private_markers(self.markers_path)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _archive(self, name: str, entries: dict[str, bytes]) -> Path:
        path = self.root / name
        with ZipFile(path, "w", compression=ZIP_DEFLATED) as archive:
            for entry_name, payload in entries.items():
                archive.writestr(entry_name, payload)
        return path

    def _assert_rejected(self, archive: Path, expected: str) -> None:
        with self.assertRaises(SystemExit) as captured:
            verify_archive(str(archive), self.markers)
        self.assertIn(expected, str(captured.exception))

    def test_accepts_safe_archive(self) -> None:
        archive = self._archive(
            "safe.zip",
            {"TokenFleet-test/README.md": b"safe public source\n"},
        )
        verify_archive(str(archive), self.markers)

    def test_rejects_path_traversal(self) -> None:
        archive = self._archive(
            "traversal.zip",
            {"TokenFleet-test/../escape.txt": b"unsafe\n"},
        )
        self._assert_rejected(archive, "unsafe path component")

    def test_rejects_non_ascii_filename_without_utf8_flag(self) -> None:
        archive = self._archive(
            "bad-utf8.zip",
            {"TokenFleet-test/说明.md": b"safe\n"},
        )
        payload = bytearray(archive.read_bytes())
        for signature, flag_offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            position = 0
            while True:
                position = payload.find(signature, position)
                if position < 0:
                    break
                flags = struct.unpack_from("<H", payload, position + flag_offset)[0]
                struct.pack_into("<H", payload, position + flag_offset, flags & ~0x800)
                position += 4
        archive.write_bytes(payload)
        self._assert_rejected(archive, "UTF-8 flag")

    def test_rejects_oversized_member(self) -> None:
        archive = self._archive(
            "oversized.zip",
            {"TokenFleet-test/large.bin": b"x" * (MAX_MEMBER_BYTES + 1)},
        )
        self._assert_rejected(archive, "exceeds 25 MiB")

    def test_rejects_injected_private_marker(self) -> None:
        archive = self._archive(
            "private-marker.zip",
            {"TokenFleet-test/README.md": b"prefix " + self.markers[0] + b" suffix"},
        )
        self._assert_rejected(archive, "personal marker")


if __name__ == "__main__":
    unittest.main()
