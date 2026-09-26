from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tokenfleet.collectors import CollectionDiagnostics, _collect_codex


def stamp(second):
    return f"2026-09-26T10:00:{second:02d}Z"


def meta(name, second, *, fork=None, parent=None, version="0.158.0-alpha.15.1", history_base=None):
    payload = {"id": name, "source": "cli", "cli_version":version}
    if history_base: payload["history_base"] = history_base
    if fork:
        payload["forked_from_id"] = fork
    if parent:
        payload["parent_thread_id"] = parent
    return {"type": "session_meta", "timestamp": stamp(second), "payload": payload}


def context(second):
    return {"type": "turn_context", "timestamp": stamp(second), "payload": {"model": "gpt-6-sol"}}


def boundary(owner, second=25):
    return {"type":"event_msg", "timestamp":stamp(second), "payload":{"type":"thread_settings_applied", "thread_id":owner}}


def event(second, total, last=None, *, cached=0, last_cached=0):
    def counts(value, read):
        return {"input_tokens": value, "cached_input_tokens": read, "output_tokens": 0,
                "reasoning_output_tokens": 0, "total_tokens": value}
    info = {"total_token_usage": counts(total, cached), "model_context_window": 10000}
    if last is not None:
        info["last_token_usage"] = counts(last, last_cached)
    return {"type": "event_msg", "timestamp": stamp(second),
            "payload": {"type": "token_count", "info": info}}


class CodexInheritanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, lines):
        path = self.root / (name + ".jsonl")
        path.write_text("\n".join(json.dumps(line) for line in lines) + "\n")
        return path

    def collect(self, *paths):
        return _collect_codex(list(paths), CollectionDiagnostics())[0]

    def test_copied_snapshot_uses_older_parent_value_and_deducts_once(self):
        parent = self.write("parent", [meta("parent", 0), context(0), event(10, 100, 100), event(19, 120, 20)])
        child = self.write("child", [meta("child", 20, fork="parent"), context(22), boundary("parent", 22), event(23, 100, 100), boundary("child"), event(30, 105, 5)])
        for _ in range(2):
            records = self.collect(child, parent)
            self.assertEqual(sum(r.counts.total for r in records), 125)
            self.assertEqual({(r.day, r.tool, r.model) for r in records}, {("2026-09-26", "Codex", "gpt-6-sol")})
        with child.open("a") as handle:
            handle.write(json.dumps(event(40, 108, 3)) + "\n")
        self.assertEqual(sum(r.counts.total for r in self.collect(parent, child)), 128)

    def test_referenced_explicit_fork_without_prefix_does_not_guess_seed(self):
        child = self.write("child", [meta("child", 20, fork="absent-parent"), context(20), boundary("child"),
                                    event(30, 105, 5), event(40, 108, 3)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)), 108)

    def test_parent_only_fresh_thread_does_not_get_new_baseline(self):
        child = self.write("child", [meta("child", 20, parent="absent-parent"), context(20), event(30, 105, 5)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)), 105)

    def test_paginated_or_empty_seed_explicit_fork_keeps_all_own_usage(self):
        child = self.write("child", [meta("child", 20, fork="absent-parent"), context(20), event(30, 5, 5), event(40, 8, 3)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)), 8)

    def test_first_own_count_coinciding_with_parent_does_not_get_discarded(self):
        for parent_total, own_total, own_last, expected in ((105, 105, 5, 210), (5, 5, 5, 10)):
            parent = self.write("parent", [meta("parent", 0), context(0), event(10, parent_total, parent_total)])
            child = self.write("child", [meta("child", 20, fork="parent"), context(20), boundary("child"), event(30, own_total, own_last)])
            self.assertEqual(sum(r.counts.total for r in self.collect(parent, child)), expected)

    def test_missing_last_or_invalid_component_seed_is_not_guessed(self):
        for first in (event(30, 105), event(30, 105, 5, cached=1, last_cached=2)):
            child = self.write("child", [meta("child", 20, fork="parent"), context(20), first])
            self.assertEqual(sum(r.counts.total for r in self.collect(child)), 105)

    def test_reset_after_inherited_seed_keeps_new_epoch(self):
        child = self.write("child", [meta("child", 20, fork="parent"), context(20), event(21, 100, 100), boundary("child"),
                                    event(30, 105, 5), event(40, 3, 3), event(50, 7, 4)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)), 12)

    def test_forked_from_selects_logical_parent_over_subagent_parent(self):
        parent = self.write("parent", [meta("parent", 0), context(0), event(10, 100, 100), event(19, 120, 20)])
        other = self.write("other", [meta("other", 0), context(0), event(10, 500, 500)])
        child = self.write("child", [meta("child", 20, fork="parent", parent="other"), context(22), event(23, 100, 100), boundary("child"), event(30, 105, 5)])
        self.assertEqual(sum(r.counts.total for r in self.collect(parent, other, child)), 625)

    def test_matching_count_at_different_time_does_not_prove_copy(self):
        parent = self.write("parent", [meta("parent", 0), context(0), event(9, 100, 100), event(19, 120, 20)])
        child = self.write("child", [meta("child", 20, fork="parent"), context(0), event(10, 100, 100), event(30, 105, 5)])
        self.assertEqual(sum(r.counts.total for r in self.collect(parent, child)), 225)

    def test_unknown_model_stays_unknown_without_inheriting_labels(self):
        child = self.write("child", [meta("child", 20, fork="absent-parent"), event(30, 107, 7)])
        records = self.collect(child)
        self.assertEqual(sum(r.counts.total for r in records), 107)
        self.assertEqual({r.model for r in records}, {"unknown"})

    def test_owned_boundary_without_parent_deducts_copied_snapshot_and_skips_echo(self):
        child = self.write("child", [meta("child", 20, fork="absent-parent"), context(22),
            event(23,100,100), boundary("parent",24), boundary("child"),
            event(26,100,100), event(30,105,5), event(40,108,3)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)),8)

    def test_nested_copies_each_deduct_their_own_boundary_seed(self):
        parent=self.write("parent",[meta("parent",0),context(0),event(10,100,100)])
        child=self.write("child",[meta("child",20,fork="parent"),context(22),event(23,100,100),boundary("child"),event(30,125,25)])
        grand=self.write("grand",[meta("grand",40,fork="child"),event(41,125,25),boundary("grand",45),event(50,131,6)])
        self.assertEqual(sum(r.counts.total for r in self.collect(parent,child,grand)),131)
        self.assertEqual({r.model for r in self.collect(grand)}, {"unknown"})

    def test_old_creation_version_resumed_by_new_binary_keeps_old_behavior(self):
        for version in ["0.151.0-alpha.7.2","0.158.0-alpha.15","bad","0.158..0"]:
            child=self.write("child",[meta("child",20,fork="absent-parent",version=version),context(22),event(23,100,100),boundary("child"),event(30,105,5)])
            self.assertEqual(sum(r.counts.total for r in self.collect(child)),105)

    def test_corrupt_or_oversized_prefix_does_not_create_new_deduction(self):
        for bad in ['{"type":"token_count",broken}', '{"type":"token_count","padding":"'+'x'*1100000+'"}']:
            child=self.write("child",[meta("child",20,fork="absent-parent"),context(22),event(23,100,100)])
            with child.open("a") as f:
                f.write(bad+"\n"+json.dumps(boundary("child"))+"\n"+json.dumps(event(30,105,5))+"\n")
            self.assertEqual(sum(r.counts.total for r in self.collect(child)),105)

    def test_referenced_history_base_is_not_a_new_seed_permission(self):
        child=self.write("child",[meta("child",20,fork="absent-parent",history_base={"thread_id":"parent","end_ordinal_exclusive":4,"end_byte_offset":128}),boundary("child"),context(22),event(30,105,5)])
        self.assertEqual(sum(r.counts.total for r in self.collect(child)),105)

    def test_legacy_exact_anchor_without_boundary_remains_unchanged(self):
        parent=self.write("parent",[meta("parent",0),context(0),event(10,5,5)])
        child=self.write("child",[meta("child",20,fork="parent"),context(20),event(30,5,5)])
        self.assertEqual(sum(r.counts.total for r in self.collect(parent,child)),5)
