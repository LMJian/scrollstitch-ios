#!/usr/bin/env python3
"""Read-only checks for release resources and, later, the actual built bundle."""
import argparse
from datetime import date
import hashlib
import re
from urllib.parse import urlsplit
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REASONS = {
    'NSPrivacyAccessedAPICategoryFileTimestamp': 'C617.1',
    'NSPrivacyAccessedAPICategorySystemBootTime': '35F9.1',
    'NSPrivacyAccessedAPICategoryUserDefaults': 'CA92.1',
    'NSPrivacyAccessedAPICategoryDiskSpace': 'E174.1',
}

def require(condition, message):
    if not condition:
        raise ValueError(message)

def read_plist(path):
    return plistlib.loads(Path(path).read_bytes())

def resource_check(root=ROOT):
    inventory = json.loads((root / 'docs/privacy-inventory.json').read_text())
    require(inventory['schemaVersion'] == 1, 'unknown privacy inventory schema')
    expected = {'App': {}, 'Controls': {}}
    for entry in inventory['entries']:
        category, reason = entry['category'], entry['reason']
        require(REASONS.get(category) == reason, 'unreviewed privacy reason')
        require(entry['reviewStatus'] == 'reviewed' and entry['limitationsReviewed'], 'privacy review incomplete')
        require(entry['source'].startswith('https://developer.apple.com/documentation/'), 'missing primary reason source')
        require(entry['purpose'].strip() and entry['reviewedAt'], 'missing purpose or review date')
        for anchor in entry['anchors']:
            require(not Path(anchor).is_absolute() and '..' not in Path(anchor).parts and (root / anchor).is_file(), 'invalid source anchor')
        for target in entry['targets']:
            require(target in expected and category not in expected[target], 'invalid/duplicate target category')
            expected[target][category] = [reason]
    for target, categories in expected.items():
        manifest = read_plist(root / target / 'PrivacyInfo.xcprivacy')
        require(manifest.get('NSPrivacyTracking') is False, 'tracking must be false')
        require(manifest.get('NSPrivacyTrackingDomains') == [], 'unexpected tracking domains')
        require(manifest.get('NSPrivacyCollectedDataTypes') == [], 'collection declaration drift')
        entries = manifest['NSPrivacyAccessedAPITypes']
        actual = {e['NSPrivacyAccessedAPIType']: e['NSPrivacyAccessedAPITypeReasons'] for e in entries}
        require(len(actual) == len(entries) and actual == categories, f'{target} privacy declaration differs from reviewed inventory')
    icon_dir = root / 'App/Assets.xcassets/AppIcon.appiconset'
    catalog = json.loads((icon_dir / 'Contents.json').read_text())
    icons = catalog['images']
    require(len(icons) == 1 and icons[0]['size'] == '1024x1024' and icons[0]['platform'] == 'ios', 'invalid icon catalog')
    icon = (icon_dir / icons[0]['filename']).read_bytes()
    require(icon[:8] == b'\x89PNG\r\n\x1a\n' and icon[12:16] == b'IHDR', 'invalid PNG')
    width, height, depth, color = struct.unpack('>IIBB', icon[16:26])
    require((width, height, depth, color) == (1024, 1024, 8, 2) and b'tRNS' not in icon, 'icon must be opaque 1024px RGB PNG')
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root / 'ScrollStitch.xcodeproj/project.pbxproj')]))['objects']
    targets = {v['name']: v for v in project.values() if v.get('isa') == 'PBXNativeTarget'}
    require(set(targets) == {'ScrollStitch', 'ScrollStitchStore', 'ScrollControls'}, 'unexpected product targets')
    for name, target in targets.items():
        is_store = name == 'ScrollStitchStore'
        is_controls = name == 'ScrollControls'
        folder = 'Controls' if is_controls else 'App'
        refs = []
        for phase_id in target['buildPhases']:
            phase = project[phase_id]
            if phase['isa'] == 'PBXResourcesBuildPhase':
                refs += [project[project[f]['fileRef']]['path'] for f in phase['files']]
        require(f'{folder}/PrivacyInfo.xcprivacy' in refs, f'{folder} manifest missing from resource phase')
        require(f'{"Controls" if folder == "App" else "App"}/PrivacyInfo.xcprivacy' not in refs, 'cross-target manifest contamination')
        if folder == 'App':
            product_path = 'Resources/Store/ProductInfo.json' if is_store else 'Resources/ProductInfo.json'
            other_product = 'Resources/ProductInfo.json' if is_store else 'Resources/Store/ProductInfo.json'
            require('App/Assets.xcassets' in refs and product_path in refs and other_product not in refs, 'wrong edition resources')
            product_check(json.loads((root / product_path).read_text()))
        configs = project[target['buildConfigurationList']]['buildConfigurations']
        modes = {project[c]['name']: project[c]['buildSettings'] for c in configs}
        require(set(modes) == {'Debug', 'Release', 'Store'}, 'missing Store configuration')
        if is_controls:
            require(not target['dependencies'], 'controls depend on another target')
            require(all('SCROLLSTITCH_CONTROLS' in v.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
                        and v.get('APPLICATION_EXTENSION_API_ONLY') == 'YES' for v in modes.values()),
                    'controls capability configuration drift')
            require(modes['Store'].get('SCROLLSTITCH_EDITION') == 'appStore', 'Store controls edition mismatch')
            require(modes['Store'].get('MARKETING_VERSION') == '1.0.0' and modes['Store'].get('CURRENT_PROJECT_VERSION') == '1', 'Store controls version mismatch')
            continue
        require('SCROLLSTITCH_STORE' in modes['Store'].get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split(), 'Store compiler gate missing')
        require(modes['Store']['SWIFT_OPTIMIZATION_LEVEL'] == '-O', 'Store must use Release optimization')
        if is_store:
            for settings in modes.values():
                flags = settings.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split()
                require('SCROLLSTITCH_STORE' in flags and 'SCROLLSTITCH_COLLAGE_ONLY' not in flags, 'full Store capability gate drift')
                require(settings.get('SCROLLSTITCH_EDITION') == 'appStore', 'Store edition metadata missing')
                require(settings.get('MARKETING_VERSION') == '1.0.0' and settings.get('CURRENT_PROJECT_VERSION') == '1', 'local candidate version drift')
            require(set(p.relative_to(root).as_posix() for p in (root/'Resources/Holidays').glob('*.json')).issubset(refs), 'Store annual data missing')
        else:
            require(all('SCROLLSTITCH_STORE' not in modes[m].get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '') for m in ('Debug', 'Release')), 'local build modes unexpectedly changed')
            require(all('SCROLLSTITCH_COLLAGE_ONLY' not in v.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '') for v in modes.values()), 'developer capture capability changed')
        require(len(target['dependencies']) == 1 and
                project[project[target['dependencies'][0]]['target']]['name'] == 'ScrollControls',
                'full app must depend only on its control extension')
        copies = [project[p] for p in target['buildPhases'] if project[p]['isa'] == 'PBXCopyFilesBuildPhase']
        require(len(copies) == 1 and len(copies[0]['files']) == 1 and
                project[project[copies[0]['files'][0]]['fileRef']]['path'] == 'ScrollControls.appex',
                'full app must embed only its control extension')
    subprocess.run([sys.executable, str(root / 'scripts/generate_project.py'), '--check'], check=True, stdout=subprocess.PIPE)
    return {'privacy_targets': sorted(expected), 'original_icon': 'opaque 1024x1024 RGB', 'project': 'generated resources current'}

def source_digest(root=ROOT):
    """Bind the bundle to build inputs, including uncommitted code/resources, not evidence logs."""
    digest = hashlib.sha256()
    paths = [root / 'Package.swift', root / 'Config/Base.xcconfig', root / 'scripts/generate_project.py']
    for folder in ('App', 'Sources', 'Shared', 'Controls', 'Resources', 'ScrollStitch.xcodeproj'):
        paths += [p for p in (root / folder).rglob('*') if p.is_file() and 'xcuserdata' not in p.parts and not p.name.startswith('.')]
    for path in sorted(paths):
        digest.update(path.relative_to(root).as_posix().encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def public_https(value):
    if not isinstance(value, str) or value != value.strip() or any(ord(c) < 32 for c in value) or "\\" in value:
        return False
    try:
        url = urlsplit(value)
        host = (url.hostname or '').lower()
        return (url.scheme == 'https' and url.username is None and url.password is None and url.port in (None, 443)
                and '.' in host and ':' not in host and not host.endswith('.') and not re.fullmatch(r'[0-9.]+', host)
                and not any(host == x or host.endswith('.' + x) for x in ('localhost','local','internal','test','invalid','example','example.com','example.org','example.net')))
    except ValueError:
        return False


def product_check(product):
    require(product['schemaVersion'] == 1, 'unsupported ProductInfo schema')
    require(product['policyVersion'] and product['effectiveDate'] and product['sections'], 'incomplete offline product info')
    date.fromisoformat(product['effectiveDate'])
    require(all(s['title'].strip() and s['body'].strip() for s in product['sections']), 'empty privacy text')
    for key in ('supportURL', 'privacyURL'):
        require(product.get(key) is None or public_https(product[key]), 'unsafe or placeholder ' + key)


def store_bundle_check(app, info):
    """Require the full release edition, independent of the bundle filename."""
    require(info.get('ScrollStitchEdition') == 'appStore', 'not an App Store candidate')
    require(info.get('CFBundleDisplayName') == '卷轴', 'unexpected App name')
    require(len(list(Path(app).rglob('*.appex'))) == 1, 'Store candidate must contain exactly one control extension')
    require('NSExtension' not in info, 'App declares an extension entry')
    require(info.get('NSScreenCaptureUsageDescription'), 'Store capture permission missing')
    require(info.get('NSAlarmKitUsageDescription'), 'Store alarm permission missing')
    require(list(Path(app).glob('*.v*.json')), 'Store annual alarm data missing')
    require(info.get('UIBackgroundModes') == ['screen-capture','processing','fetch'], 'Store background modes mismatch')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'export compliance declaration missing')
    require(info.get('CFBundleShortVersionString') == '1.0.0' and info.get('CFBundleVersion') == '1', 'local candidate version drift')


def local_check(app, root=ROOT):
    result = resource_check(root)
    app = Path(app).resolve()
    require(app.is_dir() and app.suffix == '.app', 'actual .app bundle required')
    app_info = read_plist(app / 'Info.plist')
    store_bundle_check(app, app_info)
    from check_native_package import check as native_check
    native_check(app, edition='appStore')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    digest = source_digest(root)
    require(app_info.get('M0BuildConfiguration') == 'Store', 'not Store configuration')
    require(app_info.get('M0BuildRevision') == revision, 'revision differs from HEAD')
    require(app_info.get('ScrollStitchSourceDigest') == digest, 'source digest differs from current build inputs')
    require(app_info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'not an iOS device product')
    require(app_info.get('MinimumOSVersion') == '27.0', 'minimum OS changed without approval')
    for key in ('NSMicrophoneUsageDescription', 'NSCameraUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSUserTrackingUsageDescription'):
        require(key not in app_info, f'unexpected App permission {key}')
    require(read_plist(app / 'PrivacyInfo.xcprivacy') == read_plist(root / 'App/PrivacyInfo.xcprivacy'), 'packaged privacy manifest differs')
    executable = app_info['CFBundleExecutable']
    require(Path(executable).name == executable and (app / executable).is_file(), 'missing executable')
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(app / executable)], text=True).split()
    require('arm64' in archs, 'App lacks arm64')
    require(str(app_info.get('ScrollStitchAppGroup', '')).startswith('group.') and '$(' not in app_info['ScrollStitchAppGroup'], 'unresolved App Group')
    require(app_info.get('NSPhotoLibraryAddUsageDescription') == read_plist(root / 'App/Info.plist')['NSPhotoLibraryAddUsageDescription'], 'add-only description mismatch')
    icon = app_info['CFBundleIcons']['CFBundlePrimaryIcon']
    require(icon.get('CFBundleIconName') == 'AppIcon' and (app / 'Assets.car').stat().st_size > 0, 'compiled icon missing')
    require(icon.get('CFBundleIconFiles') and all(any(app.glob(name + '*.png')) for name in icon['CFBundleIconFiles']), 'compiled icon images missing')
    require((app / 'ProductInfo.json').read_bytes() == (root / 'Resources/Store/ProductInfo.json').read_bytes(), 'wrong edition ProductInfo packaged')
    product = json.loads((app / 'ProductInfo.json').read_text())
    product_check(product)
    forbidden = {'.artifacts', 'Documents', 'operator-fixtures', 'frames', '.harness', 'Local.xcconfig'}
    require(not any(forbidden.intersection(p.relative_to(app).parts) for p in app.rglob('*')), 'private/operator files included in bundle')
    executable = app / app_info['CFBundleExecutable']
    return {**result, 'build_revision': revision, 'source_digest': digest, 'configuration': 'Store', 'edition': 'appStore', 'extensions': 1,
            'version': app_info['CFBundleShortVersionString'] + ' (' + app_info['CFBundleVersion'] + ')',
            'bundle_id': app_info['CFBundleIdentifier'], 'boundary': 'unsigned local archive structure; no distribution entitlement or UI/runtime claim'}


DECISIONS = ('product_scope', 'quality_evidence', 'distribution_account', 'signing', 'identity_name',
             'languages_regions_pricing', 'support_channel', 'store_copy', 'screenshots', 'icon_review',
             'age_rating', 'export_compliance', 'app_privacy', 'upload_approval')
DECISIONS += ('mainland_filing', 'artwork_rights', 'runtime_acceptance')

def distribution_blockers(product, decisions, revision, digest):
    """Validate declarations and evidence references, never claim external platform approval."""
    blockers = []
    if decisions.get('schemaVersion') != 1:
        blockers.append('unsupported decisions schema')
    for key in ('supportURL', 'privacyURL'):
        if not public_https(product.get(key)):
            blockers.append(key + ': missing real public HTTPS URL')
    entries = decisions.get('decisions', {})
    for name in DECISIONS:
        entry = entries.get(name, {})
        if entry.get('status') != 'confirmed':
            blockers.append(name + ': ' + str(entry.get('status', 'missing')))
            continue
        if not isinstance(entry.get('summary'), str) or not entry['summary'].strip() or not isinstance(entry.get('evidence'), list) or not entry['evidence'] or not all(isinstance(v, str) and v.strip() for v in entry['evidence']):
            blockers.append(name + ': confirmed without reviewable evidence/summary')
        try:
            reviewed = date.fromisoformat(entry.get('reviewedAt', ''))
            if reviewed > date.today():
                raise ValueError('future evidence')
        except (ValueError, TypeError):
            blockers.append(name + ': missing/invalid review date')
        if name in ('quality_evidence', 'signing', 'screenshots', 'app_privacy', 'upload_approval'):
            if entry.get('revision') != revision or entry.get('sourceDigest') != digest:
                blockers.append(name + ': evidence not bound to this build')
    return blockers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['resources', 'local', 'distribution'], required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--decisions', type=Path)
    args = parser.parse_args()
    try:
        if args.mode == 'resources':
            result = resource_check()
        else:
            require(args.app is not None, '--app is required')
            result = local_check(args.app)
        if args.mode == 'distribution':
            require(args.decisions is not None, '--decisions is required')
            decisions = json.loads(args.decisions.read_text())
            product = json.loads((args.app / 'ProductInfo.json').read_text())
            blockers = distribution_blockers(product, decisions, result['build_revision'], result['source_digest'])
            result['blockers'] = blockers
            result['boundary'] = 'declared evidence check only; human review and Apple distribution validation still required'
            if blockers:
                print(json.dumps({'status': 'blocked', **result}, ensure_ascii=False))
                return 1
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps({'status': 'passed', **result}, ensure_ascii=False))
    return 0

if __name__ == '__main__':
    sys.exit(main())
