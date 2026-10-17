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
        env = dict(os.environ, EVENT_NAME='pull_request', PR_TITLE=title, PR_BODY=body,
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


MG_FAIL = 'refusing to pass this merge group unscanned.'
PARENT = 'f' * 40
STUB_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MOCK_GH_CAPTURE"
if [ "${MOCK_GH_EXIT:-0}" != 0 ]; then
  echo '{"message": "Not Found", "status": "404"}'
  exit "$MOCK_GH_EXIT"
fi
cat "$MOCK_GH_RESPONSE"
"""


class MergeGroupBehaviorTest(unittest.TestCase):
    """The merge_group path: a queue candidate is scanned from origin/<base> to
    its head, and the title and body come from the API, never from the event."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='pr-attribution-merge-group-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name) / 'repo'
        cls.bin = Path(cls.temp.name) / 'bin'
        cls.root.mkdir()
        cls.bin.mkdir()
        (cls.bin / 'gh').write_text(STUB_GH)
        (cls.bin / 'gh').chmod(0o755)
        cls.capture = Path(cls.temp.name) / 'gh-calls.txt'
        cls.response = Path(cls.temp.name) / 'pull.json'
        cls.shell = [step for step in action['runs']['steps'] if 'run' in step][0]['run']
        cls.git('init', '-q', '-b', 'main')
        # Landed history, an AI trailer included: base..head scans never see it.
        cls.commit('test: landed base')
        cls.commit(signals[0][1])
        cls.landed = cls.commit('test: landed tip')
        cls.git('update-ref', 'refs/remotes/origin/main', cls.landed)
        # A clean candidate: one entry ahead of this pull request, then its own commit.
        cls.commit('test: entry queued ahead')
        cls.clean_head = cls.commit('test: queued change')
        # A candidate whose entry ahead carries a trailer.
        cls.git('checkout', '-q', '--detach', cls.landed)
        cls.commit(signals[2][1])
        cls.dirty_ahead = cls.commit('test: queued change on a dirty entry')
        # A candidate whose own commit carries a trailer.
        cls.git('checkout', '-q', '--detach', cls.landed)
        cls.dirty_own = cls.commit(signals[3][1])

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

    def setUp(self):
        self.capture.unlink(missing_ok=True)

    @staticmethod
    def ref(number=42, base='main', parent=PARENT):
        return f'refs/heads/gh-readonly-queue/{base}/pr-{number}-{parent}'

    def invoke(self, pull=None, head=None, head_ref=None, base_ref='refs/heads/main',
               gh_exit='0', token='test-token', repository='example/widgets', raw=None,
               event_title='', event_body=''):
        fields = {'number': 42, 'state': 'open', 'base': {'ref': 'main'},
                  'title': 'feat: queue support', 'body': 'Adds the queue path.'}
        fields.update(pull or {})
        self.response.write_text(raw if raw is not None else json.dumps(fields))
        env = dict(os.environ, EVENT_NAME='merge_group',
                   PR_TITLE=event_title, PR_BODY=event_body, BASE_SHA='', HEAD_SHA='',
                   MG_HEAD_SHA=self.clean_head if head is None else head,
                   MG_HEAD_REF=self.ref() if head_ref is None else head_ref,
                   MG_BASE_REF=base_ref, REPOSITORY=repository, GH_TOKEN=token,
                   PATTERNS=PATTERNS, REMEDIATION_HINT='',
                   PATH=f'{self.bin}{os.pathsep}{os.environ["PATH"]}',
                   MOCK_GH_CAPTURE=str(self.capture), MOCK_GH_RESPONSE=str(self.response),
                   MOCK_GH_EXIT=gh_exit)
        args = ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', self.shell]
        return subprocess.run(args, cwd=self.root, env=env, input='', text=True,
                              capture_output=True)

    def gh_calls(self):
        return self.capture.read_text().splitlines() if self.capture.exists() else []

    def assert_clean(self, **inputs):
        result = self.invoke(**inputs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(OK_LINE, result.stdout)
        self.assertIn('merge group for pull request #42 (origin/main..', result.stdout)
        return result

    def assert_forbidden(self, label, **inputs):
        result = self.invoke(**inputs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'ERROR: forbidden pattern: {label}\n', result.stdout)
        self.assertIn(FAIL_LINE, result.stdout)
        self.assertNotIn(OK_LINE, result.stdout)
        return result

    def assert_refused(self, reason, **inputs):
        result = self.invoke(**inputs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertIn(MG_FAIL, result.stderr)
        self.assertNotIn(OK_LINE, result.stdout)
        self.assertNotIn('ERROR: forbidden pattern:', result.stdout)
        return result

    def test_clean_candidate_reads_the_queued_pull_request(self):
        self.assert_clean()
        self.assertEqual(self.gh_calls(), ['api repos/example/widgets/pulls/42'])

    def test_landed_history_is_not_rescanned(self):
        # origin/main already holds an AI trailer; only unlanded commits count.
        self.assert_clean(head=self.landed)

    def test_signals_in_the_queued_title_and_body(self):
        for label, signal in signals:
            for field in ('title', 'body'):
                with self.subTest(signal=signal, field=field):
                    self.assert_forbidden(label, pull={field: signal})

    def test_signals_in_candidate_commits(self):
        self.assert_forbidden(signals[3][0], head=self.dirty_own)
        # The commit of an entry queued ahead lands with this candidate too.
        self.assert_forbidden(signals[2][0], head=self.dirty_ahead)

    def test_event_fields_are_not_the_source_of_title_and_body(self):
        self.assert_clean(event_title=signals[0][1], event_body=signals[1][1])
        self.assert_forbidden(signals[1][0], pull={'body': signals[1][1]},
                              event_body=clean[0])

    def test_null_body_is_empty(self):
        self.assert_clean(pull={'body': None})

    def test_malformed_or_mismatched_head_ref_fails_closed(self):
        for head_ref in ['', 'refs/heads/main', self.ref()[len('refs/heads/'):],
                         'refs/heads/gh-readonly-queue/main/pr-42',
                         'refs/heads/gh-readonly-queue/main/pr-42-abc123',
                         'refs/heads/gh-readonly-queue/main/pr-42-' + 'F' * 40,
                         self.ref(number=0), self.ref(number='x'), self.ref(number='042')]:
            with self.subTest(head_ref=head_ref):
                self.assert_refused('unrecognised merge group head ref', head_ref=head_ref)
        self.assert_refused("does not target base 'main'", head_ref=self.ref(base='release'))
        self.assertEqual(self.gh_calls(), [], 'no API call before the ref is proven')

    def test_invalid_base_ref_or_head_sha_fails_closed(self):
        for base_ref in ['', 'main', 'refs/tags/v1.0.0', 'refs/heads/']:
            with self.subTest(base_ref=base_ref):
                self.assert_refused('invalid merge group base ref', base_ref=base_ref)
        for head in ['', 'abc123', self.clean_head.upper(), self.clean_head + '0']:
            with self.subTest(head=head):
                self.assert_refused('invalid merge group head SHA', head=head)
        missing = '0123456789abcdef0123456789abcdef01234567'
        result = self.assert_refused('cannot scan the commit range origin/main..' + missing,
                                     head=missing)
        self.assertIn('cannot resolve head revision', result.stderr)

    def test_base_branch_with_slashes(self):
        # A release/1.x queue: the greedy base capture is anchored on the
        # /pr-<n>-<sha> suffix, so nested branch names parse.
        self.git('update-ref', 'refs/remotes/origin/release/1.x', self.landed)
        self.addCleanup(self.git, 'update-ref', '-d', 'refs/remotes/origin/release/1.x')
        inputs = dict(base_ref='refs/heads/release/1.x', head_ref=self.ref(base='release/1.x'),
                      pull={'base': {'ref': 'release/1.x'}})
        result = self.invoke(**inputs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('(origin/release/1.x..', result.stdout)
        self.assert_forbidden(signals[2][0], head=self.dirty_ahead, **inputs)

    def test_missing_base_branch_fails_closed(self):
        result = self.assert_refused('cannot scan the commit range origin/release..',
                                     base_ref='refs/heads/release',
                                     head_ref=self.ref(base='release'),
                                     pull={'base': {'ref': 'release'}})
        self.assertIn('cannot resolve base revision', result.stderr)

    def test_unreadable_or_unexpected_pull_request_fails_closed(self):
        self.assert_refused('cannot read pull request #42', gh_exit='1')
        for pull in [{'state': 'closed'}, {'base': {'ref': 'release'}}, {'number': 43},
                     {'title': None}, {'body': 7}]:
            with self.subTest(pull=pull):
                self.assert_refused('is not an open pull request into', pull=pull)
        self.assert_refused('is not an open pull request into', raw='not json')
        self.assert_refused('is not an open pull request into', raw='')

    def test_missing_token_or_repository_fails_closed(self):
        self.assert_refused('no token to read the queued pull request', token='')
        for repository in ['', 'widgets', 'example/widgets/extra', 'example/$(exit 7)']:
            with self.subTest(repository=repository):
                self.assert_refused('invalid repository', repository=repository)
        self.assertEqual(self.gh_calls(), [])

    def test_pull_request_events_never_call_the_api(self):
        env = dict(os.environ, EVENT_NAME='pull_request', PR_TITLE='fix: clean', PR_BODY='',
                   BASE_SHA=self.landed, HEAD_SHA=self.clean_head,
                   MG_HEAD_SHA='', MG_HEAD_REF='', MG_BASE_REF='', REPOSITORY='example/widgets',
                   GH_TOKEN='test-token', PATTERNS=PATTERNS, REMEDIATION_HINT='',
                   PATH=f'{self.bin}{os.pathsep}{os.environ["PATH"]}',
                   MOCK_GH_CAPTURE=str(self.capture), MOCK_GH_RESPONSE=str(self.response))
        args = ['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', self.shell]
        result = subprocess.run(args, cwd=self.root, env=env, input='', text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(OK_LINE, result.stdout)
        self.assertNotIn('merge group', result.stdout)
        self.assertEqual(self.gh_calls(), [])


unittest.main(verbosity=2)
PY
