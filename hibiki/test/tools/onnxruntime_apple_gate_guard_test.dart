// 守卫：flutter_onnxruntime vendored fork 必须 gate 出 Apple（macOS/iOS）。
//
// 背景：上游 flutter_onnxruntime 1.8.3 的 ios/macos podspec 把 onnxruntime-objc 钉在
// 1.23，强制 macOS 部署目标 14.0 / iOS 16.0。作为 federated MethodChannel 插件，一旦
// 声明 macos，Flutter 就把它注册进 macOS Swift Package，令整个 "Build Desktop" macOS
// release job 失败（本项目部署目标 macOS 10.15）。方案 B：vendored fork 从
// flutter.plugin.platforms 删掉 ios/macos（并删原生源码树），Apple 上 manga OCR 优雅
// 降级到互联 host / 云端（见 lib/src/ocr/ocr_inference_ort.dart isLocalOnnxRuntimeAvailable）。
//
// 本守卫防未来 re-vendor 或误改把 Apple 平台声明加回来，静默复破 macOS 构建。
// 纯 dart:io，不依赖 Flutter 运行时。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
  fail('找不到含 third_party/flutter_onnxruntime 的仓库根'
      '（从 ${Directory.current.path} 向上）');
}

/// 平台键是否在 `flutter.plugin.platforms` 段以行首缩进键的形式声明。
bool _declaresPlatform(String platformsSection, String name) {
  final pattern = RegExp(r'^\s+' + name + r':\s*$', multiLine: true);
  return pattern.hasMatch(platformsSection);
}

void main() {
  final root = _repoRoot();
  final forkDir = Directory('${root.path}/third_party/flutter_onnxruntime');
  final forkPubspec = File('${forkDir.path}/pubspec.yaml');

  group('flutter_onnxruntime fork gates out Apple', () {
    test('vendored pubspec 声明 android/windows/linux，不声明 ios/macos', () {
      final text = forkPubspec.readAsStringSync();
      // 只截取 flutter.plugin.platforms 段，避免注释里出现 "macos" 造成误判。
      final idx = text.indexOf('platforms:');
      expect(idx, greaterThan(0), reason: 'pubspec 缺 plugin.platforms 段');
      final platformsSection = text.substring(idx);

      expect(_declaresPlatform(platformsSection, 'android'), isTrue,
          reason: 'android OCR 必须保留');
      expect(_declaresPlatform(platformsSection, 'windows'), isTrue,
          reason: 'windows OCR 必须保留');
      expect(_declaresPlatform(platformsSection, 'linux'), isTrue,
          reason: 'linux OCR 必须保留');
      expect(_declaresPlatform(platformsSection, 'ios'), isFalse,
          reason: 'ios 平台声明会强制 iOS 16 部署目标，破坏构建');
      expect(_declaresPlatform(platformsSection, 'macos'), isFalse,
          reason: 'macos 平台声明会强制 macOS 14 部署目标，破坏 macOS release job');
    });

    test('Apple 原生源码树已删除（ios/ 与 macos/ 不存在）', () {
      expect(Directory('${forkDir.path}/ios').existsSync(), isFalse,
          reason: 'ios/ 目录应随 fork 删除');
      expect(Directory('${forkDir.path}/macos').existsSync(), isFalse,
          reason: 'macos/ 目录应随 fork 删除');
    });

    test('hibiki/pubspec.yaml 把 flutter_onnxruntime override 到 vendored fork',
        () {
      final pubspec =
          File('${root.path}/hibiki/pubspec.yaml').readAsStringSync();
      final override = RegExp(
          r'flutter_onnxruntime:\s*\n\s+path:\s*\.\./third_party/flutter_onnxruntime');
      expect(override.hasMatch(pubspec), isTrue,
          reason:
              'flutter_onnxruntime 必须经 dependency_overrides 指向 vendored fork');
    });
  });
}
