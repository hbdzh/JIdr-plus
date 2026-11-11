#!/usr/bin/env python3
"""Offline regression checks for disposable-device cleanup; no SDK or daemon."""
import importlib.util
from pathlib import Path
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('player_baseline', Path(__file__).with_name('player-baseline.py'))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)


class CleanupTests(unittest.TestCase):
    def test_input_comparison_keeps_frame_mode_fixed_and_reverses_order(self):
        self.assertEqual(baseline.input_run_plan(3), [(1,'inline'),(1,'fifo'),(2,'fifo'),
                                                    (2,'inline'),(3,'inline'),(3,'fifo')])

    def test_partial_probes_remain_failures(self):
        report = {'latency': {'detected': 59, 'missed': 1},
                  'restore': {'attempts': 3, 'timeouts': 0, 'fresh_frame_ms': {'count': 3}}}
        self.assertEqual(baseline.probe_failures(report, 60), ['touch probes were missed'])
        report['latency'] = {'detected': 60, 'missed': 0}
        self.assertEqual(baseline.probe_failures(report, 60), [])
        report['restore']['fresh_frame_ms']['count'] = 2
        self.assertEqual(baseline.probe_failures(report, 60), ['window restore measurements were incomplete'])

    def test_comparison_is_balanced_and_counterbalances_order(self):
        plan = baseline.frame_run_plan(3, True)
        self.assertEqual(plan, [(1, 'legacy'), (1, 'shared'), (2, 'shared'),
                                (2, 'legacy'), (3, 'legacy'), (3, 'shared')])
        self.assertEqual(baseline.frame_run_plan(2, False), [(1, 'shared'), (2, 'shared')])

    def test_stop_budget_and_order(self):
        calls = []
        def call(*command, timeout):
            if command[1] == 'stop' and timeout < 130:
                raise subprocess.TimeoutExpired(command, timeout)
            calls.append(command)
        self.assertEqual(baseline.cleanup_device(call, 'disposable-id'), {'stop': 'ok', 'delete': 'ok'})
        self.assertEqual(calls, [('device', 'stop', 'disposable-id'),
                                 ('device', 'delete', 'disposable-id', '--yes')])

    def test_stop_timeout_does_not_delete_locked_device(self):
        calls = []
        def call(*command, timeout):
            calls.append(command)
            raise subprocess.TimeoutExpired(command, timeout)
        result = baseline.cleanup_device(call, 'disposable-id')
        self.assertIn('timed out', result['stop'])
        self.assertEqual(len(calls), 1)
        self.assertNotIn('delete', result)

    def test_delete_failure_is_retained(self):
        def call(*command, timeout):
            if command[1] == 'delete':
                raise RuntimeError('disk is busy')
        self.assertEqual(baseline.cleanup_device(call, 'disposable-id'),
                         {'stop': 'ok', 'delete': 'disk is busy'})


if __name__ == '__main__':
    unittest.main()
