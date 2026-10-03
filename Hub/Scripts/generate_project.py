"""標準ライブラリーだけで本番用Xcodeプロジェクトを生成します。"""
from pathlib import Path
import plistlib, hashlib
root=Path(__file__).resolve().parents[1]
objects={}
def ident(s): return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def add(key,**values):
    i=ident(key); objects[i]=values; return i
files=[];sources=[]
for p in sorted((root/'App').glob('*.swift')):
    ref=add(str(p.name),isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='App/'+p.name,sourceTree='<group>')
    files.append(ref);sources.append(add('build'+p.name,isa='PBXBuildFile',fileRef=ref))
config=root/'Configuration';config.mkdir(exist_ok=True)
connection=config/'Connection.plist'
if not connection.exists(): connection.write_bytes(plistlib.dumps({'GoogleClientID':'','DeploymentID':'','Scopes':[]}))
local=config/'Local.xcconfig'
if not local.exists():local.write_text('PHH_BUNDLE_ID = jp.personalhealthhub.app\nGOOGLE_REVERSED_CLIENT_ID = phh-unconfigured\nDEVELOPMENT_TEAM =\n')
info={'CFBundleDisplayName':'Personal Health Hub','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleName':'$(PRODUCT_NAME)','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1','CFBundleVersion':'5','NSCameraUsageDescription':'食事の写真を撮影し、確認後に解析するために使います。','NSHealthShareUsageDescription':'体重・体脂肪率・BMI・除脂肪体重・歩数・活動と安静時の消費エネルギー・睡眠を読み取り、健康記録の確認と振り返りに使います。','LSRequiresIPhoneOS':True,'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False},'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'CFBundleURLTypes':[{'CFBundleURLSchemes':['$(GOOGLE_REVERSED_CLIENT_ID)']}]}
(root/'App/Info.plist').write_bytes(plistlib.dumps(info))
# 検証済みの認証処理だけを共有。検証アプリの設定・保存領域は共有しない。
ref=add('ChatGPTPlan.swift',isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='../Probe/Core/Sources/PHHProbeCore/ChatGPTPlan.swift',sourceTree='<group>')
files.append(ref);sources.append(add('buildChatGPTPlan.swift',isa='PBXBuildFile',fileRef=ref))
cref=add('connection',isa='PBXFileReference',lastKnownFileType='text.plist.xml',path='Configuration/Connection.plist',sourceTree='<group>')
xref=add('xcconfig',isa='PBXFileReference',lastKnownFileType='text.xcconfig',path='Configuration/Local.xcconfig',sourceTree='<group>')
res=add('res',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=[add('resbuild',isa='PBXBuildFile',fileRef=cref)],runOnlyForDeploymentPostprocessing=0)
remote=add('google',isa='XCRemoteSwiftPackageReference',repositoryURL='https://github.com/google/GoogleSignIn-iOS',requirement={'kind':'exactVersion','version':'10.0.0'})
localp=add('core',isa='XCLocalSwiftPackageReference',relativePath='Core')
products=[];frameworks=[]
for name,package in [('PHHHubCore',localp),('GoogleSignIn',remote),('GoogleSignInSwift',remote)]:
    dep=add('dep'+name,isa='XCSwiftPackageProductDependency',package=package,productName=name);products.append(dep)
    frameworks.append(add('fw'+name,isa='PBXBuildFile',productRef=dep))
fw=add('frameworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=frameworks,runOnlyForDeploymentPostprocessing=0)
src=add('sources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=sources,runOnlyForDeploymentPostprocessing=0)
product=add('product',isa='PBXFileReference',explicitFileType='wrapper.application',path='PHHHub.app',sourceTree='BUILT_PRODUCTS_DIR')
pg=add('products',isa='PBXGroup',children=[product],name='Products',sourceTree='<group>')
group=add('main',isa='PBXGroup',children=files+[cref,xref,pg],sourceTree='<group>')
configs=[];projectconfigs=[]
for name in ['Debug','Release']:
    bs={'PRODUCT_NAME':'PHHHub','PRODUCT_BUNDLE_IDENTIFIER':'$(PHH_BUNDLE_ID)','INFOPLIST_FILE':'App/Info.plist','IPHONEOS_DEPLOYMENT_TARGET':'26.0','SWIFT_VERSION':'6.0','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','CODE_SIGN_ENTITLEMENTS':'App/PHHHub.entitlements','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SDKROOT':'iphoneos','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if name=='Debug' else '-O','GENERATE_INFOPLIST_FILE':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks']}
    configs.append(add('target'+name,isa='XCBuildConfiguration',name=name,buildSettings=bs,baseConfigurationReference=xref))
    projectconfigs.append(add('project'+name,isa='XCBuildConfiguration',name=name,buildSettings={'CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES','DEBUG_INFORMATION_FORMAT':'dwarf','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if name=='Debug' else ''}))
cl=add('targetconfigs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
pcl=add('projectconfigs',isa='XCConfigurationList',buildConfigurations=projectconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
target=add('target',isa='PBXNativeTarget',buildConfigurationList=cl,buildPhases=[src,fw,res],buildRules=[],dependencies=[],name='PHHHub',packageProductDependencies=products,productName='PHHHub',productReference=product,productType='com.apple.product-type.application')
testfiles=[];testsources=[]
for p in sorted((root/'UITests').glob('*.swift')):
    r=add('uitest'+p.name,isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='UITests/'+p.name,sourceTree='<group>')
    testfiles.append(r);testsources.append(add('uitestbuild'+p.name,isa='PBXBuildFile',fileRef=r))
testproduct=add('uitestproduct',isa='PBXFileReference',explicitFileType='wrapper.cfbundle',path='PHHHubUITests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
objects[pg]['children'].append(testproduct);objects[group]['children']+=testfiles
testconfigs=[add('uitest'+n,isa='XCBuildConfiguration',name=n,buildSettings={'PRODUCT_NAME':'PHHHubUITests','PRODUCT_BUNDLE_IDENTIFIER':'jp.personalhealthhub.app.uitests','GENERATE_INFOPLIST_FILE':'YES','IPHONEOS_DEPLOYMENT_TARGET':'26.0','SWIFT_VERSION':'6.0','SDKROOT':'iphoneos','SUPPORTED_PLATFORMS':'iphonesimulator','TARGETED_DEVICE_FAMILY':'1','TEST_TARGET_NAME':'PHHHub','CODE_SIGNING_ALLOWED':'NO'}) for n in ['Debug','Release']]
testcl=add('uitestconfigs',isa='XCConfigurationList',buildConfigurations=testconfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
testsrc=add('uitestsources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=testsources,runOnlyForDeploymentPostprocessing=0)
proxy=add('uitestproxy',isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=target,remoteInfo='PHHHub')
dependency=add('uitestdependency',isa='PBXTargetDependency',target=target,targetProxy=proxy)
testtarget=add('uitesttarget',isa='PBXNativeTarget',buildConfigurationList=testcl,buildPhases=[testsrc],buildRules=[],dependencies=[dependency],name='PHHHubUITests',productName='PHHHubUITests',productReference=testproduct,productType='com.apple.product-type.bundle.ui-testing')
project=add('project',isa='PBXProject',attributes={'LastUpgradeCheck':'2700','TargetAttributes':{testtarget:{'TestTargetID':target}}},buildConfigurationList=pcl,compatibilityVersion='Xcode 14.0',developmentRegion='ja',hasScannedForEncodings=0,knownRegions=['ja','en','Base'],mainGroup=group,productRefGroup=pg,projectDirPath='',projectRoot='',targets=[target,testtarget],packageReferences=[localp,remote])
proj=root/'PHHHub.xcodeproj';proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project},sort_keys=False))
scheme=proj/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="PHHHub.app" BlueprintName="PHHHub" ReferencedContainer="container:PHHHub.xcodeproj"/>'
testref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{testtarget}" BuildableName="PHHHubUITests.xctest" BlueprintName="PHHHubUITests" ReferencedContainer="container:PHHHub.xcodeproj"/>'
(scheme/'PHHHub.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{testref}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(proj)
