// 用户 2026-11-25「cupertino 默认用封面网格」：Apple（design_system = glass）下
// 没选过库页布局时生效封面网格；M3E 新安装仍是拼贴；显式选过的照旧按所选。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase database;

  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  ThemeNotifier notifierWith(Map<String, Object> prefs) =>
      ThemeNotifier(database, () => const TextTheme())
        ..loadFromPrefsSnapshot(<String, String>{
          for (final MapEntry<String, Object> e in prefs.entries)
            e.key: PrefCodec.encode(e.value),
        });

  test('Cupertino 没选过布局：默认封面网格', () {
    final ThemeNotifier notifier = notifierWith(<String, Object>{
      'design_system': 'glass',
    });
    addTearDown(notifier.dispose);
    expect(notifier.shellContentLayoutDefault, ShellContentLayout.grid);
    expect(notifier.shellContentLayout, ShellContentLayout.grid);
    expect(notifier.shellTheme.contentLayout, ShellContentLayout.grid);
  });

  test('M3E 新安装没选过布局：仍是拼贴', () {
    final ThemeNotifier notifier = notifierWith(<String, Object>{
      'design_system': 'material',
    });
    addTearDown(notifier.dispose);
    expect(notifier.shellContentLayout, ShellContentLayout.collage);
  });

  test('Cupertino 显式选过拼贴：按所选', () {
    final ThemeNotifier notifier = notifierWith(<String, Object>{
      'design_system': 'glass',
      'shell_content_layout': ShellContentLayout.collage.prefValue,
    });
    addTearDown(notifier.dispose);
    expect(notifier.shellContentLayout, ShellContentLayout.collage);
  });
}
