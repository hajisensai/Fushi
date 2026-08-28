import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show kCustomThemeDefaultSeed;
import 'package:fushi/src/pages/implementations/custom_theme_page.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1841：主题 swatch 行的「+新建」圈和「编辑」按钮（当前不在自定义主题上时）
/// 以前先 `upsertCustomTheme` 一条空主题再进编辑页——用户只是点开看看、什么都
/// 没改、直接返回，列表也已经多了一个主题。修后入口只 push 一个
/// `CustomThemePage(themeId: null)` 草稿，只有编辑页里点「应用」才写列表。
/// 这里用记录型 AppModel 直接断言 upsert 的调用次数与时机。
///
/// BUG-1894：其中「编辑按钮在没有活跃自定义主题时也开空草稿」这一支已被移除——
/// 它与「+」卡片行为完全相同，构成同一行里的重复入口。现在该状态下按钮禁用，
/// 空草稿入口唯一保留在「+」上；BUG-1841 的不落库不变式仍由本文件继续守。
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
  final List<String> themeKeyWrites = <String>[];

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
    final int idx =
        _themes.indexWhere((CustomThemeEntry e) => e.id == entry.id);
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
    themeKeyWrites.add(key);
    _themeKey = key;
  }

  @override
  Future<void> setAudioHighlightColor(Color? color) async {}

  @override
  Color? get audioHighlightColor => null;

  @override
  String get brightnessMode => 'light';

  @override
  bool get isDarkMode => false;

  @override
  Color? get systemPrimaryColor => const Color(0xFF1F4959);
}

const CustomThemeEntry _existing = CustomThemeEntry(
  id: 'ct-existing',
  name: 'Mine',
  seed: 0xFF336699,
  primaryColor: 0xFF112233,
);

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

/// 真实 swatch 行：`buildThemeSelector` 吃的就是生产 `SettingsContext`，
/// 不自拟副本，保证测的是用户点到的那两个入口。
Widget _swatchRowHost(_RecordingAppModel appModel) {
  return _host(
    appModel,
    Scaffold(
      body: Consumer(
        builder: (BuildContext context, WidgetRef ref, _) {
          return StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              final SettingsContext settingsContext = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () => setState(() {}),
              );
              return SingleChildScrollView(
                child: buildThemeSelector(settingsContext),
              );
            },
          );
        },
      ),
    ),
  );
}

/// 页面里第一个 Scrollable 是 AppBar 动作区的横向滚动条（80×40），拖它列表纹丝
/// 不动；必须按轴向挑出竖向那个正文列表。
final Finder _verticalScrollable = find
    .byWidgetPredicate(
      (Widget w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    )
    .first;

/// 编辑页是懒构建的滚动列表，「应用/删除」在首屏之外根本没被 build；先滚到
/// 它出现再点。swatch 行不需要滚（已可见时 scrollUntilVisible 立即返回）。
Future<void> _tapIcon(WidgetTester tester, IconData icon) async {
  final Finder finder = find.byIcon(icon);
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: _verticalScrollable,
  );
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// 滚到列表末尾，让末尾的按钮区被真正 build——「找不到删除按钮」只有在它
/// 本该出现的位置已经构建出来时才是有效证据。
Future<void> _scrollToEnd(WidgetTester tester) async {
  await tester.drag(_verticalScrollable, const Offset(0, -10000));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  group('BUG-1841 swatch row entry points open a draft without persisting', () {
    testWidgets('+new swatch pushes CustomThemePage(themeId: null), no upsert',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel =
          _RecordingAppModel(themes: <CustomThemeEntry>[_existing]);
      await tester.pumpWidget(_swatchRowHost(appModel));
      await tester.pumpAndSettle();

      await _tapIcon(tester, Icons.add);

      final CustomThemePage page =
          tester.widget<CustomThemePage>(find.byType(CustomThemePage));
      expect(page.themeId, isNull, reason: '+新建必须打开草稿而不是某个已落库 id');
      expect(appModel.upserts, isEmpty, reason: '打开编辑页不得写主题列表（BUG-1841 原症状）');
      expect(appModel.customThemes, hasLength(1), reason: '列表不能因为点了 + 就多出一条');
    });

    // BUG-1894：这条用例以前断言「预设主题上按编辑 → 打开空草稿」。那个回落让
    // 编辑按钮与左邻「+」卡片逐字节等价——同一行两个按钮做同一件事，挂着「编辑」
    // 图标的那个却在新建，和它的 tooltip 自相矛盾。现在没有可编辑对象时按钮直接
    // 禁用；BUG-1841 真正要守的「不得预先落库」由下面的 upserts 断言继续守着。
    testWidgets(
        'BUG-1894: edit button is disabled on a preset theme (no active custom '
        'entry) — it no longer duplicates the +new draft entry point',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel(
        themes: <CustomThemeEntry>[_existing],
        themeKey: 'light-theme',
      );
      await tester.pumpWidget(_swatchRowHost(appModel));
      await tester.pumpAndSettle();

      final Finder editIcon = find.byIcon(Icons.edit_outlined);
      await tester.scrollUntilVisible(
        editIcon,
        300,
        scrollable: _verticalScrollable,
      );
      await tester.ensureVisible(editIcon);
      await tester.pumpAndSettle();

      // 按钮仍然渲染（布局稳定、功能可发现），但 FushiIconButton 在 enabled=false
      // 时把 InkWell.onTap 置空 —— 点不动。
      final InkWell ink = tester.widget<InkWell>(
        find.ancestor(of: editIcon, matching: find.byType(InkWell)).first,
      );
      expect(ink.onTap, isNull,
          reason: '没有活跃自定义主题时编辑按钮必须禁用，而不是回落去开空草稿');

      await tester.tap(editIcon, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(CustomThemePage), findsNothing,
          reason: '禁用的编辑按钮不得打开编辑页——那正是与「+」重合的旧行为');
      expect(appModel.upserts, isEmpty, reason: '编辑按钮在预设主题上不得先造一条空主题');
      expect(appModel.customThemes, hasLength(1));
    });

    testWidgets('edit button on an active custom theme edits that entry',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel(
        themes: <CustomThemeEntry>[_existing],
        themeKey: 'custom-theme:${_existing.id}',
      );
      await tester.pumpWidget(_swatchRowHost(appModel));
      await tester.pumpAndSettle();

      await _tapIcon(tester, Icons.edit_outlined);

      final CustomThemePage page =
          tester.widget<CustomThemePage>(find.byType(CustomThemePage));
      expect(page.themeId, _existing.id);
      expect(appModel.upserts, isEmpty);
    });
  });

  group('BUG-1841 CustomThemePage draft mode', () {
    testWidgets(
        'opening a draft writes nothing; apply upserts exactly once with the '
        'brand default seed and pins the theme key to the new id',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel =
          _RecordingAppModel(themes: <CustomThemeEntry>[_existing]);
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      expect(appModel.upserts, isEmpty, reason: 'initState 不得落库草稿');
      expect(find.text(t.custom_theme_default_name(n: 2)), findsOneWidget,
          reason: '草稿默认名 hint 应为「Custom 列表长度+1」');

      await _scrollToEnd(tester);
      expect(find.byIcon(Icons.check), findsOneWidget,
          reason: '按钮区已构建（应用按钮可见），删除按钮的缺席才算数');
      expect(
        find.text(t.delete_custom_theme, skipOffstage: false),
        findsNothing,
        reason: '草稿没有东西可删，删除按钮不该出现',
      );

      await _tapIcon(tester, Icons.check);

      expect(appModel.upserts, hasLength(1));
      final CustomThemeEntry saved = appModel.upserts.single;
      expect(saved.seed, kCustomThemeDefaultSeed);
      expect(saved.name, '');
      expect(saved.primaryColor, isNull);
      expect(saved.id, isNot(_existing.id));
      expect(appModel.customThemes, hasLength(2));
      expect(appModel.themeKeyWrites, <String>['custom-theme:${saved.id}']);
    });

    testWidgets('leaving a draft without applying persists nothing',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel = _RecordingAppModel();
      await tester.pumpWidget(_host(appModel, const CustomThemePage()));
      await tester.pumpAndSettle();

      // 模拟返回：直接把页面卸掉（等价于 pop），草稿随 State 一起丢弃。
      await tester.pumpWidget(_host(appModel, const SizedBox.shrink()));
      await tester.pumpAndSettle();

      expect(appModel.upserts, isEmpty);
      expect(appModel.customThemes, isEmpty);
      expect(appModel.themeKeyWrites, isEmpty);
    });

    testWidgets('an existing entry is editable: prefilled name + delete button',
        (WidgetTester tester) async {
      final _RecordingAppModel appModel =
          _RecordingAppModel(themes: <CustomThemeEntry>[_existing]);
      await tester.pumpWidget(
        _host(appModel, CustomThemePage(themeId: _existing.id)),
      );
      await tester.pumpAndSettle();

      expect(appModel.upserts, isEmpty);
      expect(find.text('Mine'), findsOneWidget);

      await _scrollToEnd(tester);
      expect(find.text(t.delete_custom_theme), findsOneWidget);

      await _tapIcon(tester, Icons.check);

      expect(appModel.upserts, hasLength(1));
      expect(appModel.upserts.single.id, _existing.id);
      expect(appModel.upserts.single.primaryColor, _existing.primaryColor);
      expect(appModel.customThemes, hasLength(1));
    });
  });
}
