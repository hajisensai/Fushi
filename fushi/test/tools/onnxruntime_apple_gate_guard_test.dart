// 守卫：flutter_onnxruntime vendored fork 必须在 **五端**（含 Apple）都接上
// native，且 Apple 端走 CocoaPods、部署目标与 podspec 下限严格对齐。
//
// 背景（本守卫 2026-08-14 整个反转）：
//
// 旧不变式是「fork 必须 gate 出 Apple」。当时的理由写着「上游 Apple podspec 把
// onnxruntime-objc 钉在 1.23，强制 macOS 14.0 / iOS 16.0」——那个归因是错的。
// 1.23.0 这个 **pod** 本身只要求 iOS 15.1 / macOS 13.4；14.0/16.0 来自上游随
// podspec 一起发的 `Package.swift`，它经 SwiftPM 拉进
// onnxruntime-swift-package-manager，而那个包的清单写死 `.macOS(.v14)`。本项目
// macOS Runner 用 FlutterGeneratedPluginSwiftPackage，于是整个 app 被拖到 14.0，
// "Build Desktop" macOS job 就炸了。
//
// 现在的 fork 改成删掉两个 Apple `Package.swift`，Flutter 回落到 podspec ->
// CocoaPods，真实下限降回 iOS 15.1 / macOS 13.4，项目部署目标已抬到该下限，
// iOS/macOS 的本地漫画 OCR 因此打开（见 third_party/flutter_onnxruntime/PATCHES.md）。
//
// 本守卫钉住这条链上**每一个**会静默复破的环节：任一环单独漂移，要么 Apple
// 本地 OCR 悄悄消失（回到 MissingPluginException），要么 pod install 直接失败。
// 纯 dart:io，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/workspace_pubspec.dart';

/// 从当前 cwd 向上找含 `third_party/flutter_onnxruntime` 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/third_party/flutter_onnxruntime').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 third_party/flutter_onnxruntime 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// 平台键是否在 `flutter.plugin.platforms` 段以行首缩进键的形式声明。
bool _declaresPlatform(String platformsSection, String name) {
  final pattern = RegExp(r'^\s+' + name + r':\s*$', multiLine: true);
  return pattern.hasMatch(platformsSection);
}

/// pbxproj 里一个 XCBuildConfiguration 块是否属于主屏小组件扩展
/// （FushiWidgets.appex）。扩展的部署目标由 WidgetKit API 决定（iOS 17 /
/// macOS 14），与 Runner 和 pod 下限无关，不受下面「恰为下限」的约束。
bool _isWidgetExtensionConfig(String block) =>
    block.contains('/* FushiWidgets.xcconfig */');

/// 按 XCBuildConfiguration 块拆 pbxproj，返回 (是否小组件扩展, 块文本)。
List<(bool, String)> _buildConfigurations(String pbxproj) {
  final List<(bool, String)> blocks = <(bool, String)>[];
  final List<String> parts = pbxproj.split('isa = XCBuildConfiguration;');
  for (final String part in parts.skip(1)) {
    final int end = part.indexOf('name = ');
    final String block = end < 0 ? part : part.substring(0, end);
    blocks.add((_isWidgetExtensionConfig(block), block));
  }
  return blocks;
}

/// 从 pbxproj 里取某个部署目标 build setting 的全部取值（去重），只看 Runner
/// 工程自身的 configuration（排除小组件扩展）。
Set<String> _deploymentTargets(String pbxproj, String key) {
  final RegExp pattern = RegExp('$key = ([^;]+);');
  return <String>{
    for (final (bool widget, String block) in _buildConfigurations(pbxproj))
      if (!widget)
        for (final RegExpMatch m in pattern.allMatches(block))
          m.group(1)!.trim(),
  };
}

/// 小组件扩展的部署目标（去重）。
Set<String> _widgetDeploymentTargets(String pbxproj, String key) {
  final RegExp pattern = RegExp('$key = ([^;]+);');
  return <String>{
    for (final (bool widget, String block) in _buildConfigurations(pbxproj))
      if (widget)
        for (final RegExpMatch m in pattern.allMatches(block))
          m.group(1)!.trim(),
  };
}

/// 点分版本号比较：a >= b。
bool _versionAtLeast(String a, String b) {
  final List<int> x = a.split('.').map(int.parse).toList();
  final List<int> y = b.split('.').map(int.parse).toList();
  for (int i = 0; i < 3; i++) {
    final int xi = i < x.length ? x[i] : 0;
    final int yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return true;
}

void main() {
  final root = _repoRoot();
  final forkDir = Directory('${root.path}/third_party/flutter_onnxruntime');
  final forkPubspec = File('${forkDir.path}/pubspec.yaml');

  group('flutter_onnxruntime fork 在五端（含 Apple）都接上 native', () {
    test('vendored pubspec 声明 android/ios/linux/macos/windows 全部五端', () {
      final text = forkPubspec.readAsStringSync();
      // 只截取 flutter.plugin.platforms 段，避免注释里出现 "macos" 造成误判。
      final idx = text.indexOf('platforms:');
      expect(idx, greaterThan(0), reason: 'pubspec 缺 plugin.platforms 段');
      final platformsSection = text.substring(idx);

      for (final name in const <String>[
        'android',
        'ios',
        'linux',
        'macos',
        'windows',
      ]) {
        expect(
          _declaresPlatform(platformsSection, name),
          isTrue,
          reason:
              '$name 平台声明必须保留，否则该端本地 OCR 静默降级为 '
              'MissingPluginException',
        );
      }
    });

    test('Apple 原生源码树存在（ios/ 与 macos/ 的 Swift 插件实现）', () {
      for (final platform in const <String>['ios', 'macos']) {
        final plugin = File(
          '${forkDir.path}/$platform/flutter_onnxruntime/'
          'Sources/flutter_onnxruntime/FlutterOnnxruntimePlugin.swift',
        );
        expect(
          plugin.existsSync(),
          isTrue,
          reason: '$platform 插件 Swift 实现缺失：${plugin.path}',
        );
      }
    });

    test('Apple 两端都没有 Package.swift —— 必须走 CocoaPods 而不是 SwiftPM', () {
      // 这是整个方案的支点。一旦 re-vendor 把上游的 Package.swift 抄回来，
      // Flutter 会改走 SwiftPM，onnxruntime-swift-package-manager 的
      // `.macOS(.v14)` 会把整个 app 拖到 macOS 14，构建当场失败。
      for (final platform in const <String>['ios', 'macos']) {
        final manifest = File(
          '${forkDir.path}/$platform/flutter_onnxruntime/Package.swift',
        );
        expect(
          manifest.existsSync(),
          isFalse,
          reason:
              '$platform/flutter_onnxruntime/Package.swift 必须删除，'
              '否则 SwiftPM 会把部署目标拖到 macOS 14 / iOS 15',
        );
      }
    });

    test('workspace 根 pubspec 把 flutter_onnxruntime 接到 vendored fork', () {
      // 迁到 pub workspace 后 dependency_overrides 只能写在仓库根，这里跟着
      // 从 fushi/pubspec.yaml 改到根，path 也不再带 ../ 前缀。
      final WorkspacePubspec ws = WorkspacePubspec.load(
        path: '${root.path}/pubspec.yaml',
      );
      expect(
        ws.isVendored('flutter_onnxruntime', 'third_party/flutter_onnxruntime'),
        isTrue,
        reason: 'flutter_onnxruntime 必须经根 pubspec 指向 vendored fork',
      );
    });
  });

  group('Apple 部署目标与 podspec 下限严格对齐', () {
    // 项目部署目标低于 podspec 下限 -> `pod install` 直接报
    // "The platform of the target `Pods-Runner` ... is not compatible with"。
    // 这两组数字必须成对移动，任一侧单独改都会炸构建，所以钉死在一起。
    const String kIosFloor = '15.1';
    const String kMacosFloor = '13.4';

    test('fork 的 Apple podspec 声明 iOS $kIosFloor / macOS $kMacosFloor', () {
      final ios = File(
        '${forkDir.path}/ios/flutter_onnxruntime.podspec',
      ).readAsStringSync();
      expect(
        ios,
        contains("s.platform = :ios, '$kIosFloor'"),
        reason: 'iOS podspec 下限漂移；onnxruntime-objc 1.23.0 要求 15.1',
      );

      final macos = File(
        '${forkDir.path}/macos/flutter_onnxruntime.podspec',
      ).readAsStringSync();
      expect(
        macos,
        contains("s.platform = :osx, '$kMacosFloor'"),
        reason: 'macOS podspec 下限漂移；onnxruntime-objc 1.23.0 要求 13.4',
      );
    });

    test('Apple podspec 都标 static_framework（use_frameworks! 下的硬要求）', () {
      // onnxruntime-c / onnxruntime-objc 是静态二进制；不标 static_framework，
      // CocoaPods 会以 "transitive dependencies that include statically linked
      // binaries" 中止安装。上游没踩到是因为他们的 example 只走 SwiftPM。
      for (final platform in const <String>['ios', 'macos']) {
        final spec = File(
          '${forkDir.path}/$platform/flutter_onnxruntime.podspec',
        ).readAsStringSync();
        expect(
          spec,
          contains('s.static_framework = true'),
          reason: '$platform podspec 缺 static_framework，pod install 会中止',
        );
      }
    });

    test('Podfile 平台声明与 podspec 下限一致', () {
      final iosPodfile = File(
        '${root.path}/fushi/ios/Podfile',
      ).readAsStringSync();
      expect(iosPodfile, contains("platform :ios, '$kIosFloor'"));

      final macosPodfile = File(
        '${root.path}/fushi/macos/Podfile',
      ).readAsStringSync();
      expect(macosPodfile, contains("platform :osx, '$kMacosFloor'"));
    });

    test('Xcode 工程三个 configuration 的部署目标都不低于 podspec 下限', () {
      final iosProject = File(
        '${root.path}/fushi/ios/Runner.xcodeproj/'
        'project.pbxproj',
      ).readAsStringSync();
      final iosTargets = _deploymentTargets(
        iosProject,
        'IPHONEOS_DEPLOYMENT_TARGET',
      );
      expect(
        iosTargets,
        <String>{kIosFloor},
        reason:
            'iOS 部署目标必须全部恰为 $kIosFloor（Debug/Profile/Release 三份），'
            '实测为 $iosTargets',
      );

      final macosProject = File(
        '${root.path}/fushi/macos/Runner.xcodeproj/'
        'project.pbxproj',
      ).readAsStringSync();
      final macosTargets = _deploymentTargets(
        macosProject,
        'MACOSX_DEPLOYMENT_TARGET',
      );
      expect(
        macosTargets,
        <String>{kMacosFloor},
        reason:
            'macOS 部署目标必须全部恰为 $kMacosFloor（Debug/Profile/Release 三份），'
            '实测为 $macosTargets',
      );

      // 小组件扩展另钉自己的目标，但不得低于 App 的下限（扩展跑在同一台设备上、
      // 由同一个 App 内嵌，低于宿主下限没有意义且会掩盖误改）。
      for (final (String project, String key, String floor)
          in <(String, String, String)>[
            (iosProject, 'IPHONEOS_DEPLOYMENT_TARGET', kIosFloor),
            (macosProject, 'MACOSX_DEPLOYMENT_TARGET', kMacosFloor),
          ]) {
        final Set<String> widget = _widgetDeploymentTargets(project, key);
        expect(widget, isNotEmpty, reason: '$key：找不到小组件扩展的部署目标');
        for (final String v in widget) {
          expect(
            _versionAtLeast(v, floor),
            isTrue,
            reason: '小组件扩展 $key=$v 低于 App 下限 $floor',
          );
        }
      }
    });
  });
}
