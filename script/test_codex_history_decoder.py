"""Exercise the bundled decoder's exact buffer boundaries without dependencies."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

DECODER = sys.argv.pop(1)


def frame(size):
    # Valid Zstandard frame: RLE x's followed by a final raw newline block.
    result = bytearray(b'\x28\xb5\x2f\xfd\xa0' + size.to_bytes(4, 'little'))
    remaining = size - 1
    while remaining:
        count = min(remaining, 128 * 1024)
        result += ((count << 3) | 2).to_bytes(3, 'little') + b'x'
        remaining -= count
    return bytes(result + b'\x09\x00\x00\n')


class DecoderBoundaries(unittest.TestCase):
    def test_complete_and_truncated_frames_at_output_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'history.jsonl.zst'
            for size in (65535, 65536, 65537, 131072, 131073):
                with self.subTest(size=size):
                    compressed = frame(size)
                    expected = b'x' * (size - 1) + b'\n'
                    path.write_bytes(compressed)
                    for mode in ('--stream', str(size)):
                        result = subprocess.run([DECODER, str(path), mode], capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, expected)
                    path.write_bytes(compressed[:-1])
                    result = subprocess.run([DECODER, str(path), '--stream'], capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)

    def test_multiple_frames_at_output_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'history.jsonl.zst'
            path.write_bytes(frame(65536) + frame(131072))
            result = subprocess.run([DECODER, str(path), '--stream'], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'x' * 65535 + b'\n' + b'x' * 131071 + b'\n')


if __name__ == '__main__':
    unittest.main()
