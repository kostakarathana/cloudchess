from pathlib import Path
import hashlib,plistlib
ROOT=Path(__file__).resolve().parents[1]
def uid(s):return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
objects={}
def obj(name,value):objects[uid(name)]=value;return uid(name)
files=sorted((ROOT/'CloudChess').glob('*.swift'))
refs=[];builds=[]
for p in files:
 ref=obj(str(p.name),f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {p.name}; sourceTree = "<group>";');refs.append(ref)
 builds.append(obj('build'+p.name,f'isa = PBXBuildFile; fileRef = {ref};'))
assetref=obj('assets','isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
refs.append(assetref)
assetbuild=obj('assetbuild',f'isa = PBXBuildFile; fileRef = {assetref};')
testref=obj('uitest','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CloudChessUITests.swift; sourceTree = "<group>";')
testbuild=obj('testbuild',f'isa = PBXBuildFile; fileRef = {testref};')
app=obj('app','isa = PBXFileReference; explicitFileType = wrapper.application; path = CloudChess.app; sourceTree = BUILT_PRODUCTS_DIR;')
testapp=obj('testapp','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CloudChessUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
source=obj('sources','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+'); runOnlyForDeploymentPostprocessing = 0;')
framework=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
resources=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assetbuild}); runOnlyForDeploymentPostprocessing = 0;')
sg=obj('sourcegroup','isa = PBXGroup; children = ('+','.join(refs)+'); path = CloudChess; sourceTree = "<group>";')
tg=obj('testgroup',f'isa = PBXGroup; children = ({testref}); path = CloudChessUITests; sourceTree = "<group>";')
pg=obj('products',f'isa = PBXGroup; children = ({app},{testapp}); name = Products; sourceTree = "<group>";')
mg=obj('main',f'isa = PBXGroup; children = ({sg},{tg},{pg}); sourceTree = "<group>";')
appcfg=[];projcfg=[];testcfg=[]
for name in ['Debug','Release']:
 common='SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES;'
 projcfg.append(obj('proj'+name,f'isa = XCBuildConfiguration; buildSettings = {{{common}}}; name = {name};'))
 settings=common+' ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; PRODUCT_BUNDLE_IDENTIFIER = com.maroon.CloudChess; PRODUCT_NAME = "$(TARGET_NAME)"; INFOPLIST_FILE = CloudChess/Info.plist; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0; ENABLE_USER_SCRIPT_SANDBOXING = YES; SWIFT_OPTIMIZATION_LEVEL = '+('"-Onone"' if name=='Debug' else '"-O"')+';'
 if name=='Debug':settings+=' SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
 appcfg.append(obj('app'+name,f'isa = XCBuildConfiguration; buildSettings = {{{settings}}}; name = {name};'))
 testcfg.append(obj('test'+name,f'isa = XCBuildConfiguration; buildSettings = {{{common} GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = com.maroon.CloudChessUITests; PRODUCT_NAME = "$(TARGET_NAME)"; TEST_TARGET_NAME = CloudChess; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic;}}; name = {name};'))
def cfg(n,cs):return obj(n,'isa = XCConfigurationList; buildConfigurations = ('+','.join(cs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
ac=cfg('appcfg',appcfg);pc=cfg('projcfg',projcfg);tc=cfg('testcfg',testcfg)
appTarget=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {ac}; buildPhases = ({source},{framework},{resources}); buildRules = (); dependencies = (); name = CloudChess; productName = CloudChess; productReference = {app}; productType = "com.apple.product-type.application";')
testsource=obj('testsources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuild}); runOnlyForDeploymentPostprocessing = 0;')
proxy=obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {appTarget}; remoteInfo = CloudChess;')
dep=obj('dep',f'isa = PBXTargetDependency; target = {appTarget}; targetProxy = {proxy};')
testTarget=obj('testtarget',f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({testsource}); buildRules = (); dependencies = ({dep}); name = CloudChessUITests; productName = CloudChessUITests; productReference = {testapp}; productType = "com.apple.product-type.bundle.ui-testing";')
proj=obj('project',f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660;}}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {mg}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({appTarget},{testTarget});')
(ROOT/'CloudChess.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(k+' = {'+v+'};\n' for k,v in objects.items())+'}; rootObject = '+proj+';}\n')
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{appTarget}" BuildableName="CloudChess.app" BlueprintName="CloudChess" ReferencedContainer="container:CloudChess.xcodeproj"/>'
tref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testTarget}" BuildableName="CloudChessUITests.xctest" BlueprintName="CloudChessUITests" ReferencedContainer="container:CloudChess.xcodeproj"/>'
(ROOT/'CloudChess.xcodeproj/xcshareddata/xcschemes/CloudChess.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2660" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{tref}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
info={'CFBundleDisplayName':'CloudChess','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'$(PRODUCT_NAME)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','UILaunchScreen':{},'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True},'NSLocalNetworkUsageDescription':'Connect to your Chess Lab engine for legal moves and Stockfish replies.'}
(ROOT/'CloudChess/Info.plist').write_bytes(plistlib.dumps(info))
