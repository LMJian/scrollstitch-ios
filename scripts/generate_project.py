"""Generate a small dependency-free Xcode project; no accounts or GUI operations."""
import hashlib
import json
import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = sys.argv[1:] == ["--check"]
if sys.argv[1:] and not CHECK:
    raise SystemExit("Usage: generate_project.py [--check]")
def emit(path, data):
    p = ROOT / path
    data = data.encode() if isinstance(data, str) else data
    if CHECK:
        if not p.exists() or p.read_bytes() != data:
            raise SystemExit(f"Generated file differs: {path}")
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

objects = {}
def key(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(identity, isa, **fields):
    ident = key(identity)
    objects[ident] = dict(isa=isa, **fields)
    return ident
def encode(v):
    if isinstance(v, dict):
        return '{\n' + '\n'.join(f'{json.dumps(k)} = {encode(x)};' for k, x in v.items()) + '\n}'
    if isinstance(v, list):
        return '(' + ','.join(encode(x) for x in v) + ')'
    return json.dumps(str(v), ensure_ascii=False)
def plist(path, data):
    emit(path, plistlib.dumps(data, sort_keys=False))

base_info = {
    'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)',
    'CFBundleName': '$(PRODUCT_NAME)', 'CFBundleShortVersionString': '$(MARKETING_VERSION)',
    'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)', 'CFBundleDevelopmentRegion': 'zh_CN',
    'ScrollStitchAppGroup': '$(SCROLLSTITCH_APP_GROUP)',
    'M0BuildRevision': '$(SCROLLSTITCH_BUILD_REVISION)', 'M0BuildConfiguration': '$(CONFIGURATION)',
    'ScrollStitchSourceDigest': '$(SCROLLSTITCH_SOURCE_DIGEST)',
    'ScrollStitchEdition': '$(SCROLLSTITCH_EDITION)',
}
app_info = dict(base_info, CFBundleDisplayName='卷轴', CFBundlePackageType='APPL',
    LSRequiresIPhoneOS=True, NSPhotoLibraryAddUsageDescription='用于将你生成的长图或拼图保存到相册', UILaunchScreen={}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait'])
full_app_info = dict(app_info, NSScreenCaptureUsageDescription='用于录制你选择共享的屏幕，在本机生成滚动长截图',
    NSAlarmKitUsageDescription='用于按你的工作日和调休安排设置起床闹钟，静音和专注模式下也能提醒',
    UIBackgroundModes=['screen-capture','processing','fetch'], NSSupportsLiveActivities=True,
    BGTaskSchedulerPermittedIdentifiers=['$(PRODUCT_BUNDLE_IDENTIFIER).finish-scroll','$(PRODUCT_BUNDLE_IDENTIFIER).refresh-alarms'])
plist('App/Info.plist', full_app_info)
plist('App/Info-Store.plist', dict(full_app_info, ITSAppUsesNonExemptEncryption=False))
plist('App/ScrollStitch.entitlements', {'com.apple.security.application-groups': ['$(SCROLLSTITCH_APP_GROUP)']})
plist('Controls/Info.plist', dict(base_info, CFBundleDisplayName='卷轴控制', CFBundlePackageType='XPC!',
    NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}))
plist('Controls/ScrollStitch.entitlements', {'com.apple.security.application-groups':['$(SCROLLSTITCH_APP_GROUP)']})

config = obj('config-ref', 'PBXFileReference', lastKnownFileType='text.xcconfig', path='Config/Base.xcconfig', sourceTree='<group>')
refs = []
source_refs = {}
for folder in ('App', 'Sources', 'Shared', 'Controls'):
    for path in sorted((ROOT / folder).rglob('*.swift')):
        rel = path.relative_to(ROOT).as_posix()
        source_refs[rel] = obj(rel, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=rel, sourceTree='<group>')
        refs.append(source_refs[rel])
resource_paths = {
    'App': ['App/PrivacyInfo.xcprivacy', 'App/Assets.xcassets', 'Resources/ProductInfo.json'] +
           [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'Resources/Holidays').glob('*.json'))],
    'Store': ['App/PrivacyInfo.xcprivacy', 'App/Assets.xcassets', 'Resources/Store/ProductInfo.json'] +
             [p.relative_to(ROOT).as_posix() for p in sorted((ROOT / 'Resources/Holidays').glob('*.json'))],
    'Controls': ['Controls/PrivacyInfo.xcprivacy'],
}
resource_refs = {}
for paths in resource_paths.values():
    for rel in paths:
        if rel in resource_refs:
            continue
        resource_refs[rel] = obj(rel, 'PBXFileReference', lastKnownFileType='folder.assetcatalog' if rel.endswith('.xcassets') else 'text.json' if rel.endswith('.json') else 'text.xml', path=rel, sourceTree='<group>')
        refs.append(resource_refs[rel])
app_product = obj('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='ScrollStitch.app', sourceTree='BUILT_PRODUCTS_DIR')
store_product = obj('store-product', 'PBXFileReference', explicitFileType='wrapper.application', path='ScrollStitchStore.app', sourceTree='BUILT_PRODUCTS_DIR')
controls_product = obj('controls-product','PBXFileReference',explicitFileType='wrapper.app-extension',path='ScrollControls.appex',sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', 'PBXGroup', children=[app_product, store_product,controls_product], name='Products', sourceTree='<group>')
main_group = obj('main-group', 'PBXGroup', children=[config, *refs, products], sourceTree='<group>')

def configurations(name, settings, base=None):
    ids = []
    for mode in ('Debug', 'Release', 'Store'):
        fields = dict(buildSettings=dict(settings, SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O'), name=mode)
        if name == 'ScrollStitchStore':
            fields['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) SCROLLSTITCH_STORE'
        elif mode == 'Store' and name != 'ScrollControls':
            fields['buildSettings']['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = '$(inherited) SCROLLSTITCH_STORE'
        if name == 'ScrollControls' and mode == 'Store':
            fields['buildSettings'].update(MARKETING_VERSION='1.0.0', CURRENT_PROJECT_VERSION='1',
                SCROLLSTITCH_EDITION='appStore',
                SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SCROLLSTITCH_CONTROLS SCROLLSTITCH_STORE')
        if base:
            fields['baseConfigurationReference'] = base
        ids.append(obj(f'{name}-{mode}', 'XCBuildConfiguration', **fields))
    return obj(f'{name}-configs', 'XCConfigurationList', buildConfigurations=ids, defaultConfigurationIsVisible='0', defaultConfigurationName='Release')

project_configs = configurations('project', {'CLANG_ENABLE_MODULES':'YES', 'SDKROOT':'iphoneos'}, config)
for name, folder, product, bundle_suffix in (
    ('ScrollStitch', 'App', app_product, 'app'),
    ('ScrollStitchStore', 'App', store_product, 'app'),
    ('ScrollControls','Controls',controls_product,'app.controls'),
):
    files = []
    for rel, ref in source_refs.items():
        if (rel.startswith(folder + '/') or
            (folder == 'App' and rel.startswith('Sources/')) or
            rel.startswith('Shared/')):
            files.append(obj(name + '-' + rel, 'PBXBuildFile', fileRef=ref))
    phase = obj(name+'-sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=files, runOnlyForDeploymentPostprocessing='0')
    frameworks = obj(name+'-frameworks', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
    resource_files = [obj(name+'-'+rel, 'PBXBuildFile', fileRef=resource_refs[rel]) for rel in resource_paths.get('Store' if name == 'ScrollStitchStore' else folder,[])]
    resources = obj(name+'-resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=resource_files, runOnlyForDeploymentPostprocessing='0')
    settings = {
        'PRODUCT_NAME': name, 'PRODUCT_BUNDLE_IDENTIFIER': '$(SCROLLSTITCH_BUNDLE_PREFIX).'+bundle_suffix,
        'INFOPLIST_FILE': folder+'/Info.plist', 'CODE_SIGN_ENTITLEMENTS': folder+'/ScrollStitch.entitlements',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST':'NO',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks',
    }
    dependencies = []
    phases = [phase, frameworks, resources]
    settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
    if name == 'ScrollStitchStore':
        settings.update(SCROLLSTITCH_EDITION='appStore', MARKETING_VERSION='1.0.0', CURRENT_PROJECT_VERSION='1',
            INFOPLIST_FILE='App/Info-Store.plist')
    elif name == 'ScrollControls':
        settings.update(APPLICATION_EXTENSION_API_ONLY='YES',SKIP_INSTALL='YES',
            SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SCROLLSTITCH_CONTROLS',
            LD_RUNPATH_SEARCH_PATHS='$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks')
        settings.pop('ASSETCATALOG_COMPILER_APPICON_NAME',None)
    if name != 'ScrollControls':
        embedded=obj(name+'-embed-controls-file','PBXBuildFile',fileRef=controls_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(obj(name+'-embed-controls','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',
            files=[embedded],name='Embed Controls',runOnlyForDeploymentPostprocessing='0'))
        proxy=obj(name+'-controls-proxy','PBXContainerItemProxy',containerPortal=key('project'),proxyType='1',
            remoteGlobalIDString=key('ScrollControls'),remoteInfo='ScrollControls')
        dependencies.append(obj(name+'-controls-dependency','PBXTargetDependency',target=key('ScrollControls'),targetProxy=proxy))
    obj(name, 'PBXNativeTarget', buildConfigurationList=configurations(name, settings), buildPhases=phases,
        buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=product,
        productType='com.apple.product-type.app-extension' if name == 'ScrollControls' else 'com.apple.product-type.application')

obj('project', 'PBXProject', attributes={'LastUpgradeCheck':'2700'}, buildConfigurationList=project_configs,
    compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN', hasScannedForEncodings='0',
    knownRegions=['zh_CN','en','Base'], mainGroup=main_group, productRefGroup=products,
    projectDirPath='', projectRoot='', targets=[key('ScrollStitch'), key('ScrollStitchStore'),key('ScrollControls')])
p = ROOT / 'ScrollStitch.xcodeproj'
emit('ScrollStitch.xcodeproj/project.pbxproj', '// !$*UTF8*$!\n' + encode(dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=key('project'))) + '\n')
schemes = p / 'xcshareddata/xcschemes'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key('ScrollStitch')}" BuildableName="ScrollStitch.app" BlueprintName="ScrollStitch" ReferencedContainer="container:ScrollStitch.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key('ScrollStitch')}" BuildableName="ScrollStitch.app" BlueprintName="ScrollStitch" ReferencedContainer="container:ScrollStitch.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
emit('ScrollStitch.xcodeproj/xcshareddata/xcschemes/ScrollStitch.xcscheme', scheme)
emit('ScrollStitch.xcodeproj/xcshareddata/xcschemes/ScrollStitchStore.xcscheme', scheme.replace(key('ScrollStitch'), key('ScrollStitchStore')).replace('BuildableName="ScrollStitch.app"', 'BuildableName="ScrollStitchStore.app"').replace('BlueprintName="ScrollStitch"', 'BlueprintName="ScrollStitchStore"').replace('buildConfiguration="Debug"', 'buildConfiguration="Store"').replace('buildConfiguration="Release"', 'buildConfiguration="Store"').replace('revealArchiveInOrganizer="YES"', 'revealArchiveInOrganizer="NO"'))
print('Generated resources are current.' if CHECK else 'Generated project, resource references, scheme, Info.plists and entitlements.')
