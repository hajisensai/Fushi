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

  test('默认（新安装）：镂空脊 + 拼贴 + 平滑圆角，色块摆放没选过', () {
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

  group('G1 库页布局出厂判定（ThemeNotifier 载入时）', () {
    Future<ThemeNotifier> load(Map<String, String> extra) async {
      final ThemeNotifier n = ThemeNotifier(database, () => const TextTheme())
        ..loadFromPrefsSnapshot(<String, String>{
          'design_system': PrefCodec.encode('material'),
          ...extra,
        });
      // 载入期的落盘是 fire-and-forget：等它落进库再断言。
      await Future<void>.delayed(Duration.zero);
      await database.getPref(ShellLayoutInstallDefault.prefKey);
      return n;
    }

    test('新安装：拼贴、不弹，判定落库', () async {
      final ThemeNotifier n = await load(const <String, String>{});
      addTearDown(n.dispose);
      expect(n.shellContentLayout, ShellContentLayout.collage);
      expect(n.shellLayoutChoicePending, isFalse);
      expect(
        await database.getPref(ShellLayoutInstallDefault.prefKey),
        PrefCodec.encode(ShellLayoutInstallDefault.fresh.prefValue),
      );
    });

    test('升级上来没选过：封面网格 + 待弹；「稍后再说」后不再弹、仍是网格', () async {
      final ThemeNotifier n = await load(<String, String>{
        'first_time_setup': PrefCodec.encode(true),
      });
      addTearDown(n.dispose);
      expect(n.shellContentLayout, ShellContentLayout.grid);
      expect(n.shellTheme.contentLayout, ShellContentLayout.grid);
      expect(n.shellLayoutChoicePending, isTrue);

      await n.resolveShellLayoutChoice(null);
      expect(n.shellLayoutChoicePending, isFalse);
      expect(n.shellContentLayout, ShellContentLayout.grid);
      expect(
        await database.getPref(ShellLayoutInstallDefault.prefKey),
        PrefCodec.encode(ShellLayoutInstallDefault.upgrade.prefValue),
      );

      // 重启：判定已落库，不重判、不再弹。
      await n.refreshFromDb();
      expect(n.shellLayoutChoicePending, isFalse);
      expect(n.shellContentLayout, ShellContentLayout.grid);
    });

    test('升级上来在弹窗里选了拼贴：写入布局并记成已处理', () async {
      final ThemeNotifier n = await load(<String, String>{
        'onboarding_completed': PrefCodec.encode(true),
      });
      addTearDown(n.dispose);
      await n.resolveShellLayoutChoice(ShellContentLayout.collage);
      expect(n.shellContentLayout, ShellContentLayout.collage);
      expect(n.shellLayoutChoicePending, isFalse);
      expect(
        await database.getPref('shell_content_layout'),
        PrefCodec.encode('collage'),
      );
    });

    test('待弹期间在设置 / 引导里显式选了布局：选择框记成已处理、不再弹', () async {
      final ThemeNotifier n = await load(<String, String>{
        'first_time_setup': PrefCodec.encode(true),
      });
      addTearDown(n.dispose);
      expect(n.shellLayoutChoicePending, isTrue);
      await n.setShellContentLayout(ShellContentLayout.collage);
      expect(n.shellLayoutChoicePending, isFalse);
      expect(n.shellContentLayout, ShellContentLayout.collage);
      expect(
        await database.getPref(ShellLayoutInstallDefault.prefKey),
        PrefCodec.encode(ShellLayoutInstallDefault.upgrade.prefValue),
      );
    });

    test('升级前就选过布局：不弹，选过的值照旧', () async {
      final ThemeNotifier n = await load(<String, String>{
        'first_time_setup': PrefCodec.encode(true),
        'shell_content_layout': PrefCodec.encode('collage'),
      });
      addTearDown(n.dispose);
      expect(n.shellLayoutChoicePending, isFalse);
      expect(n.shellContentLayout, ShellContentLayout.collage);
    });

    test('老用户的布局键被删（切到老 Profile）：落回封面网格而不是拼贴', () async {
      final ThemeNotifier n = await load(<String, String>{
        'first_time_setup': PrefCodec.encode(true),
        'shell_content_layout': PrefCodec.encode('collage'),
      });
      addTearDown(n.dispose);
      await database.deletePref('shell_content_layout');
      await n.refreshFromDb();
      expect(n.shellContentLayout, ShellContentLayout.grid);
    });
  });
}
