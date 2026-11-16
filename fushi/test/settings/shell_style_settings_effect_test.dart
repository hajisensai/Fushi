// 外壳样式四项设置（侧栏样式 / 库页布局 / 色块摆放 / 平滑圆角，PR #3397）的
// 生效链：偏好 → ThemeNotifier → 应用主题里的 [FushiShellTheme] 扩展。各消费方
// （侧栏、库页、色块墙、主题层表面形状）都只经 `shellThemeOf` /
// `shellContentLayoutOf` 读这一份扩展，所以扩展跟着变 = 设置生效。设置页
// harness 里没有外壳与库页，effect 由本文件咬住（settings_schema_coverage 的
// kCoveredElsewhere 指到这里）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FushiDatabase database;
  late ThemeNotifier notifier;

  setUp(() {
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    notifier = ThemeNotifier(database, () => const TextTheme())
      ..loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
        'brightness_mode': PrefCodec.encode('light'),
      });
  });

  tearDown(() async {
    notifier.dispose();
    await database.close();
  });

  FushiShellTheme shellOfTheme() =>
      notifier.theme.extension<FushiShellTheme>()!;

  test('默认：镂空脊 + 拼贴 + 平滑圆角，色块摆放跟着布局走', () {
    final FushiShellTheme shell = shellOfTheme();
    expect(shell.railStyle, ShellRailStyle.defaultStyle);
    expect(shell.contentLayout, ShellContentLayout.defaultLayout);
    expect(shell.blockArrangement, isNull);
    expect(shell.smoothCorners, isTrue);
  });

  test('侧栏样式：切到色脊后主题扩展跟着变', () async {
    await notifier.setShellRailStyle(ShellRailStyle.spine);
    expect(shellOfTheme().railStyle, ShellRailStyle.spine);
    await notifier.setShellRailStyle(ShellRailStyle.notch);
    expect(shellOfTheme().railStyle, ShellRailStyle.notch);
  });

  test('库页布局：切到封面网格后主题扩展跟着变', () async {
    await notifier.setShellContentLayout(ShellContentLayout.grid);
    expect(shellOfTheme().contentLayout, ShellContentLayout.grid);
  });

  test('色块摆放：选过之后主题扩展带上所选值', () async {
    await notifier.setShellBlockArrangement(ShellBlockArrangement.staggered);
    expect(shellOfTheme().blockArrangement, ShellBlockArrangement.staggered);
  });

  test('平滑圆角：关掉后主题扩展跟着变', () async {
    await notifier.setShellSmoothCorners(false);
    expect(shellOfTheme().smoothCorners, isFalse);
  });
}
