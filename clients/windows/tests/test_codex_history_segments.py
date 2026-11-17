from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tokenfleet.collectors import CollectionDiagnostics, _collect_codex, _aggregate
from tokenfleet.codex_history import history_position, prefix_usage

ROOT = '00000000-0000-4000-8000-000000000001'
NEXT = '00000000-0000-4000-8000-000000000002'
THIRD = '00000000-0000-4000-8000-000000000003'


def counts(n):
    return {'input_tokens': n, 'output_tokens': 0, 'cached_input_tokens': n // 2, 'total_tokens': n}


def event(n, day='2026-11-17'):
    return {'type': 'event_msg', 'timestamp': day + 'T12:00:00Z',
            'payload': {'type': 'token_count', 'info': {'total_token_usage': counts(n)}}}


class CodexHistorySegmentsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def write(self, physical, events, base=None, owner=ROOT):
        suffix = owner if physical == owner else owner + '_' + physical
        path = self.root / ('rollout-2026-11-17T00-00-00-' + suffix + '.jsonl')
        payload = {'id': owner, 'history_mode': 'paginated', 'cli_version': '0.169.0-alpha.11.1'}
        if base is not None:
            payload['history_base'] = base
        items = [{'type': 'session_meta', 'payload': payload},
                 {'type': 'turn_context', 'payload': {'model': 'gpt-6-sol'}}, *events]
        start = base['end_ordinal_exclusive'] if base else 0
        lines = [json.dumps(dict(item, ordinal=start+i)) + '\n' for i, item in enumerate(items)]
        path.write_text(''.join(lines))
        return path, {'thread_id': physical, 'end_ordinal_exclusive': start+len(items),
                      'end_byte_offset': path.stat().st_size}

    def collect(self, paths):
        diag = CollectionDiagnostics()
        records, incomplete = _collect_codex(paths, diag)
        return _aggregate(records, excluded_keys=set(diag.blocked_history_buckets)), diag

    def total(self, paths):
        buckets, _ = self.collect(paths)
        return sum(sum(b[k] for k in ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens')) for b in buckets)

    def test_continuation_keeps_old_days_and_counts_only_new_delta(self):
        old, base = self.write(ROOT, [event(100, '2026-11-16')])
        new, _ = self.write(NEXT, [event(105), event(108)], base)
        for paths in ([old,new],[new,old],[old,new,old,new]):
            self.assertEqual(self.total(paths),108)
        buckets, _ = self.collect([old,new])
        self.assertEqual([(b['date'],b['input_tokens']+b['cache_read_tokens']) for b in buckets], [('2026-11-16',100),('2026-11-17',8)])

    def test_branch_uses_exact_prefix_not_later_paid_tail_and_keeps_coinciding_totals(self):
        old, base = self.write(ROOT, [event(100)])
        with old.open('a') as f:
            f.write(json.dumps(dict(event(108), ordinal=base['end_ordinal_exclusive']))+'\n')
        new, base2 = self.write(NEXT, [event(108)], base)
        third, _ = self.write(THIRD, [event(111)], base2)
        self.assertEqual(self.total([third,new,old]),119)

    def test_prefix_containing_only_metadata_recursively_resolves_previous_segment(self):
        old, base = self.write(ROOT,[event(100)])
        new, base2 = self.write(NEXT,[],base)
        third, _ = self.write(THIRD,[event(105)],base2)
        self.assertEqual(self.total([old,new,third]),105)

    def test_zero_correction_survives_for_previously_overcounted_day(self):
        old, base = self.write(ROOT,[event(100,'2026-11-16')])
        new, _ = self.write(NEXT,[event(100)],base)
        buckets, _ = self.collect([old,new])
        today = next(b for b in buckets if b['date']=='2026-11-17')
        self.assertEqual(today['input_tokens']+today['cache_read_tokens'],0)
        self.assertEqual(today['completeness'],'exact')

    def test_missing_truncated_or_inconsistent_base_blocks_partial_day_upload(self):
        old, base = self.write(ROOT,[event(100)])
        for change in ({'end_byte_offset':base['end_byte_offset']-1}, {'end_ordinal_exclusive':99}, {'thread_id':THIRD}, {'end_ordinal_exclusive':True}):
            new, _ = self.write(NEXT,[event(105)],dict(base,**change))
            buckets, diag = self.collect([old,new])
            self.assertEqual(buckets,[])
            self.assertEqual(diag.source_status['Codex'],'incomplete_history_base')

    def test_resolving_missing_ancestor_recovers_without_touching_source(self):
        old, base = self.write(ROOT,[event(100)])
        new, _ = self.write(NEXT,[event(105)],base)
        self.assertEqual(self.collect([new])[0],[])
        self.assertEqual(self.total([old,new]),105)

    def test_cyclic_history_and_invalid_position_are_rejected(self):
        self.assertIsNone(history_position({'thread_id':ROOT,'end_ordinal_exclusive':True,'end_byte_offset':3}))
        self.assertIsNone(prefix_usage((ROOT,1,10),[],frozenset({(ROOT,1,10)})))

    def test_compressed_ancestor_uses_exact_prefix_and_rejects_corruption(self):
        import zstandard
        old, base = self.write(ROOT, [event(100, '2026-11-16')])
        with old.open('a') as f:
            f.write(json.dumps(dict(event(200), ordinal=base['end_ordinal_exclusive']))+'\n')
        new, _ = self.write(NEXT, [event(108)], base)
        compressed = old.with_suffix('.jsonl.zst')
        compressed.write_bytes(zstandard.ZstdCompressor().compress(old.read_bytes()))
        self.assertEqual(prefix_usage(history_position(base), [old, compressed]), counts(100))
        old.unlink()
        diag = CollectionDiagnostics()
        records, incomplete = _collect_codex([new], diag, history_paths=[new, compressed])
        self.assertFalse(incomplete)
        self.assertEqual(sum(r.counts.total for r in records), 8)
        compressed.write_bytes(b'bad frame')
        self.assertIsNone(prefix_usage(history_position(base), [compressed]))


if __name__ == '__main__':
    unittest.main()
