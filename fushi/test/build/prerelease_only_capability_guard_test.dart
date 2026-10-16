import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// 「正式版屏蔽复习（SRS）」这条构建通道边界的源码守卫（用户 2026-10-16 拍板）。
///
/// 与 `ios_store_compliance_guard_test.dart` 同一种理由：这条边界失效是**静默**的。
/// 本地 `flutter run` / `flutter test` 与 CI 测试一律不注入 `FUSHI_BUILD_VERSION`，
/// 判据在那里恒为「预发布」——某个消费端自己解析版本串判错了、或绕开模块可见性
/// 直接露出入口，本机与 CI 照样全绿，只有正式版用户看得到。
///
/// 钉两件事：
/// 1. `ModuleId.srs` 的可用性委托到 `PrereleaseOnlyCapability.srs`，判据本体
///    （`isFormalReleaseBuildVersion`）只在 `prerelease_only_capability.dart` 定义一次；
/// 2. 复习的消费端（`lib/src/srs/` 与 `lib/src/pages/implementations/srs/` 下的
///    文件，以及任何在代码里问 `ModuleId.srs` /
///    `srsModuleEnabledProvider` 的文件）**不得自己读构建版本**——一律经模块可见性。
///
/// 第 2 条是目录枚举型（扫 `lib/` 全树，新文件自动纳入），已登记进
/// `docs/agent/fast-workflow.md` 的「合并后必跑：目录枚举型守卫清单」。
void main() {
  const String capabilityFile =
      'lib/src/models/prerelease_only_capability.dart';
  const String moduleIdFile = 'lib/src/models/module_id.dart';

  /// 读构建版本 / 推断构建通道的全部入口。消费端出现任何一个都算「自己判通道」。
  const List<String> buildVersionReaders = <String>[
    'fushiRunningCodeVersion',
    'kFushiBuildVersionDefine',
    'normalizeFushiBuildVersion',
    'resolveCurrentAppVersion',
    'channelForUpdateVersion',
    'isFormalReleaseBuildVersion',
  ];

  /// 判据所在的两个文件：判据本体与委托点。
  const Set<String> allowed = <String>{capabilityFile, moduleIdFile};

  String norm(String path) => path.replaceAll('\\', '/');

  /// 该文件是否是复习的消费端（按路径或按代码里问了复习模块门）。
  bool isSrsConsumer(String path, String source) =>
      path.startsWith('lib/src/srs/') ||
      path.startsWith('lib/src/pages/implementations/srs/') ||
      containsIdentifier(source, 'srsModuleEnabledProvider') ||
      compactCode(source).contains('ModuleId.srs');

  /// 消费端里自己读构建版本的违规（文件 → 命中的标识符）。
  Map<String, List<String>> violationsIn(Map<String, String> corpus) {
    final Map<String, List<String>> out = <String, List<String>>{};
    corpus.forEach((String path, String source) {
      if (allowed.contains(path) || !isSrsConsumer(path, source)) return;
      final List<String> hits = <String>[
        for (final String name in buildVersionReaders)
          if (containsIdentifier(source, name)) name,
        if (maskComments(source).contains('FUSHI_BUILD_VERSION'))
          'FUSHI_BUILD_VERSION',
      ];
      if (hits.isNotEmpty) out[path] = hits;
    });
    return out;
  }

  group('判据单点', () {
    test('ModuleId.srs 的可用性委托到 PrereleaseOnlyCapability.srs', () {
      final String moduleId = compactCode(
        File(moduleIdFile).readAsStringSync(),
      );
      expect(
        moduleId,
        contains(
          'ModuleId.srs=>PrereleaseOnlyCapability.srs.availableFor('
          'buildVersion:normalizeFushiBuildVersion(buildVersionDefine),),',
        ),
        reason: '复习的可用性必须问构建通道的唯一真相源，不能在 module_id 里另写判据。',
      );
      expect(
        moduleId,
        contains('StringbuildVersionDefine=kFushiBuildVersionDefine,'),
        reason:
            'availableOn 的版本输入缺省必须取本构建常量，'
            '否则不传参的消费端（设置 / 引导 / 控制通道）在正式版里照样露出复习。',
      );
    });

    test('通道判据只在 prerelease_only_capability.dart 定义一次', () {
      final String capability = compactCode(
        File(capabilityFile).readAsStringSync(),
      );
      expect(
        capability,
        contains(
          'boolisFormalReleaseBuildVersion(String?buildVersion)=>'
          'buildVersion!=null&&'
          'channelForUpdateVersion(buildVersion)==UpdateChannel.stable;',
        ),
        reason: '正式版判据复用更新器的通道判据，未注入版本（null）不算正式版。',
      );
      final List<String> definers = <String>[
        for (final FileSystemEntity e in Directory(
          'lib',
        ).listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart'))
            if (RegExp(
              r'\bbool\s+isFormalReleaseBuildVersion\s*\(',
            ).hasMatch(maskComments(e.readAsStringSync())))
              norm(e.path),
      ];
      expect(definers, <String>[capabilityFile]);
    });
  });

  group('消费端不自己判构建通道', () {
    test('复习消费端一律经模块可见性，不读构建版本', () {
      final Map<String, String> corpus = <String, String>{
        for (final FileSystemEntity e in Directory(
          'lib',
        ).listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart'))
            norm(e.path): e.readAsStringSync(),
      };
      expectScanScale(
        corpus.length,
        what: 'lib/ 下的 .dart 文件',
        atLeast: 1400,
        measured: 1812,
      );
      final int consumers = corpus.entries
          .where((MapEntry<String, String> e) => isSrsConsumer(e.key, e.value))
          .length;
      expectScanScale(consumers, what: '复习消费端', atLeast: 28, measured: 36);
      expect(
        violationsIn(corpus),
        isEmpty,
        reason:
            '正式版是否提供复习只能由 PrereleaseOnlyCapability 判一次，'
            '经 ModuleId.availableOn → ModuleVisibility 生效；'
            '消费端自己读版本串会与单点分叉（本地 / CI 恒不注入版本，分叉看不出来）。',
      );
    });

    test('判据自校验：合成语料', () {
      final Map<String, List<String>> hits = violationsIn(<String, String>{
        // 复习目录里自己读版本：违规。
        'lib/src/srs/bad_a.dart':
            'bool get show => fushiRunningCodeVersion?.contains("-") ?? true;',
        // 问了复习模块门、又自己推通道：违规。
        'lib/src/pages/bad_b.dart':
            'final bool a = v.isEnabled(ModuleId.srs) && '
            'channelForUpdateVersion(x) != UpdateChannel.stable;',
        // 直接读 define：违规。
        'lib/src/settings/bad_c.dart':
            "const String v = String.fromEnvironment('FUSHI_BUILD_VERSION');\n"
            'final bool b = ref.watch(srsModuleEnabledProvider);',
        // 只在注释里提到：不算。
        'lib/src/srs/ok_comment.dart':
            '// 不要在这里读 fushiRunningCodeVersion / FUSHI_BUILD_VERSION\n'
            'final int x = 1;',
        // 读版本但与复习无关（更新器）：不在本守卫范围。
        'lib/src/utils/ok_updater.dart':
            'final String? v = fushiRunningCodeVersion;',
        // 判据所在文件：放行。
        moduleIdFile:
            'ModuleId.srs => x(kFushiBuildVersionDefine, '
            'normalizeFushiBuildVersion(d))',
      });
      expect(hits.keys.toSet(), <String>{
        'lib/src/srs/bad_a.dart',
        'lib/src/pages/bad_b.dart',
        'lib/src/settings/bad_c.dart',
      });
      expect(hits['lib/src/srs/bad_a.dart'], <String>[
        'fushiRunningCodeVersion',
      ]);
      expect(hits['lib/src/pages/bad_b.dart'], <String>[
        'channelForUpdateVersion',
      ]);
      expect(hits['lib/src/settings/bad_c.dart'], <String>[
        'FUSHI_BUILD_VERSION',
      ]);
    });
  });

  group('复习门一律经模块可见性', () {
    // 正式版判据只在 ModuleId.availableOn → ModuleVisibility 这条链上生效；
    // 直接读用户意愿（pref）的入口会绕过它——正式版里 pref 开着的用户（从
    // 预发布版换装过来）就会看到复习。消费端只能问
    // `moduleVisibility.isEnabled(ModuleId.srs)` / `srsModuleEnabledProvider`。
    final RegExp prefBypass = RegExp(
      r'''moduleEnabled\(\s*ModuleId\.srs\s*\)|ModuleId\.srs\.prefKey|['"]module_srs_enabled['"]''',
    );

    List<String> bypassesIn(Map<String, String> corpus) => <String>[
      for (final MapEntry<String, String> e in corpus.entries)
        if (e.key != moduleIdFile && prefBypass.hasMatch(maskComments(e.value)))
          e.key,
    ];

    test('lib/ 里没有绕开模块可见性直接读复习开关 pref 的入口', () {
      final Map<String, String> corpus = <String, String>{
        for (final FileSystemEntity e in Directory(
          'lib',
        ).listSync(recursive: true))
          if (e is File && e.path.endsWith('.dart'))
            norm(e.path): e.readAsStringSync(),
      };
      expectScanScale(
        corpus.length,
        what: 'lib/ 下的 .dart 文件',
        atLeast: 1400,
        measured: 1812,
      );
      expect(
        bypassesIn(corpus),
        isEmpty,
        reason:
            '复习入口必须问 moduleVisibility.isEnabled(ModuleId.srs) / '
            'srsModuleEnabledProvider（含正式版判据），不能直接读 pref。',
      );
    });

    test('判据自校验：合成语料', () {
      expect(
        bypassesIn(<String, String>{
          'lib/src/a.dart': 'final bool v = app.moduleEnabled(ModuleId.srs);',
          'lib/src/b.dart': "final Object? v = getPref('module_srs_enabled');",
          'lib/src/c.dart': 'final String k = ModuleId.srs.prefKey;',
          'lib/src/ok_visibility.dart':
              'final bool v = app.moduleVisibility.isEnabled(ModuleId.srs);',
          'lib/src/ok_comment.dart': '// 别写 moduleEnabled(ModuleId.srs)',
          moduleIdFile: "srs('module_srs_enabled'),",
        }).toSet(),
        <String>{'lib/src/a.dart', 'lib/src/b.dart', 'lib/src/c.dart'},
      );
    });
  });
}
