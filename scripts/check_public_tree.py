#!/usr/bin/env python3
"""Audit the candidate Git tree, including untracked, non-ignored additions."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_PARTS = {'.build', '.swiftpm', '.artifacts', 'DeviceEvidence', 'DerivedData',
                 'xcuserdata', '__pycache__', 'node_modules', '.venv', '.git'}
PRIVATE_SUFFIXES = {'.p12', '.p8', '.pfx', '.pem', '.key', '.cer', '.crt', '.mobileprovision',
                    '.provisionprofile', '.ipa', '.log', '.xcuserstate', '.pyc', '.zip', '.tar', '.gz'}
MEDIA_SUFFIXES = {'.png', '.jpg', '.jpeg', '.heic', '.mp4', '.mov', '.gif', '.webp', '.pdf'}
PUBLIC_MEDIA = {'Resources/Branding/AppIcon.png', 'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png'}
PUBLIC_HARNESS = {'.harness/.gitignore', '.harness/project.json'}
PATTERNS = {
    'absolute user path': re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'credential': re.compile(r'\b(?:ghp_|github_pat_|sk_live_)[A-Za-z0-9_]{16,}'),
    'device identifier': re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b'),
    'signing team': re.compile(r'DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b'),
}


def audit():
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                     '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    findings, count = [], 0
    for name in sorted(set(filter(None, names))):
        path = ROOT / name
        if not path.exists():  # A tracked deletion is absent from the candidate tree.
            continue
        count += 1
        parts = Path(name).parts
        if path.is_symlink():
            findings.append((name, 'symlink requires explicit publication review'))
            continue
        if (PRIVATE_PARTS.intersection(parts) or path.suffix.lower() in PRIVATE_SUFFIXES
                or path.name == 'Local.xcconfig' or path.name.startswith('.env')
                or (parts[0] == '.harness' and name not in PUBLIC_HARNESS)):
            findings.append((name, 'local-only file'))
        if path.suffix.lower() in MEDIA_SUFFIXES and name not in PUBLIC_MEDIA:
            findings.append((name, 'unreviewed media'))
        if path.stat().st_size > 2 * 1024 * 1024:
            findings.append((name, 'unexpected large public file'))
        try:
            data = path.read_text()
        except UnicodeError:
            if name not in PUBLIC_MEDIA:
                findings.append((name, 'unreviewed binary'))
            continue
        for category, pattern in PATTERNS.items():
            if pattern.search(data):
                findings.append((name, category))
    if findings:
        # Print categories and paths, never the credential value.
        for path, category in findings:
            print(f'FAIL: {path}: {category}')
        raise SystemExit(1)
    print(f'PASS: {count} public candidate files; private state, credentials and media excluded')


if __name__ == '__main__':
    audit()
