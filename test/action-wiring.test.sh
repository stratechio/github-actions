#!/usr/bin/env bash
# Prove the static wiring of both composite actions: the composite runner,
# required inputs without defaults, a SHA-pinned credential-free checkout where
# one is needed, bash steps that receive event fields and inputs only through
# `env:`, and no expression interpolation inside a run block. The YAML is read
# with BaseLoader (every scalar stays a string, as the runner sees it) and the
# raw text is read alongside for what the parser drops: the version comment on
# the pin and any `secrets.` reference anywhere in the file.
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
[ "$missing" -eq 0 ] || exit 2

"$PYTHON" - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys
import unittest

import yaml

root = Path(sys.argv.pop())

CHECKOUT_PIN = re.compile(r'^actions/checkout@[0-9a-f]{40}$')
# The raw line keeps the human-readable tag the SHA pins, for review and for
# the dependency bot that bumps it.
PINNED_LINE = re.compile(r'^\s*uses: actions/checkout@[0-9a-f]{40} # v\d+\.\d+\.\d+$')


def load(name):
    raw = (root / name / 'action.yml').read_text()
    return yaml.load(raw, Loader=yaml.BaseLoader), raw


class AttributionWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.action, cls.raw = load('pr-attribution')
        cls.steps = cls.action['runs']['steps']

    def test_composite_with_required_patterns_and_optional_hint(self):
        self.assertEqual(self.action['name'], 'pr-attribution')
        self.assertEqual(self.action['runs']['using'], 'composite')
        self.assertEqual(set(self.action['inputs']), {'patterns', 'remediation-hint'})
        patterns = self.action['inputs']['patterns']
        self.assertEqual(patterns['required'], 'true')
        self.assertNotIn('default', patterns, 'the policy comes only from the caller')
        self.assertEqual(self.action['inputs']['remediation-hint']['default'], '')

    def test_checkout_is_pinned_full_history_and_credential_free(self):
        self.assertEqual(len(self.steps), 2)
        checkout = self.steps[0]
        self.assertRegex(checkout['uses'], CHECKOUT_PIN)
        self.assertEqual(checkout['with'], {'fetch-depth': '0', 'persist-credentials': 'false'})
        lines = [line for line in self.raw.splitlines() if 'uses: actions/checkout@' in line]
        self.assertEqual(len(lines), 1)
        self.assertRegex(lines[0], PINNED_LINE)
        self.assertIn(checkout['uses'], lines[0])

    def test_scan_step_reads_event_fields_and_inputs_only_through_env(self):
        scan = self.steps[1]
        self.assertNotIn('uses', scan)
        self.assertEqual(scan['shell'], 'bash')
        self.assertEqual(scan['env'], {
            'PR_TITLE': '${{ github.event.pull_request.title }}',
            'PR_BODY': '${{ github.event.pull_request.body }}',
            'BASE_SHA': '${{ github.event.pull_request.base.sha }}',
            'HEAD_SHA': '${{ github.event.pull_request.head.sha }}',
            'PATTERNS': '${{ inputs.patterns }}',
            'REMEDIATION_HINT': '${{ inputs.remediation-hint }}',
        })
        self.assertNotIn('${{', scan['run'], 'untrusted interpolation in shell')
        for name in scan['env']:
            self.assertIn(name, scan['run'], f'{name} is passed but never read')

    def test_no_step_is_conditional_or_tolerant_and_no_secret_is_read(self):
        for step in self.steps:
            self.assertNotIn('if', step)
            self.assertNotIn('continue-on-error', step)
        self.assertNotIn('${{ secrets.', self.raw, 'a composite action cannot read caller secrets')


class IssueLabelsWiringTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.action, cls.raw = load('pr-issue-labels')
        cls.steps = cls.action['runs']['steps']

    def test_composite_with_required_prefixes(self):
        self.assertEqual(self.action['name'], 'pr-issue-labels')
        self.assertEqual(self.action['runs']['using'], 'composite')
        self.assertEqual(list(self.action['inputs']), ['exclude-label-prefixes'])
        prefixes = self.action['inputs']['exclude-label-prefixes']
        self.assertEqual(prefixes['required'], 'true')
        self.assertNotIn('default', prefixes, 'the policy comes only from the caller')

    def test_single_api_step_without_checkout(self):
        self.assertEqual(len(self.steps), 1)
        step = self.steps[0]
        self.assertNotIn('uses', step, 'no actions, no checkout')
        self.assertNotIn('if', step)
        self.assertNotIn('continue-on-error', step)
        self.assertEqual(step['shell'], 'bash')

    def test_api_step_reads_event_fields_and_inputs_only_through_env(self):
        step = self.steps[0]
        self.assertEqual(step['env'], {
            'GH_TOKEN': '${{ github.token }}',
            'REPO_OWNER': '${{ github.repository_owner }}',
            'REPO_NAME': '${{ github.event.repository.name }}',
            'PR_NUMBER': '${{ github.event.pull_request.number }}',
            'EXCLUDE_LABEL_PREFIXES': '${{ inputs.exclude-label-prefixes }}',
        })
        self.assertNotIn('${{', step['run'], 'untrusted interpolation in shell')
        self.assertNotIn('${{ secrets.', self.raw, 'a composite action cannot read caller secrets')
        for name in ('$REPO_OWNER', '$REPO_NAME', '$PR_NUMBER', 'EXCLUDE_LABEL_PREFIXES'):
            self.assertIn(name, step['run'], f'{name} is passed but never read')


unittest.main(verbosity=2)
PY
