import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_routes.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_values.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';

/// 建路由表不解引用 ref（handler 都是闭包），给一个空壳即可。
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('建路由表时不应触碰 WidgetRef：${invocation.memberName}');
}

StatFact _fact({
  required String kind,
  required String key,
  required String day,
  int ms = 0,
  int chars = 0,
  int pages = 0,
}) => StatFact(
  mediaKind: kind,
  mediaKey: key,
  title: 'T-$key',
  format: '',
  dateKey: day,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: pages,
  lastActiveMs: 0,
);

void main() {
  group('路由表', () {
    final List<CtlRoute> routes = buildSettingsCtlRoutes(
      DesktopCtlContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/ 下，method+path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/'));
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '重复路由 ${route.method} ${route.pattern}',
        );
      }
    });

    test('profiles/import 不被 profiles/:id 吞掉（POST 只有 import 一条两段路径）', () {
      final List<CtlRoute> hits = routes
          .where(
            (CtlRoute r) =>
                r.method == 'POST' &&
                r.match('/api/admin/profiles/import') != null,
          )
          .toList();
      expect(hits.map((CtlRoute r) => r.pattern), <String>[
        '/api/admin/profiles/import',
      ]);
    });
  });

  group('值解析', () {
    test('布尔', () {
      expect(parseCtlSettingBool('ON'), isTrue);
      expect(parseCtlSettingBool('0'), isFalse);
      expect(
        () => parseCtlSettingBool('maybe'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
    });

    test('数字：整数约束与越界 400', () {
      expect(parseCtlSettingNumber('1.5', integer: false, min: 0, max: 2), 1.5);
      expect(parseCtlSettingNumber('3', integer: true), 3);
      for (final String bad in <String>['1.5', 'x']) {
        expect(
          () => parseCtlSettingNumber(bad, integer: true),
          throwsA(isA<CtlFailure>()),
        );
      }
      expect(
        () => parseCtlSettingNumber('5', integer: false, max: 2),
        throwsA(isA<CtlFailure>()),
      );
      expect(
        () => parseCtlSettingNumber('NaN', integer: false),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('单选：token / 大小写 / 标签', () {
      const List<String> tokens = <String>['light', 'system', 'dark'];
      const List<String> labels = <String>['浅色', '跟随系统', '深色'];
      expect(
        indexOfCtlSettingOption('dark', tokens: tokens, labels: labels),
        2,
      );
      expect(
        indexOfCtlSettingOption('LIGHT', tokens: tokens, labels: labels),
        0,
      );
      expect(
        indexOfCtlSettingOption('跟随系统', tokens: tokens, labels: labels),
        1,
      );
      expect(
        () => indexOfCtlSettingOption('blue', tokens: tokens, labels: labels),
        throwsA(isA<CtlFailure>()),
      );
      expect(ctlSettingOptionToken(ModuleId.browse), 'browse');
      expect(ctlSettingOptionToken(3), '3');
    });

    test('模块 id：枚举名各种写法与持久化键', () {
      expect(parseCtlModuleId('browser-extension'), ModuleId.browserExtension);
      expect(parseCtlModuleId('CARD_CREATION'), ModuleId.cardCreation);
      expect(parseCtlModuleId('module_downloads_enabled'), ModuleId.browse);
      expect(parseCtlModuleId('nope'), isNull);
    });
  });

  test('机密判定：schema secret / 键尾命中 PrefRedactionPolicy', () {
    expect(isCtlSecretSetting('x.y', declaredSecret: true), isTrue);
    expect(
      isCtlSecretSetting(
        'system.network_proxy_username',
        declaredSecret: false,
      ),
      isTrue,
    );
    expect(
      isCtlSecretSetting('services.jimaku_api_key', declaredSecret: false),
      isTrue,
    );
    expect(
      isCtlSecretSetting('appearance.eink_mode', declaredSecret: false),
      isFalse,
    );
    expect(redactCtlSecret('hunter2'), kCtlRedactedValue);
    expect(redactCtlSecret(''), '');
  });

  test('统计域参数：listen 没有独立口径给 400', () {
    expect(ctlStatMediaKindOf(null), isNull);
    expect(ctlStatMediaKindOf('read'), kActivityMediaBook);
    expect(ctlStatMediaKindOf('watch'), kActivityMediaVideo);
    expect(ctlStatMediaKindOf('game'), kActivityMediaGame);
    expect(() => ctlStatMediaKindOf('listen'), throwsA(isA<CtlFailure>()));
    expect(() => ctlStatMediaKindOf('xx'), throwsA(isA<CtlFailure>()));
  });

  test('统计摘要：按窗口与域过滤日面事实，按条目排名', () {
    final List<StatFact> daily = <StatFact>[
      _fact(
        kind: kActivityMediaBook,
        key: 'a',
        day: '2026-10-01',
        ms: 60000,
        chars: 500,
      ),
      _fact(
        kind: kActivityMediaBook,
        key: 'a',
        day: '2026-10-02',
        ms: 60000,
        chars: 300,
      ),
      _fact(
        kind: kActivityMediaBook,
        key: 'b',
        day: '2026-09-01',
        ms: 999999,
        chars: 1,
      ),
      _fact(kind: kActivityMediaVideo, key: 'v', day: '2026-10-02', ms: 180000),
    ];
    bool inWindow(String day) => day.compareTo('2026-09-28') >= 0;

    final Map<String, Object?> all = summarizeCtlStatFacts(
      daily,
      inWindow: inWindow,
    );
    final Map<String, Object?> totals = all['totals']! as Map<String, Object?>;
    expect(totals['ms'], 300000);
    expect(totals['chars'], 800);
    expect(totals['activeDays'], 2);
    final Map<String, Object?> byKind = all['byKind']! as Map<String, Object?>;
    expect(byKind.keys, unorderedEquals(<String>['read', 'watch']));
    final List<Map<String, Object?>> top =
        all['topMedia']! as List<Map<String, Object?>>;
    expect(top.map((Map<String, Object?> m) => m['mediaKey']), <String>[
      'v',
      'a',
    ]);

    final Map<String, Object?> books = summarizeCtlStatFacts(
      daily,
      inWindow: (String _) => true,
      mediaKind: kActivityMediaBook,
    );
    expect((books['totals']! as Map<String, Object?>)['chars'], 801);
    expect((books['byKind']! as Map<String, Object?>).keys, <String>['read']);
  });

  test('快捷键列：滚轮绑定走序列化格式，macOS 上也不出 ⌥ 显示符号', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final Map<String, List<String>> columns = ctlShortcutBindingColumns(
      const ShortcutBindingSet(
        wheelBindings: <WheelBinding>[
          WheelBinding(
            WheelDirection.down,
            modifiers: <ModifierKey>{ModifierKey.alt},
          ),
        ],
      ),
    );
    expect(columns['mouse'], <String>['Alt+WheelDown']);
    debugDefaultTargetPlatformOverride = null;
  });

  test('时长格式', () {
    expect(formatCtlDuration(45000), '45s');
    expect(formatCtlDuration(750000), '12m30s');
    expect(formatCtlDuration(3900000), '1h05m');
  });
}
