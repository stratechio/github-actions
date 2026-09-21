#!/usr/bin/env bash
# Exercise the actual `run:` block of pr-attribution/action.yml on shared
# inputs: synthetic, policy-neutral patterns against titles, bodies, and the
# commits of a real temporary git repository, plus every fail-closed path of
# the policy check and the revision resolver.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON="${PYTHON:-python3}"

# Preconditions, inline: the suite depends on nothing outside this repository.
missing=0
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "MISSING: $PYTHON — install with: brew install python@3.14" >&2
  missing=1
elif ! "$PYTHON" -c 'import yaml' >/dev/null 2>&1; then
  echo "MISSING: pyyaml — install with: $PYTHON -m pip install pyyaml==6.0.3" >&2
  missing=1
fi
command -v jq >/dev/null 2>&1 \
  || { echo "MISSING: jq — install with: brew install jq" >&2; missing=1; }
command -v git >/dev/null 2>&1 \
  || { echo "MISSING: git — install with: brew install git" >&2; missing=1; }
[ "$missing" -eq 0 ] || exit 2

"$PYTHON" - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

import yaml

root = Path(sys.argv.pop())
reference = root / 'pr-attribution/action.yml'
# BaseLoader keeps every scalar a string (no YAML 1.1 booleans or integers),
# which is how the runner hands `with:` and `env:` values to a step.
action = yaml.load(reference.read_text(), Loader=yaml.BaseLoader)

# Policy-neutral fixtures: the action ships no patterns, so the suite supplies
# synthetic ones. Each signal trips exactly one label; the clean prose reuses
# the same bare words without the exact strings.
patterns = [
    {'label': 'example co-author trailer', 'pattern': r'co-authored-by:.*@example\.invalid'},
    {'label': 'example tool footer', 'pattern': 'generated with .*example tool'},
    {'label': 'example noreply address', 'pattern': r'noreply@example\.invalid'},
    {'label': 'example checkpoint line', 'pattern': '^example checkpoint:'},
]
PATTERNS = json.dumps(patterns)
signals = [
    ('example co-author trailer', 'Co-Authored-By: Example Bot <bot@example.invalid>'),
    ('example tool footer', 'Generated with [Example Tool](https://example.invalid/tool)'),
    ('example noreply address', 'Reviewed-by: Example Bot <noreply@example.invalid>'),
    ('example checkpoint line', 'example checkpoint: 1234 @ 5678'),
]
clean = [
    'fix: handle expired refresh tokens',
    'docs: describe the example tool and its checkpoint files',
    'feat: generated with care and tested against example.invalid hosts',
    'Co-Authored-By: Jane Roe <jane@example.com>',
    'Reply to noreply-desk@example.org about the invalid example',
    'example checkpoint files are now ignored',
    "literal shell input: $(exit 77) `exit 77` \" ' $HOME",
    '',
]
OK_LINE = 'pr-attribution: OK (no forbidden patterns matched)'
SELF_TEST_LINE = 'pr-attribution: self-test OK (an unresolvable range fails closed)'
FAIL_LINE = 'FAIL: the pull request title, body, or commit messages match a forbidden pattern.'


class AttributionBehaviorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='pr-attribution-behavior-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.steps = action['runs']['steps']
        cls.scan = [step for step in cls.steps if 'run' in step]
        if len(cls.scan) != 1:
            raise AssertionError('expected exactly one shipped shell block')
        cls.shell = cls.scan[0]['run']
        cls.git('init', '-q', '-b', 'main')
        cls.base = cls.commit('test: clean base')
        cls.clean_head = cls.commit('test: clean head')
        cls.dirty = cls.commit(signals[0][1])
        cls.after_dirty = cls.commit('test: clean commit after the old trailer')

    @classmethod
    def git(cls, *args):
        return subprocess.check_output([
            'git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
            '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            '-C', str(cls.root), *args], text=True, stderr=subprocess.STDOUT).strip()

    @classmethod
    def commit(cls, message):
        cls.git('commit', '--allow-empty', '-qm', message)
        return cls.git('rev-parse', 'HEAD')

    def invoke(self, title='', body='', base=None, head=None, patterns=PATTERNS, hint=''):
        # None means the clean default range; '' is a real (empty) revision.
        env = dict(os.environ, PR_TITLE=title, PR_BODY=body,
                   BASE_SHA=self.base if base is None else base,
                   HEAD_SHA=self.clean_head if head is None else head,
                   PATTERNS=patterns, REMEDIATION_HINT=hint)
        args = ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', self.shell]
        return subprocess.run(args, cwd=self.root, env=env, input='', text=True,
                              capture_output=True)

    def assert_scan(self, expected, **inputs):
        result = self.invoke(**inputs)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertIn(SELF_TEST_LINE, result.stdout)
        if expected == 0:
            self.assertIn(OK_LINE, result.stdout)
            self.assertNotIn('ERROR: forbidden pattern:', result.stdout)
        else:
            self.assertNotIn(OK_LINE, result.stdout)
        return result

    def assert_forbidden(self, label, **inputs):
        result = self.assert_scan(1, **inputs)
        self.assertIn(f'ERROR: forbidden pattern: {label}\n', result.stdout)
        self.assertEqual(result.stdout.count('ERROR: forbidden pattern:'), 1,
                         'a signal trips exactly one label')
        self.assertIn(FAIL_LINE, result.stdout)
        return result

    def test_all_signals_in_titles_and_bodies(self):
        for label, signal in signals:
            for field in ('title', 'body'):
                for text in (signal, signal.upper()):
                    with self.subTest(signal=signal, field=field, text=text):
                        self.assert_forbidden(label, **{field: text})

    def test_legitimate_prose(self):
        for text in clean:
            with self.subTest(text=text):
                self.assert_scan(0, title=text, body=text)

    def test_all_signals_in_commit_messages(self):
        for label, signal in signals:
            parent = self.git('rev-parse', 'HEAD')
            head = self.commit(signal)
            with self.subTest(signal=signal):
                self.assert_forbidden(label, base=parent, head=head)

    def test_clean_empty_and_isolated_commit_ranges(self):
        for base, head in [(self.base, self.clean_head), (self.base, self.base),
                           (self.dirty, self.after_dirty)]:
            with self.subTest(base=base, head=head):
                self.assert_scan(0, base=base, head=head)

    def test_invalid_revisions_fail_closed(self):
        missing = '0123456789abcdef0123456789abcdef01234567'
        for base, head, which in [(missing, self.clean_head, 'base'), (self.base, missing, 'head'),
                                  ('', self.clean_head, 'base'), (self.base, '', 'head')]:
            with self.subTest(base=base, head=head):
                result = self.assert_scan(1, base=base, head=head)
                self.assertIn(f'cannot resolve {which} revision', result.stderr)
                self.assertIn("cannot scan this pull request's commit range", result.stderr)
                # The resolver self-test ran and passed before the real range
                # failed; nothing else reached stdout.
                self.assertEqual(result.stdout, SELF_TEST_LINE + '\n')

    def test_block_scalar_patterns_are_accepted(self):
        # A caller's `patterns: |` arrives indented, multi-line, and with a
        # trailing newline; the policy check reads it as JSON all the same.
        block = textwrap.indent(json.dumps(patterns, indent=2), '  ') + '\n'
        self.assertTrue(block.startswith('  [\n') and block.endswith('  ]\n'))
        label, signal = signals[3]
        self.assert_forbidden(label, title=signal, patterns=block)
        self.assert_scan(0, title=clean[0], patterns=block)

    def test_remediation_hint_is_printed_only_on_failure(self):
        hint = 'Remove the trailer.\nSee the contributing guide.'
        label, signal = signals[0]
        result = self.assert_forbidden(label, body=signal, hint=hint)
        self.assertIn(FAIL_LINE + '\n      Remove the trailer.\n      See the contributing guide.\n',
                      result.stdout)
        # Without a hint the failure line closes the report.
        result = self.assert_forbidden(label, body=signal)
        self.assertTrue(result.stdout.endswith(FAIL_LINE + '\n'), result.stdout)
        # A clean run never prints the hint.
        result = self.assert_scan(0, body=clean[0], hint=hint)
        self.assertNotIn('Remove the trailer.', result.stdout + result.stderr)
        self.assertNotIn(FAIL_LINE, result.stdout)

    def test_invalid_policy_fails_closed(self):
        invalid = [
            '',
            'not json',
            '[]',
            '{}',
            json.dumps([{'label': 'x'}]),
            json.dumps([{'pattern': 'x'}]),
            json.dumps([{'label': '', 'pattern': 'x'}]),
            json.dumps([{'label': 'x', 'pattern': ''}]),
            json.dumps([{'label': 'x', 'pattern': 'x', 'extra': 1}]),
            json.dumps([{'label': 'two\nlines', 'pattern': 'x'}]),
            json.dumps([{'label': 'x', 'pattern': 'two\nlines'}]),
            json.dumps([{'label': 1, 'pattern': 'x'}]),
            json.dumps({'label': 'x', 'pattern': 'x'}),
            json.dumps(['x']),
        ]
        label, signal = signals[0]
        for policy in invalid:
            with self.subTest(policy=policy):
                result = self.invoke(body=signal, patterns=policy)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("'patterns'", result.stderr)
                self.assertNotIn(OK_LINE, result.stdout)
                self.assertNotIn('ERROR: forbidden pattern:', result.stdout)
        # jq accepts the list but grep rejects the expression: a broken policy
        # is not a clean scan.
        broken = json.dumps([{'label': 'broken', 'pattern': '('}])
        result = self.invoke(body=signal, patterns=broken)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('not a valid extended regular expression', result.stderr)
        self.assertIn("'broken'", result.stderr)
        self.assertNotIn('ERROR: forbidden pattern', result.stdout)
        self.assertNotIn(OK_LINE, result.stdout)

    def test_pattern_starting_with_dash_is_not_an_option(self):
        policy = json.dumps([{'label': 'dash pattern', 'pattern': '-x'}])
        self.assert_forbidden('dash pattern', body='run it with -x to see the flags',
                              patterns=policy)
        self.assert_scan(0, body='run it without flags', patterns=policy)


unittest.main(verbosity=2)
PY
