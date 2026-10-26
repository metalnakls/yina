import importlib.util
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('media_signing', Path(__file__).resolve().parents[1] / 'prepare_media_extension_signing.py')
media_signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(media_signing)

class ProfileMatchingTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.certificate = b'synthetic-test-certificate'
        self.identity = hashlib.sha1(self.certificate).hexdigest().upper()
        self.capability = media_signing.EXTENSIONS['formatreader']
        self.profile = {
            'ExpirationDate': self.now + timedelta(days=1),
            'DeveloperCertificates': [self.certificate],
            'Platform': ['OSX'],
            'Entitlements': {
                self.capability: True,
                'com.apple.application-identifier': 'TESTTEAM.tsmc.yina.formatreader',
            },
        }

    def matches(self):
        return media_signing.matches(self.profile, 'tsmc.yina.formatreader', self.capability, self.identity, self.now)

    def test_requires_matching_certificate(self):
        self.assertTrue(self.matches())
        self.profile['DeveloperCertificates'] = [b'other-certificate']
        self.assertFalse(self.matches())

    def test_requires_restricted_capability(self):
        self.profile['Entitlements'].pop(self.capability)
        self.assertFalse(self.matches())

    def test_rejects_other_app_and_wildcard(self):
        for app_id in ['TESTTEAM.tsmc.yina.other', 'TESTTEAM.*']:
            self.profile['Entitlements']['com.apple.application-identifier'] = app_id
            self.assertFalse(self.matches())

    def test_rejects_expired_profile(self):
        self.profile['ExpirationDate'] = self.now - timedelta(seconds=1)
        self.assertFalse(self.matches())

    def test_handles_plist_utc_date(self):
        self.profile['ExpirationDate'] = (self.now + timedelta(days=1)).replace(tzinfo=None)
        self.assertTrue(self.matches())

    def test_rejects_non_macos_profile(self):
        self.profile['Platform'] = ['iOS']
        self.assertFalse(self.matches())

if __name__ == '__main__':
    unittest.main()
