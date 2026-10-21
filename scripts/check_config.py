"""Check real build/privacy boundaries; this does not certify runtime privacy."""
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
def read(name):
    with (root / name).open('rb') as f:
        return plistlib.load(f)

app = read('App/Info.plist')
store = read('App/Info-Store.plist')
assert app['UIBackgroundModes'] == ['screen-capture','processing','fetch']
assert app['BGTaskSchedulerPermittedIdentifiers']==['$(PRODUCT_BUNDLE_IDENTIFIER).finish-scroll','$(PRODUCT_BUNDLE_IDENTIFIER).refresh-alarms']
assert app['NSAlarmKitUsageDescription']
assert 'NSAlarmKitUsageDescription' not in store
assert app['NSScreenCaptureUsageDescription']
assert app['NSSupportsLiveActivities']
controls=read('Controls/Info.plist')
assert controls['NSExtension']=={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}
assert read('Controls/ScrollStitch.entitlements')==read('App/ScrollStitch.entitlements')
assert 'UIBackgroundModes' not in store
assert 'NSScreenCaptureUsageDescription' not in store
assert read('App/ScrollStitch.entitlements') == {'com.apple.security.application-groups': ['$(SCROLLSTITCH_APP_GROUP)']}
assert not list((root / 'BroadcastExtension').glob('*'))
assert 'IPHONEOS_DEPLOYMENT_TARGET = 27.0' in (root / 'Config/Base.xcconfig').read_text()
for path in ['App/Info.plist', 'App/Info-Store.plist', 'Controls/Info.plist']:
    keys = read(path)
    assert not any(k in keys for k in ['NSMicrophoneUsageDescription', 'NSCameraUsageDescription',
        'NSLocationWhenInUseUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSUserTrackingUsageDescription'])
assert app['NSPhotoLibraryAddUsageDescription'] == '用于将你生成的长图或拼图保存到相册'
assert app['UISupportedInterfaceOrientations'] == ['UIInterfaceOrientationPortrait']
print('PASS: native/Store capability isolation, iOS 27-only entry, App Group, portrait and minimal permissions')
