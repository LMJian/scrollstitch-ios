#!/usr/bin/env python3
"""Inspect the real developer bundle, including a Debug configuration's split dylib."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def check(app, edition='developer'):
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['MinimumOSVersion'] == '27.0', 'native app must require iOS 27'
    assert info['ScrollStitchEdition'] == edition
    assert info['UIBackgroundModes'] == ['screen-capture','processing','fetch']
    assert info['BGTaskSchedulerPermittedIdentifiers']==[info['CFBundleIdentifier']+'.finish-scroll',info['CFBundleIdentifier']+'.refresh-alarms']
    assert info['NSAlarmKitUsageDescription']
    from check_alarm_data import check as check_alarm_data
    check_alarm_data(app)
    assert info['NSScreenCaptureUsageDescription']
    extensions=list(app.rglob('*.appex'))
    assert len(extensions)==1, 'expected only the WidgetKit control extension'
    controls=plistlib.loads((extensions[0]/'Info.plist').read_bytes())
    assert controls['NSExtension']['NSExtensionPointIdentifier']=='com.apple.widgetkit-extension'
    assert controls['CFBundleIdentifier']==info['CFBundleIdentifier']+'.controls'
    assert info['NSSupportsLiveActivities'] is True
    assert controls['MinimumOSVersion']=='27.0'
    assert controls['CFBundleShortVersionString']==info['CFBundleShortVersionString'], 'extension marketing version mismatch'
    assert controls['CFBundleVersion']==info['CFBundleVersion'], 'extension build version mismatch'
    assert controls['ScrollStitchEdition']==edition, 'extension edition mismatch'
    assert 'NSExtension' not in info
    for key in ('NSMicrophoneUsageDescription', 'NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription'):
        assert key not in info, 'unexpected permission: ' + key
    executable = app / info['CFBundleExecutable']
    binaries = [executable, *app.glob('*.dylib'),extensions[0]/controls['CFBundleExecutable'],*extensions[0].glob('*.dylib')]
    loads = '\n'.join(subprocess.check_output(['xcrun', 'otool', '-L', str(binary)], text=True) for binary in binaries)
    assert 'ScreenCaptureKit.framework/ScreenCaptureKit' in loads, 'SCK not linked into actual app'
    assert 'AlarmKit.framework/AlarmKit' in loads, 'AlarmKit not linked into actual app'
    assert 'ReplayKit.framework/ReplayKit' not in loads, 'legacy capture framework still linked'
    return {'status': 'passed', 'edition': edition, 'minimumOS': info['MinimumOSVersion'], 'version': info['CFBundleVersion'],
            'backend': 'ScreenCaptureKit', 'embeddedExtensions': 1, 'extensionType':'WidgetKit', 'replayKitLinked': False,
            'boundary': 'actual bundle structure/linkage; not system consent or runtime capture'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True)
    print(json.dumps(check(parser.parse_args().app)))
