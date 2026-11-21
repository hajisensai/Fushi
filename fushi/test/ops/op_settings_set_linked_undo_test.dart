import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_settings.dart';
import 'package:fushi/src/ops/settings_index.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ref is not used by the settings.set undo');
}

const String _theme = 'appearance.theme';
const String _backdrop = 'appearance.page_backdrop.follow_accent';
const String _icon = 'appearance.follow_app_icon_accent';

/// pr3775：`config set appearance.theme` 与设置页点色卡同一入口，会顺带关掉正在
/// 生效的取色开关。AI 写操作必须可撤销：settings.set 的撤销要把被关掉的开关一并写回，
/// 没被改动的联动项不碰。
void main() {
  late Map<String, Object?> store;
  late List<String> writes;
  late OpCatalog catalog;

  /// 与真实路由同形的假设置读写：写主题键时按 pickAppThemeKey 的语义关掉开着的取色。
  List<CtlRoute> routes() => <CtlRoute>[
    CtlRoute.get('/api/admin/settings/:key', (CtlCall call) async {
      final String key = call.params['key']!;
      return <String, Object?>{'key': key, 'value': store[key]};
    }),
    CtlRoute('PUT', '/api/admin/settings/:key', (CtlCall call) async {
      final String key = call.params['key']!;
      writes.add(key);
      store[key] = call.body['value'];
      if (key == _theme) {
        if (store[_backdrop] == true) store[_backdrop] = false;
        if (store[_icon] == true) store[_icon] = false;
      }
      return <String, Object?>{'key': key, 'value': store[key]};
    }),
  ];

  setUp(() {
    store = <String, Object?>{
      _theme: 'm3-baseline',
      _backdrop: true,
      _icon: false,
    };
    writes = <String>[];
    final List<CtlRoute> rs = routes();
    catalog = OpCatalog.build(
      rs,
      describeSettingsOps(
        OpDescribeKit(OpContext(ref: _UnusedRef()), rs),
      ).where((OpDescription d) => d.id == 'settings.set'),
    );
  });

  Future<OpInvocation> set(String key, Object? value) =>
      OpInvoker(catalog).invoke(
        'settings.set',
        <String, Object?>{'key': key, 'value': value},
        caller: OpCaller.model,
        captureUndo: true,
      );

  Future<OpUndoOutcome> undo(OpInvocation invocation) {
    final Map<String, Object?> payload =
        jsonDecode(jsonEncode(invocation.undo!.payload))
            as Map<String, Object?>;
    return catalog['settings.set']!.undo!.revert(payload);
  }

  test('theme declares the two accent toggles it may switch off', () {
    expect(settingsIndexLinkedKeys(_theme), <String>[_backdrop, _icon]);
    expect(settingsIndexLinkedKeys(_backdrop), isEmpty);
    // 联动键必须是真实存在的设置项，否则撤销读它时 400。
    final String backdropSchema = File(
      'lib/src/settings/settings_schema_page_backdrop.dart',
    ).readAsStringSync();
    final String appearanceSchema = File(
      'lib/src/settings/settings_schema_appearance.dart',
    ).readAsStringSync();
    expect(backdropSchema, contains("id: '$_backdrop'"));
    expect(appearanceSchema, contains("id: '$_icon'"));
  });

  test('undo restores the theme and the accent toggle it switched off, '
      'without touching untouched linked toggles', () async {
    final OpInvocation invocation = await set(_theme, 'm3-blue');
    expect(store[_theme], 'm3-blue');
    expect(store[_backdrop], isFalse);

    writes.clear();
    final OpUndoOutcome outcome = await undo(invocation);

    expect(outcome.status, OpUndoStatus.done);
    expect(store[_theme], 'm3-baseline');
    expect(store[_backdrop], isTrue);
    expect(store[_icon], isFalse);
    expect(writes, <String>[_theme, _backdrop]);
  });

  test(
    'a linked toggle the user already switched back stays on after undo',
    () async {
      final OpInvocation invocation = await set(_theme, 'm3-blue');
      store[_backdrop] = true;

      // 写回主题键仍走用户选主题入口，会再关一次正在生效的取色；联动快照随后把它
      // 写回原值，终态与执行前一致。
      expect((await undo(invocation)).status, OpUndoStatus.done);
      expect(store[_theme], 'm3-baseline');
      expect(store[_backdrop], isTrue);
      expect(store[_icon], isFalse);
    },
  );

  test('theme changed again since: superseded, nothing written', () async {
    final OpInvocation invocation = await set(_theme, 'm3-blue');
    store[_theme] = 'm3-teal';

    writes.clear();
    expect((await undo(invocation)).status, OpUndoStatus.superseded);
    expect(writes, isEmpty);
    expect(store[_backdrop], isFalse);
  });

  test('settings without linked keys keep the plain read-back undo', () async {
    final OpInvocation invocation = await set(_icon, true);
    expect(invocation.undo!.payload['linked'], isEmpty);
    expect((await undo(invocation)).status, OpUndoStatus.done);
    expect(store[_icon], isFalse);
  });
}
