import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show kCustomThemeDefaultSeed;
import 'package:fushi/src/pages/implementations/custom_theme_page.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// 自定义主题编辑页重设计（2026-09）的行为测试：
/// - 主题色默认所见即所得（保存时 primaryColor == seed == 所选色）；
/// - 「按明暗自动调整色调」默认关；开了只存 seed（primaryColor null）；只有 seed 的
///   旧条目打开时该开关自动为开（还原其派生语义）；
/// - 「界面背景」选纯白 → 写 surfaceColor；「跟随系统取色」→ 写 followSystemAccent；
/// - 角色行默认「跟随主题」（条目字段 null），在选色弹窗里改色后落进条目；
/// - 「恢复跟随主题」把字段清回 null；
/// - 宽屏（≥ 900）点角色行不弹窗，右栏选色器直接切到该角色。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel({
    List<CustomThemeEntry> themes = const <CustomThemeEntry>[],
    String themeKey = 'system-theme',
  })  : _themes = List<CustomThemeEntry>.from(themes),
        _themeKey = themeKey,
        super(testPlatformServices());

  final List<CustomThemeEntry> _themes;
  String _themeKey;
  final List<CustomThemeEntry> upserts = <CustomThemeEntry>[];
  final List<Color?> audioHighlightWrites = <Color?>[];

  @override
  List<CustomThemeEntry> get customThemes =>
      List<CustomThemeEntry>.unmodifiable(_themes);

  @override
  CustomThemeEntry? customThemeById(String id) {
    for (final CustomThemeEntry e in _themes) {
      if (e.id == id) return e;
    }
    return null;
  }

  @override
  CustomThemeEntry? get activeCustomThemeEntry {
    const String prefix = 'custom-theme:';
    if (!_themeKey.startsWith(prefix)) return null;
    return customThemeById(_themeKey.substring(prefix.length));
  }

  @override
  Future<void> upsertCustomTheme(CustomThemeEntry entry) async {
    upserts.add(entry);
    final int idx = _themes.indexWhere(
      (CustomThemeEntry e) => e.id == entry.id,
    );
    if (idx >= 0) {
      _themes[idx] = entry;
    } else {
      _themes.add(entry);
    }
  }

  @override
  Future<void> selectCustomTheme(String id) async {}

  @override
  Future<void> deleteCustomTheme(String id) async {
    _themes.removeWhere((CustomThemeEntry e) => e.id == id);
  }

  @override
  String get appThemeKey => _themeKey;

  @override
  Future<void> setAppThemeKey(String key) async {
    _themeKey = key;
  }

  @override
  Future<void> setAudioHighlightColor(Color? color) async {
    audioHighlightWrites.add(color);
  }

  @override
  Color? get audioHighlightColor => null;

  @override
  String get brightnessMode => 'light';

  @override
  bool get isDarkMode => false;

  @override
  bool get einkMode => false;

  @override
  Color? get systemPrimaryColor => const Color(0xFF1F4959);
}

Widget _host(_RecordingAppModel appModel, Widget home) {
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => appModel)],
    child: TranslationProvider(
      child: MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: home,
      ),
    ),
  );
}

final Finder _verticalScrollable = find
    .byWidgetPredicate(
      (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

Future<void> _tapApply(WidgetTester tester) async {
  final Finder apply = find.byIcon(Icons.check);
  await tester.scrollUntilVisible(apply, 200, scrollable: _verticalScrollable);
  await tester.pumpAndSettle();
  await tester.tap(apply);
  await tester.pumpAndSettle();
}

Future<void> _tapRow(WidgetTester tester, String title) async {
  final Finder row = find.text(title);
  await tester.scrollUntilVisible(row, 120, scrollable: _verticalScrollable);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// 设置分组里第 N 只开关（预览卡里还有一只只读的示意开关，不能按类型取 first）。
Finder _settingsSwitch(int index) => find
    .descendant(
      of: find.byType(AdaptiveSettingsSwitchRow),
      matching: find.byType(Switch),
    )
    .at(index);

Future<void> _tapSettingsSwitch(WidgetTester tester, int index) async {
  final Finder toggle = _settingsSwitch(index);
  await tester.scrollUntilVisible(toggle, 120, scrollable: _verticalScrollable);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

/// 在选色面板上点一下（HSV 面板右上角 = 高饱和高亮度），产生一个非默认颜色。
Future<void> _pickInArea(WidgetTester tester) async {
  final Finder area = find.byType(ColorPickerArea).last;
  final Rect rect = tester.getRect(area);
  await tester.tapAt(Offset(rect.right - 4, rect.top + 4));
  await tester.pumpAndSettle();
}

void main() {
  group('CustomThemePage · 主题色所见即所得', () {
    testWidgets('草稿默认钉死主题色：primaryColor == seed == 品牌默认色', (
      WidgetTester tester,
    ) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      await _tapApply(tester);

      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.seed, kCustomThemeDefaultSeed);
      expect(saved.primaryColor, kCustomThemeDefaultSeed);
      // 其余角色全部跟随主题。
      expect(saved.fontColor, isNull);
      expect(saved.bgColor, isNull);
      expect(saved.selectionColor, isNull);
      expect(saved.linkColor, isNull);
      expect(saved.secondaryColor, isNull);
      expect(saved.tertiaryColor, isNull);
      expect(saved.containerColor, isNull);
    });

    testWidgets('开启「按明暗自动调整色调」→ 只存 seed，不钉 primary，行尾出现实际显示色点', (
      WidgetTester tester,
    ) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();
      expect(find.byTooltip(t.theme_role_actual_color), findsNothing);

      // 第 0 只是「跟随系统取色」，第 1 只是「自动调整色调」。
      await _tapSettingsSwitch(tester, 1);
      expect(find.byTooltip(t.theme_role_actual_color), findsOneWidget);

      await _tapApply(tester);
      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.seed, kCustomThemeDefaultSeed);
      expect(saved.primaryColor, isNull);
    });

    testWidgets('「跟随系统取色」→ 主题色行显示系统色并上锁，应用写 followSystemAccent', (
      WidgetTester tester,
    ) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      await _tapSettingsSwitch(tester, 0);
      expect(find.byIcon(Icons.lock_outline), findsWidgets);

      await _tapApply(tester);
      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.followSystemAccent, isTrue);
      // 所选色仍作兜底存着（系统不提供取色时用）。
      expect(saved.seed, kCustomThemeDefaultSeed);
    });

    testWidgets('「派生色用中性灰」开关 → 应用写 neutralDerived', (
      WidgetTester tester,
    ) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      // 第 2 只开关：跟随系统 / 自动调色调 / 派生色中性灰。
      await _tapSettingsSwitch(tester, 2);
      await _tapApply(tester);
      expect(appModel.upserts.single.neutralDerived, isTrue);
    });

    testWidgets('「界面背景」选纯白 → 应用写 surfaceColor', (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      await _tapRow(tester, t.theme_role_surface);
      expect(find.byType(ColorPickerArea), findsOneWidget);
      // 预设第一格是纯白。
      final Finder white = find.byWidgetPredicate(
        (Widget w) =>
            w is FushiColorSwatch &&
            w.onTap != null &&
            w.color.toARGB32() == 0xFFFFFFFF,
      );
      await tester.tap(white.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.dialog_done));
      await tester.pumpAndSettle();

      await _tapApply(tester);
      expect(appModel.upserts.single.surfaceColor, 0xFFFFFFFF);
    });

    testWidgets('已钉主色的旧条目：主题色就是钉的那个，重存后 seed 对齐', (WidgetTester tester) async {
      const CustomThemeEntry existing = CustomThemeEntry(
        id: 'ct-1',
        name: 'Mine',
        seed: 0xFF336699,
        primaryColor: 0xFF112233,
      );
      final _RecordingAppModel appModel = _RecordingAppModel(
        themes: <CustomThemeEntry>[existing],
        themeKey: 'custom-theme:ct-1',
      );
      await tester.pumpWidget(
        _host(appModel, const CustomThemePage(themeId: 'ct-1')),
      );
      await tester.pumpAndSettle();

      await _tapApply(tester);
      final CustomThemeEntry saved = appModel.upserts.single;
      // 重存后 seed 与钉死的主色对齐：派生色都从主题色出发。
      expect(saved.primaryColor, 0xFF112233);
      expect(saved.seed, 0xFF112233);
    });

    testWidgets('只有 seed 的旧条目：自动调色调开关自动为开，重存仍只存 seed', (
      WidgetTester tester,
    ) async {
      const CustomThemeEntry legacy = CustomThemeEntry(
        id: 'ct-2',
        name: 'Old',
        seed: 0xFF336699,
      );
      final _RecordingAppModel appModel = _RecordingAppModel(
        themes: <CustomThemeEntry>[legacy],
        themeKey: 'custom-theme:ct-2',
      );
      await tester.pumpWidget(
        _host(appModel, const CustomThemePage(themeId: 'ct-2')),
      );
      await tester.pumpAndSettle();
      final Switch autoTone = tester.widget<Switch>(_settingsSwitch(1));
      expect(autoTone.value, isTrue);

      await _tapApply(tester);
      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.primaryColor, isNull);
      expect(saved.seed, 0xFF336699);
    });
  });

  group('CustomThemePage · 角色行：跟随主题 / 弹窗改色 / 恢复', () {
    testWidgets('正文文字默认跟随主题；弹窗里选色后落进 fontColor', (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      // 滚到阅读器板块后，已布局的可选角色全部「跟随主题」（ListView 懒构建，
      // 只数已构建的）。
      await tester.scrollUntilVisible(
        find.text(t.theme_role_reader_text),
        120,
        scrollable: _verticalScrollable,
      );
      await tester.pumpAndSettle();
      final int followingBefore =
          find.text(t.theme_role_follows_theme).evaluate().length;
      expect(followingBefore, greaterThanOrEqualTo(4));
      expect(find.byTooltip(t.theme_role_reset), findsNothing);

      await _tapRow(tester, t.theme_role_reader_text);
      // 窄屏（默认 800×600）：弹选色窗。
      expect(find.byType(ColorPickerArea), findsOneWidget);
      await _pickInArea(tester);
      await tester.tap(find.text(t.dialog_done));
      await tester.pumpAndSettle();

      expect(
        find.text(t.theme_role_follows_theme).evaluate().length,
        followingBefore - 1,
      );
      expect(find.byTooltip(t.theme_role_reset), findsOneWidget);

      await _tapApply(tester);
      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.fontColor, isNotNull);
      expect(saved.bgColor, isNull);
    });

    testWidgets('「恢复跟随主题」把字段清回 null', (WidgetTester tester) async {
      const CustomThemeEntry existing = CustomThemeEntry(
        id: 'ct-1',
        name: 'Mine',
        seed: 0xFF336699,
        linkColor: 0xFF0000FF,
      );
      final _RecordingAppModel appModel = _RecordingAppModel(
        themes: <CustomThemeEntry>[existing],
      );
      await tester.pumpWidget(
        _host(appModel, const CustomThemePage(themeId: 'ct-1')),
      );
      await tester.pumpAndSettle();

      final Finder reset = find.byTooltip(t.theme_role_reset);
      await tester.scrollUntilVisible(
        reset,
        120,
        scrollable: _verticalScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(find.byTooltip(t.theme_role_reset), findsNothing);

      await _tapApply(tester);
      expect(appModel.upserts.single.linkColor, isNull);
    });

    testWidgets('当前句高亮是全局偏好：改色/恢复立即写穿 AppModel', (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      await _tapRow(tester, t.theme_role_audio_highlight);
      await _pickInArea(tester);
      expect(appModel.audioHighlightWrites, isNotEmpty);
      expect(appModel.audioHighlightWrites.last, isNotNull);
      await tester.tap(find.text(t.dialog_done));
      await tester.pumpAndSettle();

      final Finder reset = find.byTooltip(t.theme_role_reset);
      await tester.scrollUntilVisible(
        reset,
        120,
        scrollable: _verticalScrollable,
      );
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(appModel.audioHighlightWrites.last, isNull);
    });
  });

  group('CustomThemePage · 宽屏两栏', () {
    testWidgets('≥ 900 宽：点角色行不弹窗，右栏选色器切到该角色', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      // 右栏常驻一个选色器（默认编辑主题色）。
      expect(find.byType(ColorPickerArea), findsOneWidget);
      expect(find.text(t.theme_role_accent), findsNWidgets(2));

      // 界面背景行在第一板块、不用滚动就可见（链接行在 800 高下已在视口外）。
      await tester.tap(find.text(t.theme_role_surface).first);
      await tester.pumpAndSettle();
      // 没弹窗：仍然只有一个选色器；右栏标题换成界面背景。
      expect(find.byType(ColorPickerArea), findsOneWidget);
      expect(find.text(t.dialog_done), findsNothing);
      expect(find.text(t.theme_role_surface), findsNWidgets(2));
      expect(find.text(t.theme_role_accent), findsOneWidget);
    });
  });
}
