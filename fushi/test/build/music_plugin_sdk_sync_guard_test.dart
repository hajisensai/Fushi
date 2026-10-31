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

  test('rules.mjs 的 LIMITS 与宿主常量一致（含在途 / 单步宿主调用、凭据条数）', () {
    /// `4 * 1024 * 1024` / `64_000` 这类整数乘积。
    int product(String expr) => expr
        .split('*')
        .map((String f) => int.parse(f.trim().replaceAll('_', '')))
        .fold(1, (int a, int b) => a * b);

    final Match? limitsBody = RegExp(
      r'export const LIMITS = \{([^}]*)\}',
    ).firstMatch(rules);
    expect(limitsBody, isNotNull, reason: 'rules.mjs 缺 LIMITS');
    final Map<String, int> limits = <String, int>{
      for (final Match m in RegExp(
        r'^\s*(\w+):\s*([0-9_*\s]+),',
        multiLine: true,
      ).allMatches(limitsBody!.group(1)!))
        m.group(1)!: product(m.group(2)!),
    };

    int rustConst(String file, String name) {
      final Match? m = RegExp(
        'const $name: \\w+ = ([0-9_*\\s]+);',
      ).firstMatch(read('../native/fushi_music/src/plugin/$file'));
      expect(m, isNotNull, reason: '$file 缺 $name');
      return product(m!.group(1)!);
    }

    int dartConst(String name) {
      final Match? m = RegExp('const int $name = ([0-9_*\\s]+);').firstMatch(
        read('../packages/fushi_music/lib/src/plugin/plugin_instance.dart'),
      );
      expect(m, isNotNull, reason: 'plugin_instance.dart 缺 $name');
      return product(m!.group(1)!);
    }

    final Map<String, int> host = <String, int>{
      'maxFiles': rustConst('package.rs', 'MAX_FILES'),
      'maxFileBytes': rustConst('package.rs', 'MAX_FILE_BYTES'),
      'maxTotalBytes': rustConst('package.rs', 'MAX_TOTAL_BYTES'),
      'maxHeaders': rustConst('runtime.rs', 'MAX_HEADERS'),
      'maxHeaderBytes': rustConst('runtime.rs', 'MAX_HEADER_BYTES'),
      'maxRequestBodyBytes': rustConst('runtime.rs', 'MAX_BODY_BYTES'),
      'maxResultBytes': rustConst('runtime.rs', 'MAX_RESULT_BYTES'),
      'maxStorageKey': rustConst('runtime.rs', 'MAX_STORAGE_KEY'),
      'maxStorageValue': rustConst('runtime.rs', 'MAX_STORAGE_VALUE'),
      'maxInflightCalls': rustConst('runtime.rs', 'MAX_INFLIGHT_CALLS'),
      'maxCallsPerStep': rustConst('runtime.rs', 'MAX_CALLS_PER_STEP'),
      'maxCredentialValue': rustConst('vault.rs', 'MAX_VALUE_BYTES'),
      'maxCredentialEntries': rustConst('vault.rs', 'MAX_ENTRIES'),
      'maxResponseBytes': dartConst('_kMaxResponseBytes'),
      'maxRedirects': dartConst('_kMaxRedirects'),
    };
    for (final MapEntry<String, int> e in host.entries) {
      expect(
        limits[e.key],
        e.value,
        reason: 'rules.mjs LIMITS.${e.key} 与宿主常量不一致',
      );
    }
  });

  test('fushi-plugin.d.ts 的能力 / 搜索类型 / HTTP 方法与 manifest.rs 一致', () {
    final String dts = read('$sdk/fushi-plugin.d.ts');
    final Match? plugin = RegExp(
      r'interface Plugin \{([\s\S]*?)\n  \}',
    ).firstMatch(dts);
    expect(plugin, isNotNull, reason: 'd.ts 缺 interface Plugin');
    final Set<String> methods = RegExp(
      r'^\s{4}(\w+)\(',
      multiLine: true,
    ).allMatches(plugin!.group(1)!).map((Match m) => m.group(1)!).toSet();
    expect(methods, rustList('KNOWN_CAPABILITIES').toSet());

    List<String> union(String pattern) {
      final Match? m = RegExp(pattern).firstMatch(dts);
      expect(m, isNotNull, reason: 'd.ts 缺 $pattern');
      return literals(m!.group(1)!);
    }

    expect(
      union(r'type SearchType = ([^;]+);'),
      rustList('KNOWN_SEARCH_TYPES'),
    );
    expect(union(r'method\?: ([^;]+);'), rustList('KNOWN_METHODS'));
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
