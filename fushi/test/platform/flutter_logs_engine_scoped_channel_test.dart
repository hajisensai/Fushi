// BUG-4242：Android 上同一进程会同时存在多个 FlutterEngine——WorkManager 的后台引擎
// （workmanager 的 BackgroundWorker）自动注册全部插件，其中 audio_service 插件一附着就
// 绑定 AudioService，AudioService.onCreate 再新建主引擎跑 main()。后台任务结束销毁后台
// 引擎时，每个插件的 onDetachedFromEngine 只该拆自己那个引擎上的东西。
//
// flutter_logs 2.1.x 把 MethodChannel 存在 Kotlin `companion object`（进程级静态）里：
// 主引擎附着时覆盖了静态 channel，后台引擎销毁时 `channel?.setMethodCallHandler(null)`
// 清掉的是**主引擎**的 handler → 用户打开 app，main() 的 FlutterLogs.initLogs 抛
// MissingPluginException，appModel.initialise() 永不调用，停在启动看门狗页。
//
// 本守卫钉住两件事：解析到的 flutter_logs 版本里，Android 插件的 channel 是引擎实例
// 作用域（不在 companion object 里）；main() 仍在 initialise() 之前调 initLogs（若以后
// 挪走了这次调用，本守卫的前提随之变化，需要一起复核）。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

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

/// [source] 里所有 `companion object { ... }` 块的正文（按花括号配对截取）。
List<String> _companionBodies(String source) {
  final List<String> bodies = <String>[];
  for (final RegExpMatch m in RegExp(
    r'companion\s+object\s*\{',
  ).allMatches(source)) {
    int depth = 1;
    int i = m.end;
    while (i < source.length && depth > 0) {
      final String c = source[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      i++;
    }
    bodies.add(source.substring(m.end, i));
  }
  return bodies;
}

void main() {
  test('flutter_logs Android plugin keeps its channels per engine', () {
    final File plugin = _packageFile(
      'flutter_logs',
      'android/src/main/kotlin/com/flutter/logs/plogs/flutter_logs/'
          'FlutterLogsPlugin.kt',
    );
    expect(plugin.existsSync(), isTrue, reason: plugin.path);
    final String src = plugin.readAsStringSync();
    final RegExp channelField = RegExp(
      r'\bva[rl]\s+\w+\s*:\s*(MethodChannel|EventChannel)\b',
    );
    for (final String body in _companionBodies(src)) {
      expect(
        channelField.hasMatch(body),
        isFalse,
        reason:
            'flutter_logs 把 channel 放回了 companion object（进程级静态）：'
            '后台引擎销毁时会清掉主引擎的 handler（BUG-4242）',
      );
    }
    // 实例字段 + 拆的是自己那个：onDetachedFromEngine 置空的是实例上的 channel。
    expect(
      src,
      matches(RegExp(r'private\s+var\s+channel\s*:\s*MethodChannel\?')),
      reason: 'MethodChannel 必须是插件实例字段',
    );
  });

  test('main() still initialises flutter_logs before AppModel.initialise', () {
    final String main = File('lib/main.dart').readAsStringSync();
    final int initLogs = main.indexOf('await FlutterLogs.initLogs(');
    final int initialise = main.indexOf('await appModel.initialise();');
    expect(initLogs, greaterThan(0));
    expect(initialise, greaterThan(initLogs));
  });
}
