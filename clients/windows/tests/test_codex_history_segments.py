from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tokenfleet.collectors import CollectionDiagnostics, _collect_codex, _aggregate, collect_usage
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
        self.assertEqual(sum(r.counts.total for r in records), 208)
        compressed.write_bytes(b'bad frame')
        self.assertIsNone(prefix_usage(history_position(base), [compressed]))

    def test_bad_ancestor_counter_blocks_all_codex_buckets(self):
        for raw in ({}, dict(counts(100), input_tokens='100'), dict(counts(100), cached_input_tokens=-1)):
            old, base = self.write(ROOT, [dict(event(100), payload={'type':'token_count','info':{'total_token_usage':raw}})])
            new, _ = self.write(NEXT, [event(105)], base)
            other, _ = self.write(THIRD, [event(15, '2026-11-16')], owner=THIRD)
            buckets, diag = self.collect([old, new, other])
            self.assertEqual(buckets, [])
            self.assertEqual(diag.source_status['Codex'], 'incomplete_history_base')

    def test_compressed_recursive_ancestors_and_truncated_tail_are_not_partial(self):
        import zstandard
        old, base = self.write(ROOT, [event(100)])
        second, base2 = self.write(NEXT, [event(105)], base)
        third, _ = self.write(THIRD, [event(108)], base2)
        compressed = []
        for p in (old, second):
            out=p.with_suffix('.jsonl.zst');out.write_bytes(zstandard.ZstdCompressor(write_checksum=True).compress(p.read_bytes()))
            compressed.append(out);p.unlink()
        diag=CollectionDiagnostics()
        records, incomplete=_collect_codex([third], diag, history_paths=[third,*compressed])
        self.assertEqual(sum(r.counts.total for r in records),108)
        self.assertFalse(incomplete)
        compressed[0].write_bytes(compressed[0].read_bytes()[:-1])
        diag=CollectionDiagnostics()
        records, incomplete=_collect_codex([third], diag, history_paths=[third,*compressed])
        self.assertEqual(_aggregate(records, excluded_keys=set(diag.blocked_history_buckets)),[])


    def test_large_nonaccounting_compression_record_preserves_real_usage(self):
        import zstandard
        old, base = self.write(ROOT, [{'type':'compacted','payload':{'replacement_history':'x'*2_200_000}}, event(100)])
        new, _ = self.write(NEXT, [event(108)], base)
        compressed=old.with_suffix('.jsonl.zst')
        compressed.write_bytes(zstandard.ZstdCompressor().compress(old.read_bytes()));old.unlink()
        diag=CollectionDiagnostics()
        records, incomplete=_collect_codex([new], diag, history_paths=[new,compressed])
        self.assertFalse(incomplete)
        self.assertEqual(sum(r.counts.total for r in records),108)


    def test_bad_compressed_paid_tail_blocks_all_uploads_but_notifications_do_not(self):
        import zstandard
        old, base = self.write(ROOT, [event(100)])
        new, _ = self.write(NEXT, [event(108)], base)
        compressed=old.with_suffix('.jsonl.zst')
        original=old.read_bytes()
        for tail, valid in [
            ({'type':'event_msg','payload':{'type':'token_count','info':None}}, True),
            (dict(event(200),payload={'type':'token_count','info':{'total_token_usage':dict(counts(100), total_tokens=200)}}),False),
        ]:
            payload=original+(json.dumps(dict(tail,ordinal=base['end_ordinal_exclusive']))+'\n').encode()
            compressed.write_bytes(zstandard.ZstdCompressor().compress(payload))
            if old.exists(): old.unlink()
            diag=CollectionDiagnostics();records,_=_collect_codex([new],diag,history_paths=[new,compressed])
            buckets=_aggregate(records,excluded_keys=set(diag.blocked_history_buckets))
            self.assertEqual(bool(buckets),valid)


    def test_context_sentinel_and_zero_notification_survive_compressed_history(self):
        import zstandard
        sentinel=event(0)
        sentinel['payload']['info'].update(total_token_usage=dict(counts(0),total_tokens=64),last_token_usage=counts(0),model_context_window=64)
        old,base=self.write(ROOT,[event(100),event(0),sentinel])
        with old.open('a') as f: f.write(json.dumps(dict(event(200),ordinal=base['end_ordinal_exclusive']))+'\n')
        child,_=self.write(NEXT,[event(108)],base)
        compressed=old.with_suffix('.jsonl.zst');compressed.write_bytes(zstandard.ZstdCompressor().compress(old.read_bytes()));old.unlink()
        self.assertEqual(prefix_usage(history_position(base),[compressed]),counts(100))
        diag=CollectionDiagnostics();records,incomplete=_collect_codex([child],diag,history_paths=[child,compressed])
        self.assertFalse(incomplete)
        self.assertEqual(sum(r.counts.total for r in records),208)

    def test_archives_are_only_counted_when_referenced(self):
        import zstandard
        sessions = self.root / '.codex' / 'sessions'
        archives = self.root / '.codex' / 'archived_sessions'
        sessions.mkdir(parents=True); archives.mkdir(parents=True)
        old, base = self.write(ROOT, [event(100)])
        child, _ = self.write(NEXT, [event(108)], base)
        unrelated, _ = self.write(THIRD, [event(9999)], owner=THIRD)
        archived = archives / old.name
        old.rename(archived); child.rename(sessions / child.name)
        unrelated.rename(archives / unrelated.name)
        for compressed in (False, True):
            if compressed:
                archived.with_suffix('.jsonl.zst').write_bytes(zstandard.ZstdCompressor().compress(archived.read_bytes()))
                archived.unlink()
            result = collect_usage(self.root, history_days=1830)
            self.assertEqual(sum(b['input_tokens'] + b['cache_read_tokens'] for b in result.buckets), 108)
            self.assertEqual(result.diagnostics.source_files['Codex'], 2)

    def test_zero_corrections_follow_usage_dates_after_notifications(self):
        old, base = self.write(ROOT, [event(100, '2026-11-15')])
        notification = {'type':'event_msg','timestamp':'2026-11-16T12:00:00Z',
                        'payload':{'type':'token_count','info':{'model_context_window':64}}}
        child, _ = self.write(NEXT, [notification, event(100), event(100, '2026-11-18')], base)
        buckets, _ = self.collect([old, child])
        self.assertEqual({b['date']:b['input_tokens'] + b['cache_read_tokens'] for b in buckets},
                         {'2026-11-15':100, '2026-11-17':0})

    def test_later_duplicates_do_not_create_zero_overwrites(self):
        old, base = self.write(ROOT, [event(100, '2026-11-15')])
        child, _ = self.write(NEXT, [event(108, '2026-11-16'), event(108)], base)
        buckets, _ = self.collect([old, child])
        self.assertEqual({b['date']:b['input_tokens'] + b['cache_read_tokens'] for b in buckets},
                         {'2026-11-15':100, '2026-11-16':8})

    def test_zero_requires_equal_components_and_ignores_initial_zero_notifications(self):
        old, base = self.write(ROOT, [event(100, '2026-11-15')])
        changed = event(100)
        changed['payload']['info']['total_token_usage']['cached_input_tokens'] = 49
        child, _ = self.write(NEXT, [changed, event(100, '2026-11-18')], base)
        self.assertEqual([b['date'] for b in self.collect([old, child])[0]], ['2026-11-15'])
        child, _ = self.write(NEXT, [event(0, '2026-11-16'), event(100)], base)
        self.assertEqual({b['date']:b['input_tokens'] + b['cache_read_tokens'] for b in self.collect([old, child])[0]},
                         {'2026-11-15':100, '2026-11-17':0})

    def test_null_root_and_multiframe_prefix(self):
        import zstandard
        old, _ = self.write(ROOT, [])
        rows = [json.loads(line) for line in old.read_text().splitlines()]
        rows[0]['payload']['history_base'] = None
        raw = ''.join(json.dumps(row) + '\n' for row in rows).encode()
        old.write_bytes(raw)
        base = {'thread_id':ROOT, 'end_ordinal_exclusive':len(rows), 'end_byte_offset':len(raw)}
        self.assertEqual(prefix_usage(history_position(base), [old])['total_tokens'], 0)
        split = raw.index(b'\n') + 1
        compressed = old.with_suffix('.jsonl.zst')
        compressed.write_bytes(zstandard.ZstdCompressor().compress(raw[:split]) + zstandard.ZstdCompressor().compress(raw[split:]))
        old.unlink()
        self.assertEqual(prefix_usage(history_position(base), [compressed])['total_tokens'], 0)

    def test_large_nonaccounting_event_and_last_null_do_not_quarantine(self):
        import zstandard
        old, base = self.write(ROOT, [
            {'type':'event_msg','payload':{'type':'exec_command_end','aggregated_output':'x'*2_200_000}},
            event(100), {'type':'event_msg','payload':{'type':'token_count','info':{'last_token_usage':None}}}])
        child, _ = self.write(NEXT, [event(108)], base)
        compressed = old.with_suffix('.jsonl.zst')
        compressed.write_bytes(zstandard.ZstdCompressor().compress(old.read_bytes())); old.unlink()
        diag = CollectionDiagnostics()
        records, incomplete = _collect_codex([child], diag, history_paths=[child, compressed])
        self.assertFalse(incomplete)
        self.assertEqual(sum(r.counts.total for r in records), 108)


if __name__ == '__main__':
    unittest.main()
