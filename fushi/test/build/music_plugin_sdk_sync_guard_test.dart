import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 第三方插件开发包 `tools/music-plugin-sdk/` 的本地运行器必须与宿主同规则：前奏脚本是逐字节副本，
/// 能力 / 权限 / 搜索类型 / HTTP 方法 / 媒体请求头 / App scheme 清单与宿主一致。宿主改了规则而
/// 开发包没跟上，第三方本地全绿、装进 app 才失败。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  const String sdk = '../tools/music-plugin-sdk';
  final String rules = read('$sdk/lib/rules.mjs');
  final String manifestRs = read(
    '../native/fushi_music/src/plugin/manifest.rs',
  );

  /// `[ 'a', "b", ... ]` / `&[ "a", ... ]` 里的全部字符串字面量（按出现顺序）。
  List<String> literals(String body) => RegExp(
    r'''['"]([^'"]+)['"]''',
  ).allMatches(body).map((Match m) => m.group(1)!).toList();

  List<String> jsList(String name) {
    final Match? m = RegExp(
      'export const $name = \\[([^\\]]*)\\]',
    ).firstMatch(rules);
    expect(m, isNotNull, reason: 'rules.mjs 缺 $name');
    return literals(m!.group(1)!);
  }

  List<String> rustList(String name) {
    final Match? m = RegExp(
      '$name: &\\[&str\\] = &\\[([^\\]]*)\\]',
    ).firstMatch(manifestRs);
    expect(m, isNotNull, reason: 'manifest.rs 缺 $name');
    return literals(m!.group(1)!);
  }

  test('前奏脚本与宿主逐字节一致', () {
    expect(
      read('$sdk/lib/prelude.js'),
      read('../native/fushi_music/src/plugin/prelude.js'),
      reason: '改了 native/fushi_music/src/plugin/prelude.js 就复制一份到开发包',
    );
  });

  test('能力 / 权限 / 搜索类型 / HTTP 方法 / API 版本与 manifest.rs 一致', () {
    expect(jsList('KNOWN_CAPABILITIES'), rustList('KNOWN_CAPABILITIES'));
    expect(jsList('KNOWN_PERMISSIONS'), rustList('KNOWN_PERMISSIONS'));
    expect(jsList('KNOWN_SEARCH_TYPES'), rustList('KNOWN_SEARCH_TYPES'));
    expect(jsList('KNOWN_METHODS'), rustList('KNOWN_METHODS'));
    final String rustApi = RegExp(
      r'HOST_API_VERSION: u32 = (\d+);',
    ).firstMatch(manifestRs)!.group(1)!;
    expect(rules, contains('export const HOST_API_VERSION = $rustApi;'));
  });

  test('媒体请求头白名单与 App scheme 白名单与 Dart 宿主一致', () {
    List<String> dartSet(String file, String name) {
      final Match? m = RegExp(
        'const Set<String> $name = <String>\\{([^}]*)\\}',
      ).firstMatch(read(file));
      expect(m, isNotNull, reason: '$file 缺 $name');
      return literals(m!.group(1)!);
    }

    const String plugin = '../packages/fushi_music/lib/src/plugin';
    expect(
      jsList('MEDIA_HEADER_ALLOWLIST'),
      dartSet(
        '$plugin/plugin_net_guard.dart',
        'kMusicPluginMediaHeaderAllowlist',
      ),
    );
    expect(
      jsList('APP_URL_SCHEMES'),
      dartSet('$plugin/plugin_source.dart', 'kMusicPluginAppSchemes'),
    );
  });
}
