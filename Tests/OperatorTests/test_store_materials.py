"""Protect submission text and publication state from misleading output."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from check_store_materials import check
from prepare_store_site import render

class StoreMaterialsTests(unittest.TestCase):
    def testPrivateReviewPhoneCannotEnterPublicMetadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copytree(ROOT/'docs/app-store',root/'docs/app-store')
            shutil.copytree(ROOT/'Resources',root/'Resources')
            path=root/'docs/app-store/metadata.zh-Hans.json'
            metadata=json.loads(path.read_text())
            metadata['reviewContact']['phone']='+8613800000000'
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError,'Private review phone'):check(root)

    def testPreparedAssetsAndFieldLimits(self):
        self.assertEqual(check()['pages'],3)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copytree(ROOT/'docs/app-store',root/'docs/app-store')
            shutil.copytree(ROOT/'Resources',root/'Resources')
            path=root/'docs/app-store/metadata.zh-Hans.json'
            metadata=json.loads(path.read_text()); metadata['keywords']='截'*34
            path.write_text(json.dumps(metadata))
            with self.assertRaisesRegex(ValueError,'100 bytes'):check(root)

    def testPolicyRenderingEscapesUserText(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copytree(ROOT/'docs/app-store',root/'docs/app-store')
            shutil.copytree(ROOT/'Resources',root/'Resources')
            path=root/'Resources/Store/ProductInfo.json'
            policy=json.loads(path.read_text()); policy['sections'][0]['body']='<script>alert(1)</script>'
            path.write_text(json.dumps(policy))
            text=render(root)['privacy.html']
            self.assertIn('&lt;script&gt;',text)
            self.assertNotIn('<script>',text)

    def testUnpublishedURLsCannotBeExposedInApp(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copytree(ROOT/'docs/app-store',root/'docs/app-store')
            shutil.copytree(ROOT/'Resources',root/'Resources')
            metadata_path=root/'docs/app-store/metadata.zh-Hans.json'
            metadata=json.loads(metadata_path.read_text());metadata['publicURLStatus']='not_published_or_verified'
            metadata_path.write_text(json.dumps(metadata))
            for name in ('Resources/ProductInfo.json','Resources/Store/ProductInfo.json'):
                path=root/name; policy=json.loads(path.read_text())
                policy['privacyURL']='https://lmjian.github.io/apps/scrollstitch/privacy.html'
                path.write_text(json.dumps(policy))
            with self.assertRaisesRegex(ValueError,'Unverified URL'):check(root)

    def testPublishedLinksMustMatchVerifiedPages(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            shutil.copytree(ROOT/'docs/app-store',root/'docs/app-store')
            shutil.copytree(ROOT/'Resources',root/'Resources')
            metadata_path=root/'docs/app-store/metadata.zh-Hans.json'
            metadata=json.loads(metadata_path.read_text());metadata['publicURLStatus']='published_and_verified'
            metadata_path.write_text(json.dumps(metadata))
            for name in ('Resources/ProductInfo.json','Resources/Store/ProductInfo.json'):
                path=root/name;policy=json.loads(path.read_text());policy['privacyURL']='https://lmjian.github.io/wrong.html'
                path.write_text(json.dumps(policy))
            with self.assertRaisesRegex(ValueError,'Published app links'):check(root)
