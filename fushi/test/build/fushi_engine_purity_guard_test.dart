import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';

/// 无头服务端的编译门在源码层的镜像：`packages/fushi_engine` 与 `packages/fushi_server`
/// 会被 `dart compile exe` 成不含 Flutter 的单文件，闭包里任何 `package:flutter/…`
/// （含 foundation.dart，它传递 import `dart:ui`）、`dart:ui`、method-channel 插件、
/// 或者反向 import app（`package:fushi/…`）都会让服务端编不过——但那要等 CI 的
/// Linux job 才炸。这里在 `flutter test` 层先拦：
///
/// 1. 两个包的 `lib/` + `bin/` 全树零禁用 import；
/// 2. 引擎只准 import 三个内部包的**纯 Dart 子 barrel**
///    （`fushi_audio_core` / `fushi_anki_core` / `fushi_dictionary_core`），
///    不准 import 全 barrel（全 barrel 导出 just_audio / shared_preferences / file_picker）；
/// 3. 三个子 barrel 的 export 闭包本身也零禁用 import。
///
/// 设计：docs/specs/2026-09-08-fushi-server-headless-design.md §3.1。
void main() {
  const List<String> forbiddenPrefixes = <String>[
    'package:flutter/',
    'package:flutter_riverpod/',
    'package:riverpod/',
    'package:fushi/',
    'package:path_provider/',
    'package:shared_preferences/',
    'package:flutter_onnxruntime/',
    'package:ffmpeg_kit_flutter',
    'package:bonsoir/',
    'package:file_picker/',
    'package:share_plus/',
    'package:url_launcher/',
    'package:flutter_charset_detector/',
    'package:package_info_plus/',
    'package:device_info_plus/',
    'package:permission_handler/',
    'package:media_kit',
    'package:flutter_inappwebview',
    'package:just_audio',
    'package:audio_session/',
    'package:flutter_archive/',
    'package:win32/',
    'package:sqlite3_flutter_libs/',
    'package:fushi_audio/fushi_audio.dart',
    'package:fushi_anki/fushi_anki.dart',
    'package:fushi_dictionary/fushi_dictionary.dart',
  ];
  final RegExp directive = RegExp(r"""^\s*(?:import|export)\s+['"]([^'"]+)['"]""", multiLine: true);

  List<String> offendersIn(File f) {
    final List<String> out = <String>[];
    for (final RegExpMatch m in directive.allMatches(f.readAsStringSync())) {
      final String uri = m.group(1)!;
      if (uri == 'dart:ui' || uri.startsWith('dart:ui/')) {
        out.add('$uri');
        continue;
      }
      for (final String prefix in forbiddenPrefixes) {
        if (uri.startsWith(prefix)) {
          out.add(uri);
          break;
        }
      }
    }
    return out;
  }

  Map<String, List<String>> scanTree(Directory root) {
    final Map<String, List<String>> bad = <String, List<String>>{};
    for (final FileSystemEntity e in root.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final List<String> hits = offendersIn(e);
      if (hits.isNotEmpty) bad[e.path.replaceAll('\\', '/')] = hits;
    }
    return bad;
  }

  int countDart(Directory root) => root
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .length;

  test('fushi_engine 源码零 Flutter / 插件 / 反向 app import', () {
    final Directory lib = Directory('../packages/fushi_engine/lib');
    expect(lib.existsSync(), isTrue, reason: '请从 fushi/ 包根跑测试');
    expectScanScale(countDart(lib),
        what: 'fushi_engine/lib 下的 .dart', atLeast: 150, measured: 214);
    expect(scanTree(lib), isEmpty);
  });

  test('fushi_server 源码零 Flutter / 插件 / 反向 app import', () {
    final Directory lib = Directory('../packages/fushi_server/lib');
    final Directory bin = Directory('../packages/fushi_server/bin');
    expect(lib.existsSync() && bin.existsSync(), isTrue);
    expectScanScale(countDart(lib) + countDart(bin),
        what: 'fushi_server 下的 .dart', atLeast: 8, measured: 12);
    expect(<String, List<String>>{...scanTree(lib), ...scanTree(bin)}, isEmpty);
  });

  test('三个纯 Dart 子 barrel 的 export 闭包零 Flutter / 插件', () {
    final Map<String, String> barrels = <String, String>{
      'fushi_audio': '../packages/fushi_audio/lib/fushi_audio_core.dart',
      'fushi_anki': '../packages/fushi_anki/lib/fushi_anki_core.dart',
      'fushi_dictionary': '../packages/fushi_dictionary/lib/fushi_dictionary_core.dart',
    };
    final Map<String, List<String>> bad = <String, List<String>>{};
    int visited = 0;
    for (final MapEntry<String, String> e in barrels.entries) {
      final File barrel = File(e.value);
      expect(barrel.existsSync(), isTrue, reason: '${e.value} 不存在');
      final Set<String> seen = <String>{};
      final List<File> queue = <File>[barrel];
      while (queue.isNotEmpty) {
        final File f = queue.removeLast();
        final String key = f.absolute.path;
        if (!seen.add(key)) continue;
        visited++;
        final List<String> hits = offendersIn(f);
        if (hits.isNotEmpty) bad[f.path.replaceAll('\\', '/')] = hits;
        for (final RegExpMatch m in directive.allMatches(f.readAsStringSync())) {
          final String uri = m.group(1)!;
          if (uri.startsWith('package:') || uri.startsWith('dart:')) continue;
          final File dep = File('${f.parent.path}/$uri');
          if (dep.existsSync()) queue.add(dep);
        }
      }
    }
    expectScanScale(visited, what: '三个 core barrel 的 export 闭包文件', atLeast: 30, measured: 60);
    expect(bad, isEmpty);
  });

  test('fushi_engine / fushi_server 的 pubspec 不声明 flutter sdk', () {
    for (final String path in <String>[
      '../packages/fushi_engine/pubspec.yaml',
      '../packages/fushi_server/pubspec.yaml',
      '../packages/fushi_core/pubspec.yaml',
    ]) {
      final String text = File(path).readAsStringSync();
      expect(RegExp(r'^\s+flutter:\s*\n\s+sdk:\s*flutter', multiLine: true).hasMatch(text), isFalse,
          reason: '$path 声明了 flutter sdk 依赖');
    }
  });
}
