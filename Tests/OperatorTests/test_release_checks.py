"""Negative release gates exercise missing and contradictory evidence, never mock a release."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('release_check', ROOT / 'scripts/check_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class ReleaseChecksTests(unittest.TestCase):
    def resource_tree(self, destination):
        for folder in ('App', 'Sources', 'Shared', 'Controls', 'Resources', 'ScrollStitch.xcodeproj'):
            shutil.copytree(ROOT / folder, destination / folder, ignore=shutil.ignore_patterns('xcuserdata'))
        for name in ('scripts/generate_project.py', 'docs/privacy-inventory.json'):
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)

    def testFullStorePackageRejectsMissingFeaturesAndWrongEdition(self):
        info = {'ScrollStitchEdition':'appStore', 'CFBundleDisplayName':'卷轴',
                'CFBundleShortVersionString':'1.0.0', 'CFBundleVersion':'1',
                'NSScreenCaptureUsageDescription':'record', 'NSAlarmKitUsageDescription':'alarm',
                'UIBackgroundModes':['screen-capture','processing','fetch'],
                'ITSAppUsesNonExemptEncryption':False}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'exactly one control extension'):
                release.store_bundle_check(root, info)
            (root/'PlugIns/ScrollControls.appex').mkdir(parents=True)
            (root/'2026.v1.json').write_text('{}')
            release.store_bundle_check(root, info)
            for missing in ('NSScreenCaptureUsageDescription', 'NSAlarmKitUsageDescription', 'UIBackgroundModes', 'ITSAppUsesNonExemptEncryption'):
                changed=copy.deepcopy(info); changed.pop(missing)
                with self.subTest(missing=missing), self.assertRaises(ValueError):
                    release.store_bundle_check(root, changed)
            with self.assertRaisesRegex(ValueError, 'not an App Store candidate'):
                release.store_bundle_check(root, {**info, 'ScrollStitchEdition':'developer'})
            extension = root / 'PlugIns/Hidden.appex'
            extension.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'exactly one control extension'):
                release.store_bundle_check(root, info)

    def testResourcesFailForMissingManifest(self):
        for folder in ('App','Controls'):
            with self.subTest(target=folder), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.resource_tree(root)
                (root / folder / 'PrivacyInfo.xcprivacy').unlink()
                with self.assertRaises(OSError):
                    release.resource_check(root)

    def testPendingReviewAndUnknownReasonCannotPass(self):
        for field, value in [('reviewStatus', 'pending'), ('reason', 'FAKE.1')]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.resource_tree(root)
                path = root / 'docs/privacy-inventory.json'
                data = json.loads(path.read_text())
                data['entries'][0][field] = value
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    release.resource_check(root)

    def testUnconfiguredDistributionRemainsBlocked(self):
        product = json.loads((ROOT / 'Resources/ProductInfo.json').read_text())
        product.update(supportURL=None, privacyURL=None)
        decisions = {'schemaVersion': 1, 'decisions': {name: {'status': 'deferred'} for name in release.DECISIONS}}
        blockers = release.distribution_blockers(product, decisions, 'current', 'digest')
        self.assertTrue(any('supportURL' in s for s in blockers))
        self.assertTrue(any('product_scope: deferred' in s for s in blockers))
        self.assertTrue(any('upload_approval' in s for s in blockers))

    def testConfirmedBooleanOrStaleBuildIsNotEvidence(self):
        decisions = {'schemaVersion':1, 'decisions':{name: {'status':'confirmed'} for name in release.DECISIONS}}
        blockers = release.distribution_blockers({}, decisions, 'new', 'new-digest')
        self.assertTrue(any('quality_evidence: confirmed without' in s for s in blockers))
        self.assertTrue(any('signing: evidence not bound' in s for s in blockers))
        self.assertTrue(any('upload_approval: missing/invalid review date' in s for s in blockers))

    def testProductMetadataRejectsUnsafeOrFutureInput(self):
        base = json.loads((ROOT / 'Resources/ProductInfo.json').read_text())
        release.product_check(base)
        for changes in [{'schemaVersion':2}, {'privacyURL':'javascript:alert(1)'}, {'supportURL':'https://example.com'}]:
            value = copy.deepcopy(base)
            value.update(changes)
            with self.assertRaises(ValueError):
                release.product_check(value)

if __name__ == '__main__':
    unittest.main()
