#!/usr/bin/env python3
"""Check publishable files without printing secret values or private file contents."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {'Sources', 'Tests', 'apps', 'config', 'scripts', 'docs', 'assets', '.github'}
ROOT_FILES = {'Package.swift', 'Package.resolved', 'Makefile', 'project.yml', 'README.md',
              'LICENSE', 'SECURITY.md', 'CONTRIBUTING.md', 'CHANGELOG.md', '.gitignore', '.gitleaks.toml'}
PRIVATE_NAMES = re.compile(r'(^|/)(\.local|\.secrets|proof-runs|captures|Walks|xcuserdata)(/|$)|(?:step-count-trial|correction-key|oauth-client|token|state|step-sync-journal|step-sync-status|health-diagnostic|health-proof).*\.json$|\.(p8|p12|mobileprovision|keychain|log)$', re.I)
SENSITIVE = {
    'paired correction private key': re.compile(r'"privateKey"\s*:\s*"[A-Za-z0-9+/]{40,}={0,2}"'),
    'private key': re.compile(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'OAuth refresh token': re.compile(r'1//[A-Za-z0-9_-]{25,}'),
    'Google access token': re.compile(r'ya29\.[A-Za-z0-9._-]{20,}'),
    'GitHub token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})'),
    'configured Google client': re.compile(r'\b[0-9]{6,}-[a-z0-9]{10,}\.apps\.googleusercontent\.com\b'),
    'personal filesystem path': re.compile('/' + r'Users/[^/\s]+/'),
    'non-template client secret': re.compile(r'"client_secret"\s*:\s*"(?!YOUR_|PLACEHOLDER)[^"\s]+"'),
}


def files():
    git = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT, capture_output=True)
    if git.returncode == 0:
        return sorted(set(p for p in git.stdout.decode().split('\0') if p))
    excluded = {'.git', '.local', '.secrets', '.build', '.swiftpm', 'build', '__pycache__'}
    return sorted(str(p.relative_to(ROOT)) for p in ROOT.rglob('*') if p.is_file()
                  and not any(part in excluded or part.endswith('.xcodeproj') for part in p.relative_to(ROOT).parts))


def main():
    problems = []
    paths = files()
    for name in paths:
        parts = Path(name).parts
        if parts[0] not in ALLOWED and name not in ROOT_FILES:
            problems.append((name, 'outside public file allowlist'))
        if PRIVATE_NAMES.search(name):
            problems.append((name, 'private artifact path'))
        path = ROOT / name
        if path.is_symlink():
            problems.append((name, 'symbolic link requires explicit review')); continue
        if not path.is_file():
            continue
        data = path.read_bytes()
        if len(data) > 10 * 1024 * 1024:
            problems.append((name, 'unexpected file larger than 10 MiB'))
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for label, pattern in SENSITIVE.items():
            if pattern.search(text):
                problems.append((name, label))
    if problems:
        for name, label in problems:
            print(f'FAIL {name}: {label} (value withheld)')
        return 1
    print(f'PASS: {len(paths)} public files checked. No blocked artifacts or credential patterns found.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
