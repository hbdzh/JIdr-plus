#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Runner safety regressions. CLI/guard checks only; never mount a view."""
import subprocess
import sys
import unittest
from pathlib import Path

BINARY = Path(sys.argv.pop(1)).resolve()
ROOT = Path(__file__).resolve().parents[4]


class RunnerSafetyTests(unittest.TestCase):
    def invoke(self, *args):
        return subprocess.run([str(BINARY), *args], capture_output=True, text=True, timeout=10)

    def test_local_run_requires_explicit_scope(self):
        result = self.invoke('--check')
        self.assertEqual(result.returncode, 2)
        self.assertIn('choose --only CASE', result.stderr)
        self.assertNotIn('registered', result.stdout)

    def test_repeated_only_selects_exact_cases_without_duplicates(self):
        result = self.invoke('--list', '--only', 'tools-battery-light', '--only', 'tools-calls-light',
                             '--only', 'tools-battery-light')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['tools-battery-light', 'tools-calls-light'])

    def test_unknown_case_never_falls_back_to_all(self):
        result = self.invoke('--list', '--only', 'tools-does-not-exist')
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown case', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_all_and_only_are_mutually_exclusive(self):
        result = self.invoke('--list', '--all', '--only', 'tools-battery-light')
        self.assertEqual(result.returncode, 2)
        self.assertIn('cannot be combined', result.stderr)

    def test_list_only_does_not_need_bridges_or_rendering(self):
        result = self.invoke('--list')
        self.assertEqual(result.returncode, 0, result.stderr)
        names = result.stdout.splitlines()
        self.assertIn('tools-battery-light', names)
        self.assertIn('center-empty', names)
        self.assertIn('player-running', names)
        self.assertNotIn('snapshot:', result.stdout)

    def test_snapshot_shell_refuses_implicit_full_matrix_before_build(self):
        result = subprocess.run(['bash', str(ROOT / 'apps/jidr-swiftui/snapshot.sh'), '--check'],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Choose --only CASE', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_visible_interaction_suite_requires_explicit_opt_in(self):
        result = subprocess.run(['bash', str(ROOT / 'apps/jidr-swiftui/test-center-ui.sh')],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertIn('opens visible windows', result.stderr)
        self.assertEqual(result.stdout, '')


unittest.main()
