"""Fault checks for release gating. No Apple account, network, or real signing tools."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        # The host /tmp may be noexec; use an ignored workspace directory.
        (ROOT / '.build').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / '.build')
        self.folder = Path(self.temp.name)
        self.log = self.folder / 'calls'
        tool = self.folder / 'xcrun'
        tool.write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$FAKE_LOG"
if [[ "$1" == "notarytool" ]]; then
  printf '{"status":"%s"}\\n' "$FAKE_STATUS"
else
  if [[ "$2" == "staple" && "$FAKE_STAPLE_FAILURE" == "1" ]]; then exit 1; fi
fi
''')
        tool.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items() if key not in
                    ('NOTARY_PROFILE', 'APPLE_ID', 'APPLE_TEAM_ID', 'APPLE_APP_PASSWORD')}
        self.env.update(PATH=str(self.folder) + os.pathsep + os.environ['PATH'],
                        FAKE_LOG=str(self.log), FAKE_STATUS='Accepted', FAKE_STAPLE_FAILURE='0')

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self):
        return subprocess.run(['bash', str(ROOT / 'scripts/notarize.sh'), 'fixture.zip', 'fixture.app'],
                              env=self.env, capture_output=True, text=True, check=False)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_missing_or_partial_credentials_never_submit(self):
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.env.update(APPLE_ID='fixture@example.invalid', APPLE_TEAM_ID='FIXTURE')
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rejected_submission_cannot_staple_even_if_tool_exits_zero(self):
        self.env.update(NOTARY_PROFILE='fixture', FAKE_STATUS='Invalid')
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not accepted', result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.calls()[0].startswith('notarytool submit'))

    def test_accepted_submission_staples_then_validates(self):
        self.env['NOTARY_PROFILE'] = 'fixture'
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.calls()[1:], ['stapler staple fixture.app', 'stapler validate fixture.app'])

    def test_stapling_failure_is_not_a_successful_consumer_package(self):
        self.env.update(NOTARY_PROFILE='fixture', FAKE_STAPLE_FAILURE='1')
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.assertEqual(len(self.calls()), 2)


if __name__ == '__main__':
    unittest.main()
