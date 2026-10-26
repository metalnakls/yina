#!/usr/bin/env python3
"""Prepare profile-backed entitlements without exporting signing keys or logging profiles."""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess

EXTENSIONS = {
    'formatreader': 'com.apple.developer.mediaextension.formatreader',
    'videodecoder': 'com.apple.developer.mediaextension.videodecoder',
}


def matches(profile, bundle_id, capability, identity, now):
    entitlements = profile.get('Entitlements', {})
    app_id = entitlements.get('com.apple.application-identifier', entitlements.get('application-identifier', ''))
    expiration = profile.get('ExpirationDate')
    if not isinstance(expiration, datetime):
        return False
    expiration = expiration.replace(tzinfo=timezone.utc) if expiration.tzinfo is None else expiration
    return (expiration > now and entitlements.get(capability) is True
            and app_id.endswith('.' + bundle_id)
            and any(hashlib.sha1(cert).hexdigest().upper() == identity.upper()
                    for cert in profile.get('DeveloperCertificates', []))
            and ('Platform' not in profile or 'OSX' in profile['Platform']))


def prepare(identity, profile_dirs, output):
    candidates = []
    for directory in profile_dirs:
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix not in ('.provisionprofile', '.mobileprovision'):
                continue
            decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
            if decoded.returncode:
                continue
            try:
                candidates.append((path, plistlib.loads(decoded.stdout)))
            except (ValueError, plistlib.InvalidFileException):
                continue
    selected = {}
    for kind, capability in EXTENSIONS.items():
        bundle_id = 'tsmc.yina.' + kind
        found = [(path, data) for path, data in candidates
                 if matches(data, bundle_id, capability, identity, datetime.now(timezone.utc))]
        if not found:
            raise SystemExit('Missing a valid macOS provisioning profile for ' + bundle_id
                             + ' with ' + capability + ' and signing certificate ' + identity
                             + '. Obtain the profile through Xcode provisioning; the existing installation was not changed.')
        selected[kind] = max(found, key=lambda item: item[1]['ExpirationDate'])
    output.mkdir(parents=True, exist_ok=True)
    for kind, (path, profile) in selected.items():
        profile_entitlements = profile['Entitlements']
        app_id_key = ('com.apple.application-identifier' if 'com.apple.application-identifier' in profile_entitlements
                      else 'application-identifier')
        entitlements = {
            EXTENSIONS[kind]: True,
            'com.apple.security.app-sandbox': True,
            'com.apple.security.files.user-selected.read-only': True,
            app_id_key: profile_entitlements[app_id_key],
        }
        if 'com.apple.developer.team-identifier' in profile_entitlements:
            entitlements['com.apple.developer.team-identifier'] = profile_entitlements['com.apple.developer.team-identifier']
        shutil.copyfile(path, output / (kind + '.provisionprofile'))
        (output / (kind + '.entitlements')).write_bytes(plistlib.dumps(entitlements))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profiles-dir', type=Path, action='append')
    args = parser.parse_args()
    directories = args.profiles_dir or [
        Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
        Path.home() / 'Library/MobileDevice/Provisioning Profiles',
    ]
    prepare(args.identity, directories, args.output)
