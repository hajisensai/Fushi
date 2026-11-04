// 「正在播放」小组件的原生控制（NowPlayingWidget.kt 的 NowPlayingControl）经反射读
// audio_service 包私有的 `AudioService.instance` 拿 MediaSession token。
//
// 这是外部不可控限制下的兼容层：audio_service 不公开服务实例，插件内部又写死
// `AudioService.class`（不能换成自家子类），而走 MediaBrowserCompat 连服务会
// BIND_AUTO_CREATE 冷建服务，每次渲染都这么做既费电又会把「没接上 Dart」的空会话
// 当成可控。代价是插件升级改了字段名 / 继承关系时反射静默返回 null，小组件退化成
// 「点了只开 app」。本守卫把这层隐式契约钉成测试：插件升级改动它时在这里红，
// 而不是在用户手里静默失效。插件公开会话 token（或服务实例）后删反射与本测试。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 经 `.dart_tool/package_config.json` 解析 [package] 包里的一个文件（pub cache
/// 目录名带版本号，只有 package_config 知道真值）。
File _packageFile(String package, String relative) {
  Directory current = Directory.current.absolute;
  File? config;
  while (true) {
    final File candidate = File(
      '${current.path}/.dart_tool/package_config.json',
    );
    if (candidate.existsSync()) {
      config = candidate;
      break;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  if (config == null) {
    throw StateError('找不到 .dart_tool/package_config.json —— 先跑 pub get');
  }
  final Map<String, Object?> json =
      jsonDecode(config.readAsStringSync()) as Map<String, Object?>;
  for (final Object? entry in json['packages']! as List<Object?>) {
    final Map<String, Object?> pkg = entry! as Map<String, Object?>;
    if (pkg['name'] != package) continue;
    final Uri root = config.parent.uri.resolve('${pkg["rootUri"]}/');
    return File.fromUri(root.resolve(relative));
  }
  throw StateError('package_config.json 里没有 $package');
}

void main() {
  test('audio_service still exposes what NowPlayingControl reflects on', () {
    final File service = _packageFile(
      'audio_service',
      'android/src/main/java/com/ryanheise/audioservice/AudioService.java',
    );
    expect(service.existsSync(), isTrue, reason: service.path);
    final String src = service.readAsStringSync();
    expect(
      src,
      matches(RegExp(r'\bstatic\s+AudioService\s+instance\s*;')),
      reason: 'NowPlayingControl reads the static field "instance" by name',
    );
    expect(
      src,
      contains('class AudioService extends MediaBrowserServiceCompat'),
      reason: 'getSessionToken() comes from MediaBrowserServiceCompat',
    );
  });

  test('the app side of the reflection contract is intact', () {
    final String kotlin = File(
      'android/app/src/main/java/app/fushi/reader/widgets/NowPlayingWidget.kt',
    ).readAsStringSync();
    expect(kotlin, contains('"com.ryanheise.audioservice.AudioService"'));
    expect(kotlin, contains('getDeclaredField("instance")'));
    expect(kotlin, contains('getMethod("getSessionToken")'));
    final String proguard = File(
      'android/app/proguard-rules.pro',
    ).readAsStringSync();
    expect(
      proguard,
      contains('-keep class com.ryanheise.audioservice.** { *; }'),
      reason: 'R8 must not rename AudioService.instance',
    );
  });
}
