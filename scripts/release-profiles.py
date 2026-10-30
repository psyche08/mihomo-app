#!/usr/bin/env python3
"""Select and freeze Developer ID profiles without relying on Xcode auto-selection."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

TEAM = '89LGY6BD53'
LEAF = '2E1EF531C972A15F5B5C58855001FA6FA1186383'
HOST = 'dev.linsheng.mihomo-app'
EXT = HOST + '.app-proxy'

def eligible(profile, bundle, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get('ExpirationDate')
    if not isinstance(expiry, dt.datetime):
        return False
    expiry = expiry.replace(tzinfo=dt.timezone.utc) if expiry.tzinfo is None else expiry
    e = profile.get('Entitlements', {})
    return (expiry > now + dt.timedelta(days=1)
            and profile.get('ProvisionsAllDevices') is True
            and 'OSX' in profile.get('Platform', [])
            and TEAM in profile.get('TeamIdentifier', [])
            and e.get('com.apple.application-identifier') == TEAM + '.' + bundle
            and e.get('com.apple.developer.team-identifier') == TEAM
            and not e.get('get-task-allow', False)
            and LEAF in [hashlib.sha1(c).hexdigest().upper() for c in profile.get('DeveloperCertificates', [])]
            and 'app-proxy-provider-systemextension' in e.get('com.apple.developer.networking.networkextension', [])
            and (bundle != HOST or e.get('com.apple.developer.system-extension.install') is True))

def decode(path):
    return plistlib.loads(subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(path)],
                                        check=True, capture_output=True).stdout)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def choose(candidates, bundle):
    matches = [(p, d) for p, d in candidates if eligible(d, bundle)]
    if not matches:
        raise ValueError('No valid Developer ID profile for ' + bundle + ' and pinned certificate ' + LEAF)
    # Renewed profiles win deterministically; duplicate copies of one UUID must agree.
    by_uuid = {}
    for p, d in matches:
        uuid = d['UUID']
        if uuid in by_uuid and digest(p) != digest(by_uuid[uuid][0]):
            raise ValueError('Conflicting profile copies for UUID ' + uuid)
        by_uuid[uuid] = (p, d)
    return max(by_uuid.values(), key=lambda pair: (pair[1]['ExpirationDate'], pair[1].get('CreationDate', dt.datetime.min), pair[1]['UUID']))

def prepare(state, roots, installed):
    state.mkdir(parents=True, exist_ok=True)
    if (state / 'profiles.json').exists():
        return verify(state, installed)
    candidates = []
    for root in roots:
        for path in sorted(root.glob('*.provisionprofile')):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                candidates.append((path, decode(path)))
            except (subprocess.CalledProcessError, plistlib.InvalidFileException, ValueError):
                continue
    selected = {b: choose(candidates, b) for b in (HOST, EXT)}
    (state / 'profiles').mkdir(exist_ok=True)
    rows, mapping = [], {}
    for bundle, (path, profile) in selected.items():
        uuid = profile['UUID']
        # UUID is later used as a filename, never accept a path from CMS data.
        import uuid as uuid_module
        if str(uuid_module.UUID(uuid)).upper() != uuid.upper():
            raise ValueError('Invalid profile UUID')
        target = state / 'profiles' / (uuid + '.provisionprofile')
        shutil.copyfile(path, target)
        mapping[bundle] = uuid
        rows.append({'bundle': bundle, 'uuid': uuid, 'sha256': digest(target)})
    options = {'method': 'developer-id', 'teamID': TEAM, 'signingStyle': 'manual',
               'signingCertificate': LEAF, 'provisioningProfiles': mapping}
    export = state / 'export.plist'
    export.write_bytes(plistlib.dumps(options))
    manifest = {'profiles': rows, 'export_sha256': digest(export)}
    temp = state / 'profiles.json.tmp'
    temp.write_text(json.dumps(manifest, indent=2) + '\n')
    temp.replace(state / 'profiles.json')
    verify(state, installed)

def verify(state, installed):
    manifest = json.loads((state / 'profiles.json').read_text())
    if digest(state / 'export.plist') != manifest['export_sha256']:
        raise ValueError('Frozen export options changed')
    if len(manifest['profiles']) != 2 or {r['bundle'] for r in manifest['profiles']} != {HOST, EXT}:
        raise ValueError('Frozen profiles do not cover both targets')
    installed.mkdir(parents=True, exist_ok=True)
    for row in manifest['profiles']:
        import uuid
        if str(uuid.UUID(row['uuid'])).upper() != row['uuid'].upper():
            raise ValueError('Invalid frozen profile UUID')
        path = state / 'profiles' / (row['uuid'] + '.provisionprofile')
        if path.is_symlink() or digest(path) != row['sha256'] or not eligible(decode(path), row['bundle']):
            raise ValueError('Frozen profile changed, expired or no longer eligible: ' + row['bundle'])
        target = installed / path.name
        if target.is_symlink() or (target.exists() and digest(target) != row['sha256']):
            raise ValueError('Installed profile conflicts with frozen UUID')
        if not target.exists():
            shutil.copyfile(path, target)
        print(row['bundle'] + ': ' + row['uuid'])

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'verify'])
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--directory', type=Path)
    args = parser.parse_args()
    installed = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
    roots = [installed, Path.home() / 'Library/MobileDevice/Provisioning Profiles']
    if args.directory:
        if not args.directory.is_dir():
            parser.error('profile directory does not exist')
        roots.insert(0, args.directory)
    try:
        prepare(args.state, roots, installed) if args.action == 'prepare' else verify(args.state, installed)
    except (ValueError, KeyError, OSError, AssertionError) as error:
        parser.exit(1, 'release profiles: ' + str(error) + '\n')
