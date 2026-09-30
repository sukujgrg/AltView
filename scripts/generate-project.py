#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project; no external tools or packages needed."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def ref(name): return uid(name)
def obj(key, isa, **fields):
    objects[ref(key)] = dict(isa=isa, **fields)
    return ref(key)
def quoted(value):
    if isinstance(value, dict): return '{ ' + ' '.join(f'{json.dumps(k)} = {quoted(v)};' for k,v in value.items()) + ' }'
    if isinstance(value, list): return '(' + ', '.join(quoted(v) for v in value) + (',' if value else '') + ')'
    return json.dumps(str(value))

app_sources = sorted(root.glob('AltView/**/*.swift'))
test_sources = sorted(root.glob('AltViewTests/*.swift'))
app_resources = sorted(root.glob('AltView/**/*.xcassets'))
files = []
for path in app_sources + test_sources + app_resources + [root/'AltView/Info.plist', root/'AltView/AltView.entitlements', root/'AltView/AltViewDebug.entitlements', root/'README.md', root/'VERSION']:
    rel = str(path.relative_to(root))
    typ = 'folder.assetcatalog' if path.suffix == '.xcassets' else 'sourcecode.swift' if path.suffix == '.swift' else 'text.plist.xml' if path.suffix in ('.plist', '.entitlements') else 'net.daringfireball.markdown'
    files.append(obj(rel, 'PBXFileReference', lastKnownFileType=typ, path=rel, sourceTree='SOURCE_ROOT'))
sparkle = obj('SparklePackage', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/sparkle-project/Sparkle', requirement={'kind':'exactVersion','version':'2.9.6'})
sparkle_product = obj('SparkleProduct', 'XCSwiftPackageProductDependency', package=sparkle, productName='Sparkle')
sparkle_build = obj('SparkleBuild', 'PBXBuildFile', productRef=sparkle_product)
obj('AltView:version', 'PBXShellScriptBuildPhase', buildActionMask='2147483647', files=[],
    inputPaths=['$(SRCROOT)/VERSION','$(SRCROOT)/AltView/Info.plist','$(SRCROOT)/scripts/generate-info-plist.sh'],
    outputPaths=['$(DERIVED_FILE_DIR)/AltView-Info.plist'], name='Generate versioned Info.plist',
    runOnlyForDeploymentPostprocessing='0', shellPath='/bin/bash',
    shellScript='bash "$SRCROOT/scripts/generate-info-plist.sh" "$SRCROOT/VERSION" "$SRCROOT/AltView/Info.plist" "$DERIVED_FILE_DIR/AltView-Info.plist"\n')
for target, sources in [('AltView', app_sources), ('AltViewTests', test_sources)]:
    buildfiles = []
    for path in sources:
        rel = str(path.relative_to(root))
        buildfiles.append(obj(rel+':build', 'PBXBuildFile', fileRef=ref(rel)))
    obj(target+':sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=buildfiles, runOnlyForDeploymentPostprocessing='0')
    obj(target+':frameworks', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[sparkle_build] if target == 'AltView' else [], runOnlyForDeploymentPostprocessing='0')
    resources = []
    for path in app_resources if target == 'AltView' else []:
        rel = str(path.relative_to(root))
        resources.append(obj(rel+':build', 'PBXBuildFile', fileRef=ref(rel)))
    obj(target+':resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=resources, runOnlyForDeploymentPostprocessing='0')

appProduct = obj('appProduct', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path='AltView.app', sourceTree='BUILT_PRODUCTS_DIR')
testProduct = obj('testProduct', 'PBXFileReference', explicitFileType='wrapper.cfbundle', includeInIndex='0', path='AltViewTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', 'PBXGroup', children=[appProduct,testProduct], name='Products', sourceTree='<group>')
appGroup = obj('appGroup', 'PBXGroup', children=[ref(str(p.relative_to(root))) for p in app_sources + app_resources] + [ref('AltView/Info.plist'),ref('AltView/AltView.entitlements'),ref('AltView/AltViewDebug.entitlements')], name='AltView', sourceTree='<group>')
testGroup = obj('testGroup', 'PBXGroup', children=[ref(str(p.relative_to(root))) for p in test_sources], name='AltViewTests', sourceTree='<group>')
main = obj('mainGroup', 'PBXGroup', children=[appGroup,testGroup,ref('README.md'),ref('VERSION'),products], sourceTree='<group>')

for target in ['project','AltView','AltViewTests']:
    configurations=[]
    for name in ['Debug','Release']:
        if target=='project':
            settings=dict(MACOSX_DEPLOYMENT_TARGET='12.0', SDKROOT='macosx', SWIFT_VERSION='5.0', ARCHS='$(ARCHS_STANDARD)', CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', GCC_C_LANGUAGE_STANDARD='gnu17', ENABLE_USER_SCRIPT_SANDBOXING='YES', DEBUG_INFORMATION_FORMAT='dwarf' if name=='Debug' else 'dwarf-with-dsym', ONLY_ACTIVE_ARCH='YES' if name=='Debug' else 'NO', SWIFT_OPTIMIZATION_LEVEL='-Onone' if name=='Debug' else '-O', SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if name=='Debug' else '', ENABLE_TESTABILITY='YES' if name=='Debug' else 'NO', GCC_WARN_64_TO_32_BIT_CONVERSION='YES', CLANG_WARN_DOCUMENTATION_COMMENTS='YES')
        elif target=='AltView':
            settings=dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.suku.AltView', INFOPLIST_FILE='$(DERIVED_FILE_DIR)/AltView-Info.plist', CURRENT_PROJECT_VERSION='1', ALTVIEW_SOURCE_COMMIT='development', CODE_SIGN_ENTITLEMENTS='AltView/AltViewDebug.entitlements' if name=='Debug' else 'AltView/AltView.entitlements', CODE_SIGN_IDENTITY='-' if name=='Debug' else 'Apple Development', CODE_SIGN_STYLE='Manual' if name=='Debug' else 'Automatic', DEVELOPMENT_TEAM='' if name=='Debug' else 'E5N29VFW8T', ENABLE_HARDENED_RUNTIME='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks'], SUPPORTED_PLATFORMS='macosx', COMBINE_HIDPI_IMAGES='YES')
            settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
            if name == 'Release':
                settings['ARCHS'] = 'arm64 x86_64'
        else:
            settings=dict(MACOSX_DEPLOYMENT_TARGET='14.0', PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.suku.AltViewTests', GENERATE_INFOPLIST_FILE='YES', CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual', TEST_HOST='$(BUILT_PRODUCTS_DIR)/AltView.app/Contents/MacOS/AltView', BUNDLE_LOADER='$(TEST_HOST)', LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@loader_path/../Frameworks'])
        configurations.append(obj(target+name,'XCBuildConfiguration',buildSettings=settings,name=name))
    obj(target+'configs','XCConfigurationList',buildConfigurations=configurations,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

proxy=obj('proxy','PBXContainerItemProxy',containerPortal=ref('project'),proxyType='1',remoteGlobalIDString=ref('AltViewTarget'),remoteInfo='AltView')
dependency=obj('testDependency','PBXTargetDependency',target=ref('AltViewTarget'),targetProxy=proxy)
for target,product,typ in [('AltView',appProduct,'com.apple.product-type.application'),('AltViewTests',testProduct,'com.apple.product-type.bundle.unit-test')]:
    obj(target+'Target','PBXNativeTarget',buildConfigurationList=ref(target+'configs'),buildPhases=([ref('AltView:version')] if target=='AltView' else []) + [ref(target+':sources'),ref(target+':frameworks'),ref(target+':resources')],buildRules=[],dependencies=[dependency] if target=='AltViewTests' else [],name=target,productName=target,productReference=product,productType=typ,packageProductDependencies=[sparkle_product] if target=='AltView' else [])
obj('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2700','TargetAttributes':{ref('AltViewTarget'):{'CreatedOnToolsVersion':'27.0'},ref('AltViewTestsTarget'):{'CreatedOnToolsVersion':'27.0','TestTargetID':ref('AltViewTarget')}}},buildConfigurationList=ref('projectconfigs'),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=main,productRefGroup=products,projectDirPath='',projectRoot='',packageReferences=[sparkle],targets=[ref('AltViewTarget'),ref('AltViewTestsTarget')])
text='// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n'
for key,value in objects.items(): text+='\t\t'+key+' = '+quoted(value)+';\n'
text+='\t};\n\trootObject = '+ref('project')+';\n}\n'
(root/'AltView.xcodeproj/project.pbxproj').write_text(text)
appref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("AltViewTarget")}" BuildableName="AltView.app" BlueprintName="AltView" ReferencedContainer="container:AltView.xcodeproj"/>'
testref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ref("AltViewTestsTarget")}" BuildableName="AltViewTests.xctest" BlueprintName="AltViewTests" ReferencedContainer="container:AltView.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{testref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(root/'AltView.xcodeproj/xcshareddata/xcschemes/AltView.xcscheme').write_text(scheme)
print('Generated AltView.xcodeproj')
