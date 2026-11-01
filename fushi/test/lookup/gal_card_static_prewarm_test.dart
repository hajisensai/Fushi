import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_render.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';

/// 游戏内嵌查词冷启动预热：会话开门时把静态段先送进卡片宿主页，首查不再现场
/// 建窗 + 灌几十 MB 静态段。宿主侧行为由 `global_lookup_host_test.mjs` 覆盖，这里钉
/// Dart 侧脚本形状与两条记账 / 触发纪律。
void main() {
  test('预热脚本只调用宿主 prewarmStatic，并原样携带静态段与版本号', () {
    const PopupStaticSettingsJs settings = PopupStaticSettingsJs(
      head: '/* HEAD </script> "q" */',
      tail: '/* TAIL */',
      revision: 42,
      themeVarsJs: '',
    );
    final String script = buildPrewarmStaticScript(settings);
    const String prefix =
        'window.__globalLookupHost && '
        'window.__globalLookupHost.prewarmStatic(';
    expect(script, startsWith(prefix));
    expect(script, endsWith(');'));
    final Object? descriptor = jsonDecode(
      script.substring(prefix.length, script.length - 2),
    );
    expect(descriptor, <String, Object>{
      'staticRevision': 42,
      'staticHeadJs': '/* HEAD </script> "q" */',
      'staticTailJs': '/* TAIL */',
    });
  });

  test('预热在平台调用完成且路由仍有效之后才记账', () {
    final String source = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    final int start = source.indexOf('Future<void> prewarmGalCardStatic(');
    expect(start, isNonNegative);
    final int end = source.indexOf('\n  }\n', start);
    final String body = source.substring(start, end);
    final int render = body.indexOf('GlobalLookupChannel.render(');
    final int valid = body.indexOf('GlobalLookupChannel.isRouteValid(route)');
    final int commit = body.indexOf('_hostStaticRevisions.commit(');
    expect(render, isNonNegative);
    expect(valid, greaterThan(render));
    expect(commit, greaterThan(valid), reason: '脚本没送到宿主就先记账，首查就再也拿不到静态段');
  });

  test('只在门刚打开、没有卡片也没有排队查词时预热', () {
    final String source = File(
      'lib/src/lookup/gal_ingame_lookup_controller.dart',
    ).readAsStringSync();
    final int start = source.indexOf('void _prewarmCardIfIdle()');
    expect(start, isNonNegative);
    final String body = source.substring(
      start,
      source.indexOf('\n  }\n', start),
    );
    expect(body, contains('_activeRoute != null'));
    expect(body, contains('_pendingLookup != null'));
    expect(body, contains('++_lookupRouteEpoch'));
    expect(
      source,
      contains('if (admitted && nativeAccepted) _prewarmCardIfIdle();'),
    );
  });
}
