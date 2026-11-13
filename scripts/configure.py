#!/usr/bin/env python3
"""Generate a local Xcode project without putting an owner's configuration in Git."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def read_configuration(ci=False):
    if ci:
        # Compile-only identifiers. No sign-in, network call or health write runs.
        return {
            "apple_team_id": "",
            "mac_bundle_id": "org.padsteps.build.desktop",
            "phone_bundle_id": "org.padsteps.build.iphone",
            "google_ios_client_id": "compile-only.apps.googleusercontent.com",
        }, {"installed": {"client_id": "compile-only-recorder.apps.googleusercontent.com", "client_secret": ""}}
    try:
        settings = json.loads((ROOT / '.local/settings.json').read_text())
        oauth = json.loads((ROOT / '.local/desktop-oauth.json').read_text())
    except (OSError, ValueError):
        raise SystemExit('Copy config/*.example.json into .local/ as settings.json and desktop-oauth.json, then fill in your own configuration. No credentials were printed.')
    for key in ['mac_bundle_id', 'phone_bundle_id']:
        value = settings.get(key, '')
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', value):
            raise SystemExit(f'Invalid {key}; use your own reverse-domain bundle identifier.')
    if not re.fullmatch(r'[A-Z0-9]{10}', settings.get('apple_team_id', '')):
        raise SystemExit('apple_team_id must be your ten-character Apple development team ID.')
    for value in [settings.get('google_ios_client_id', ''), oauth.get('installed', {}).get('client_id', '')]:
        if not re.fullmatch(r'[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com', value):
            raise SystemExit('Configure real native iOS and desktop Google OAuth client IDs from your own project.')
    if not isinstance(oauth.get('installed', {}).get('client_secret'), str) or not oauth['installed']['client_secret']:
        raise SystemExit('The downloaded desktop OAuth JSON is missing its installed-client configuration.')
    return settings, oauth


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ci', action='store_true', help='Generate a compile-only project with dummy identifiers; no real credentials.')
    args = parser.parse_args()
    settings, oauth = read_configuration(args.ci)
    if shutil.which('xcodegen') is None:
        raise SystemExit('Install XcodeGen first: brew install xcodegen')
    local = ROOT / '.local'
    local.mkdir(mode=0o700, exist_ok=True)
    os.chmod(local, 0o700)
    resource = ROOT / 'apps/macOS/Resources/oauth-client.json'
    resource.write_text(json.dumps(oauth, indent=2) + '\n')
    os.chmod(resource, 0o600)
    client = settings['google_ios_client_id']
    env = os.environ.copy()
    env.update({
        'PADSTEPS_APPLE_TEAM': settings['apple_team_id'],
        'PADSTEPS_MAC_BUNDLE_ID': settings['mac_bundle_id'],
        'PADSTEPS_PHONE_BUNDLE_ID': settings['phone_bundle_id'],
        'PADSTEPS_IOS_CLIENT_ID': client,
        'PADSTEPS_IOS_CALLBACK_SCHEME': '.'.join(reversed(client.split('.'))),
        'PADSTEPS_RECORDER_CLIENT_ID': oauth['installed']['client_id'],
    })
    subprocess.run(['xcodegen', 'generate', '--spec', 'project.yml'], cwd=ROOT, env=env, check=True)
    print('Local project generated. Personal settings and OAuth resources are ignored by Git.')


if __name__ == '__main__':
    main()
