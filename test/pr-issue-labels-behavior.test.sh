#!/usr/bin/env bash
# Exercise the actual `run:` block of pr-issue-labels/action.yml against a
# stub `gh` (fixture GraphQL answers, recorded label writes). Real jq does the
# filtering, as on the runner.
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
[ "$missing" -eq 0 ] || exit 2

"$PYTHON" - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

import yaml

root = Path(sys.argv.pop())
reference = root / 'pr-issue-labels/action.yml'
# BaseLoader keeps every scalar a string (no YAML 1.1 booleans or integers),
# which is how the runner hands `env:` values to a step.
action = yaml.load(reference.read_text(), Loader=yaml.BaseLoader)

OWNER = 'example-org'
NAME = 'example-repo'
REPO = f'{OWNER}/{NAME}'
PR_NUMBER = '42'

# The stub answers exactly the two calls the run block makes and refuses any
# other, so an unexpected API call is a test failure rather than a silent pass.
STUB = r'''#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$STUB_CALLS"
case "$1 $2" in
  "api graphql")
    cat "$STUB_GRAPHQL"
    exit "${STUB_GRAPHQL_EXIT:-0}" ;;
  "api --method")
    [ "$3" = POST ] || { echo "stub gh: unexpected method $3" >&2; exit 99; }
    printf '%s' "$4" > "$STUB_POST_ENDPOINT"
    cat > "$STUB_POST_BODY"
    if [ -n "${STUB_POST_RESPONSE:-}" ]; then
      printf '%s' "$STUB_POST_RESPONSE"
    else
      jq -c '[.labels[] | {name: .}]' "$STUB_POST_BODY"
    fi
    exit "${STUB_POST_EXIT:-0}" ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 99 ;;
esac
'''


def graphql(pr_labels=(), issues=()):
    """Shape of the one query the run block sends; issues = [(repo, labels)]."""
    return {'data': {'repository': {'pullRequest': {
        'labels': {'nodes': [{'name': n} for n in pr_labels]},
        'closingIssuesReferences': {'nodes': [
            {'number': i + 1, 'repository': {'nameWithOwner': repo},
             'labels': {'nodes': [{'name': n} for n in labels]}}
            for i, (repo, labels) in enumerate(issues)]}}}}}


class IssueLabelsBehaviorTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        steps = action['runs']['steps']
        cls.run_steps = [step for step in steps if 'run' in step]
        if len(cls.run_steps) != 1:
            raise AssertionError('expected exactly one shipped shell block')
        cls.shell = cls.run_steps[0]['run']

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='pr-issue-labels-behavior-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        bindir = self.root / 'bin'
        bindir.mkdir()
        stub = bindir / 'gh'
        stub.write_text(STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        self.calls = self.root / 'calls.log'
        self.post_body = self.root / 'post-body.json'
        self.post_endpoint = self.root / 'post-endpoint.txt'
        # Every variable the step's `env:` declares is set explicitly; the
        # stub comes first on PATH so `gh` never reaches a real client.
        self.env = dict(os.environ,
                        PATH=f"{bindir}:{os.environ.get('PATH', os.defpath)}",
                        GH_TOKEN='stub-token',
                        REPO_OWNER=OWNER, REPO_NAME=NAME, PR_NUMBER=PR_NUMBER,
                        EXCLUDE_LABEL_PREFIXES='phase:',
                        STUB_CALLS=str(self.calls),
                        STUB_POST_BODY=str(self.post_body),
                        STUB_POST_ENDPOINT=str(self.post_endpoint))

    def invoke(self, fixture, **overrides):
        graphql_file = self.root / 'graphql.json'
        graphql_file.write_text(json.dumps(fixture))
        env = dict(self.env, STUB_GRAPHQL=str(graphql_file), **overrides)
        return subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail',
                               '-c', self.shell], cwd=self.root, env=env, input='',
                              text=True, capture_output=True)

    def posted(self):
        if not self.post_body.exists():
            return None
        body = json.loads(self.post_body.read_text())
        self.assertEqual(list(body), ['labels'], 'the additive write carries only labels')
        return body['labels']

    def assert_added(self, fixture, expected, **overrides):
        result = self.invoke(fixture, **overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.posted(), expected)
        self.assertEqual(self.post_endpoint.read_text(),
                         f'repos/{REPO}/issues/{PR_NUMBER}/labels')
        self.assertIn('OK (added from the closing issues)', result.stdout)
        for name in expected:
            self.assertIn(f'  {name}\n', result.stdout)
        return result

    def assert_nothing_to_add(self, fixture, **overrides):
        result = self.invoke(fixture, **overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.posted())
        self.assertIn('OK (nothing to add)', result.stdout)
        self.assertEqual(self.calls.read_text().count('\n'), 1, 'exactly one API read')

    def test_union_dedup_and_prefix_exclusion(self):
        fixture = graphql(issues=[
            (REPO, ['type:bug', 'phase:review', 'priority:medium', 'bug']),
            (REPO, ['type:bug', 'phase:active', 'help wanted', 'area:docs']),
        ])
        self.assert_added(fixture, ['area:docs', 'bug', 'help wanted', 'priority:medium',
                                    'type:bug'])

    def test_labels_already_on_the_pr_are_not_re_added(self):
        fixture = graphql(pr_labels=['type:bug', 'automation:deploy'],
                          issues=[(REPO, ['type:bug', 'priority:low', 'phase:review'])])
        self.assert_added(fixture, ['priority:low'])

    def test_cross_repository_issue_is_ignored(self):
        foreign = ['type:feature', 'priority:high']
        fixture = graphql(issues=[('other-org/other-repo', foreign),
                                  (f'other-org/{NAME}', foreign),
                                  (f'{OWNER}/other-repo', foreign),
                                  (REPO, ['type:maintenance', 'phase:review'])])
        self.assert_added(fixture, ['type:maintenance'])

    def test_label_names_with_spaces_survive(self):
        names = ['status: planned', 'good first issue', 'type:feature']
        fixture = graphql(issues=[(REPO, names)])
        self.assert_added(fixture, sorted(names))

    def test_no_closing_issue_adds_nothing(self):
        self.assert_nothing_to_add(graphql())

    def test_edit_refreshes_labels_after_a_late_link(self):
        # Opening before the link exists succeeds without writing labels.
        self.assert_nothing_to_add(graphql(pr_labels=['automation:deploy']))
        # A later edit re-reads the current links and adds what is new while
        # the labels already on the pull request stay untouched.
        linked = graphql(pr_labels=['automation:deploy'],
                         issues=[(REPO, ['type:bug', 'priority:low', 'phase:review'])])
        self.assert_added(linked, ['priority:low', 'type:bug'])
        self.assertEqual(self.calls.read_text().splitlines(),
                         ['api graphql', 'api graphql', 'api --method'])

    def test_only_excluded_labels_add_nothing(self):
        self.assert_nothing_to_add(graphql(issues=[(REPO, ['phase:review', 'phase:active'])]))

    def test_everything_already_present_adds_nothing(self):
        self.assert_nothing_to_add(graphql(pr_labels=['type:bug', 'priority:low'],
                                           issues=[(REPO, ['type:bug', 'priority:low',
                                                           'phase:review'])]))

    def test_graphql_failure_fails_closed(self):
        result = self.invoke(graphql(issues=[(REPO, ['type:bug'])]), STUB_GRAPHQL_EXIT='1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIsNone(self.posted())
        self.assertIn("cannot read the pull request's closing issues", result.stderr)

    def test_missing_pull_request_in_response_fails_closed(self):
        for response in ({'data': {'repository': {'pullRequest': None}}},
                         {'data': {'repository': None}},
                         {'data': {'repository': {'pullRequest': 'not an object'}}},
                         {'errors': [{'message': 'Could not resolve to a PullRequest'}]}):
            with self.subTest(response=response):
                result = self.invoke(response)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIsNone(self.posted())
                self.assertIn('unexpected GraphQL response', result.stderr)

    def test_write_failure_fails_closed(self):
        result = self.invoke(graphql(issues=[(REPO, ['type:bug'])]), STUB_POST_EXIT='1')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.posted(), ['type:bug'])
        self.assertIn('could not add the labels', result.stderr)

    def test_unverified_write_fails_closed(self):
        response = json.dumps([{'name': 'type:bug'}])  # priority:low never landed
        result = self.invoke(graphql(issues=[(REPO, ['type:bug', 'priority:low'])]),
                             STUB_POST_RESPONSE=response)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('not present on the pull request after the write', result.stderr)
        self.assertIn('  priority:low', result.stderr)

    def test_invalid_pull_request_number_fails_before_any_call(self):
        for number in ('', '12a', '-1'):
            with self.subTest(number=number):
                result = self.invoke(graphql(), PR_NUMBER=number)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('invalid pull request number', result.stderr)
                self.assertFalse(self.calls.exists(), 'no API call was made')

    def test_multiple_prefixes_with_whitespace(self):
        fixture = graphql(issues=[(REPO, ['phase:review', 'wip-draft', 'type:bug',
                                          'priority:medium'])])
        self.assert_added(fixture, ['priority:medium', 'type:bug'],
                          EXCLUDE_LABEL_PREFIXES=' phase: , wip-')

    def test_empty_prefix_list_fails_before_any_call(self):
        for prefixes in ('', ' , '):
            with self.subTest(prefixes=prefixes):
                result = self.invoke(graphql(issues=[(REPO, ['type:bug'])]),
                                     EXCLUDE_LABEL_PREFIXES=prefixes)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("'exclude-label-prefixes' must name at least one label-name prefix",
                              result.stderr)
                self.assertFalse(self.calls.exists(), 'no API call was made')


unittest.main(verbosity=2)
PY
