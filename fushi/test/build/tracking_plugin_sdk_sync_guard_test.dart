import 'dart:io';

import 'package:test/test.dart';

/// 追踪插件开发包 `tools/tracking-plugin-sdk/` 必须与宿主同规则：词汇清单、requestsPerMinute
/// 上下限、siteId 规则与 `manifest.rs` 一致；沙箱（前奏、上限、运行器）只从音乐开发包引用、不另存
/// 副本（那份由 music_plugin_sdk_sync_guard_test.dart 钉住宿主）。宿主改了而开发包没跟上，
/// 作者本地全绿、装进 app 才失败。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  const String sdk = '../tools/tracking-plugin-sdk';
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
    expect(m, isNotNull, reason: 'tracking rules.mjs 缺 $name');
    return literals(m!.group(1)!);
  }

  List<String> rustList(String name) {
    final Match? m = RegExp(
      'pub const $name: &\\[&str\\] =\\s*&\\[([^\\]]*)\\];',
    ).firstMatch(manifestRs);
    expect(m, isNotNull, reason: 'manifest.rs 缺 $name');
    return literals(m!.group(1)!);
  }

  int jsInt(String name) {
    final Match? m = RegExp('export const $name = (\\d+);').firstMatch(rules);
    expect(m, isNotNull, reason: 'tracking rules.mjs 缺 $name');
    return int.parse(m!.group(1)!);
  }

  const List<String> vocab = <String>[
    'KNOWN_TRACKING_CAPABILITIES',
    'REQUIRED_TRACKING_CAPABILITIES',
    'KNOWN_TRACKING_PERMISSIONS',
    'REQUIRED_TRACKING_PERMISSIONS',
    'KNOWN_TRACKING_KINDS',
    'KNOWN_TRACKING_MODES',
  ];

  test('search / lookup result cap: the kit validator and the host agree', () {
    final RegExpMatch? kit = RegExp(
      r'searchItems: (\d+),',
    ).firstMatch(read('$sdk/lib/validate.mjs'));
    final RegExpMatch? host = RegExp(r'const int _maxSearchResults = (\d+);')
        .firstMatch(
          read('lib/src/media/tracking/plugin/plugin_tracking_provider.dart'),
        );
    expect(kit, isNotNull);
    expect(host, isNotNull);
    expect(kit!.group(1), host!.group(1));
    // Raised from 10 so the Bangumi auto-matching scores as many candidates
    // as the built-in provider (spec 2026-11-11 §6).
    expect(host.group(1), '20');
    for (final String doc in <String>[
      '$sdk/GUIDE.md',
      '$sdk/fushi-tracking-plugin.d.ts',
      '../docs/specs/2026-11-10-tracking-plugins.md',
    ]) {
      expect(read(doc), isNot(contains('first 10')), reason: doc);
    }
  });

  test('六份追踪词汇清单与 manifest.rs 一致', () {
    for (final String name in vocab) {
      final List<String> rust = rustList(name);
      expect(rust, isNotEmpty, reason: 'manifest.rs $name 解析为空');
      expect(jsList(name), rust, reason: '$name 与 manifest.rs 不一致');
    }
  });

  test('保留 siteId 清单与 manifest.rs RESERVED_TRACKING_SITE_IDS 一致', () {
    final List<String> rust = rustList('RESERVED_TRACKING_SITE_IDS');
    expect(
      rust,
      isNotEmpty,
      reason: 'manifest.rs RESERVED_TRACKING_SITE_IDS 解析为空',
    );
    expect(jsList('RESERVED_SITE_IDS'), rust);
  });

  test('requestsPerMinute 上下限与 manifest.rs validate_tracking 一致', () {
    // manifest.rs 把上下限写成校验里的字面量：`(1..=600).contains(&t.requests_per_minute)`。
    final Match? m = RegExp(
      r'\((\d+)\.\.=(\d+)\)\.contains\(&t\.requests_per_minute\)',
    ).firstMatch(manifestRs);
    expect(m, isNotNull, reason: 'manifest.rs 里找不到 requestsPerMinute 的范围校验');
    expect(jsInt('REQUESTS_PER_MINUTE_MIN'), int.parse(m!.group(1)!));
    expect(jsInt('REQUESTS_PER_MINUTE_MAX'), int.parse(m.group(2)!));
  });

  test('siteId 规则与 manifest.rs valid_site_id 一致', () {
    final Match? fn = RegExp(
      r'fn valid_site_id\(id: &str\) -> bool \{([\s\S]*?)\n\}',
    ).firstMatch(manifestRs);
    expect(fn, isNotNull, reason: 'manifest.rs 缺 valid_site_id');
    final String body = fn!.group(1)!;
    final Match? len = RegExp(
      r'\((\d+)\.\.=(\d+)\)\.contains\(&id\.len\(\)\)',
    ).firstMatch(body);
    expect(len, isNotNull, reason: 'valid_site_id 的长度校验形状变了');
    final int min = int.parse(len!.group(1)!);
    final int max = int.parse(len.group(2)!);
    // 字符集：只允许 ASCII 小写字母与数字（再多一种字符就得同步改开发包的正则）。
    final Set<String> predicates = RegExp(
      r'is_ascii_\w+\(\)',
    ).allMatches(body).map((Match m) => m.group(0)!).toSet();
    expect(predicates, <String>{'is_ascii_lowercase()', 'is_ascii_digit()'});
    expect(
      body,
      isNot(contains("b'")),
      reason: 'valid_site_id 多了字面量字符，同步 SITE_ID_PATTERN',
    );

    expect(jsInt('SITE_ID_MIN'), min);
    expect(jsInt('SITE_ID_MAX'), max);
    expect(
      rules,
      contains('export const SITE_ID_PATTERN = /^[a-z0-9]{$min,$max}\$/;'),
    );
  });

  test('开发包不自带前奏 / 沙箱上限 / 运行器副本，只引用音乐开发包', () {
    expect(
      File('$sdk/lib/prelude.js').existsSync(),
      isFalse,
      reason: '前奏只有音乐开发包一份（逐字节对齐宿主）',
    );
    final List<File> sources = Directory(sdk)
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (File f) =>
              f.path.endsWith('.mjs') &&
              !f.path.replaceAll('\\', '/').contains('/examples/') &&
              !f.path.replaceAll('\\', '/').contains('/templates/'),
        )
        .toList();
    expect(sources, isNotEmpty);
    for (final File f in sources) {
      final String text = read(f.path);
      for (final String banned in <String>[
        'export const LIMITS',
        'prelude.js',
        'node:vm',
        'class Policy',
        'function isPrivateIp',
      ]) {
        expect(
          text,
          isNot(contains(banned)),
          reason: '${f.path} 不能自带 `$banned`（从 ../music-plugin-sdk 引用）',
        );
      }
    }
    expect(
      rules,
      contains("from '../../music-plugin-sdk/lib/rules.mjs'"),
      reason: 'tracking rules.mjs 应从音乐开发包取 LIMITS / Policy',
    );
    final String cli = read('$sdk/fushi-tracking-plugin.mjs');
    expect(cli, contains("from '../music-plugin-sdk/lib/runner.mjs'"));
    expect(cli, contains("from '../music-plugin-sdk/lib/pkg.mjs'"));
  });

  test('fushi-tracking-plugin.d.ts 的能力函数与清单联合类型与 manifest.rs 一致', () {
    final String dts = read('$sdk/fushi-tracking-plugin.d.ts');
    final Match? plugin = RegExp(
      r'interface Plugin \{([\s\S]*?)\n  \}',
    ).firstMatch(dts);
    expect(plugin, isNotNull, reason: 'd.ts 缺 interface Plugin');
    final Set<String> methods = RegExp(
      r'^\s{4}(\w+)\(',
      multiLine: true,
    ).allMatches(plugin!.group(1)!).map((Match m) => m.group(1)!).toSet();
    expect(methods, rustList('KNOWN_TRACKING_CAPABILITIES').toSet());

    List<String> union(String name) {
      final Match? m = RegExp('type $name = ([^;]+);').firstMatch(dts);
      expect(m, isNotNull, reason: 'd.ts 缺 type $name');
      return literals(m!.group(1)!);
    }

    expect(union('Capability'), rustList('KNOWN_TRACKING_CAPABILITIES'));
    expect(union('Permission'), rustList('KNOWN_TRACKING_PERMISSIONS'));
    expect(union('Kind'), rustList('KNOWN_TRACKING_KINDS'));
    expect(union('Mode'), rustList('KNOWN_TRACKING_MODES'));
  });

  test('错误前缀分类剥掉的 JS 错误类型名与 Dart 宿主一致', () {
    final Match? dart = RegExp(r"RegExp\(r'\^\(([A-Za-z|]+)\): '\)").firstMatch(
      read('../packages/fushi_music/lib/src/plugin/plugin_instance.dart'),
    );
    expect(dart, isNotNull, reason: 'musicPluginErrorSummary 的正则形状变了');
    expect(jsList('STRIPPED_ERROR_NAMES'), dart!.group(1)!.split('|'));
  });
}
