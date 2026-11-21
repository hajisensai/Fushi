import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/fushi_icon_fonts.dart';
import '../helpers/test_platform_services.dart';

/// 设计稿 11-20 #18：手机端各模块页顶部大标题统一成书架的规格
/// （[FushiPageTitleMetrics]）。
///
/// 挂真的 [HomePage]（402×874，iPhone 17 逻辑尺寸），用 `debugSelectTab` 逐个切到
/// 十个模块页，量**画出来的**大标题：
///
/// - 字号：`TextStyle.fontSize` × 绘制缩放（页头大字随滚动在绘制层缩放、M3E
///   胶囊行会整行缩到 0.857，两种缩放都算进去）= 规格页名字号；
/// - 页名字面基线的全局 y 全部相等（切 tab 顶栏不跳）；
/// - 右端主按钮（有的页面）尺寸 = 规格主按钮，竖向中线相等。
///
/// 窄窗下有一级切换的库页（「书架 / 在线」）由切换的选中项当主标题，同样按页名
/// 字号量。查词页**不在统一范围内**：手机上按用户 2026-10-18 / 11-12 的拍板不画
/// 页头（底栏已标明「查词」），11-20 #18 复核时用户再次确认「查词页不加手机大
/// 标题，保持现状」；这里断言它没有大标题行，而不是放过不量。
///
/// 中文界面：测试默认字体 Ahem 的 CJK 度量接近真实字体、西文宽度失真，「放得下、
/// 不缩字号」只有中文可信。
class _ShellAppModel extends AppModel {
  _ShellAppModel(this._dir) : super(testPlatformServices());

  final Directory _dir;

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'app.hibiki.reader',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;

  @override
  bool moduleEnabled(ModuleId module) => true;

  // iPhone 上的游戏模块是纯串流接收端（无 texthooker 页签），不随跑测试的
  // 机器（Windows = 本机 galgame 库 / Mac 桌面 = 带 texthooker）变。
  @override
  GamesModuleForm get gamesModuleForm => GamesModuleForm.streamClient;

  @override
  bool get gamesOffersExternalTexthooker => false;

  // 查词页的历史区读词典库；本测试不量查词正文，给空历史。
  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      const <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
}

Future<void> _pumpHome(WidgetTester tester) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_title_metrics_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final _ShellAppModel appModel = _ShellAppModel(tmpDir)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db)
    ..populateLanguages()
    ..populateLocales()
    ..populateMediaTypes()
    ..populateMediaSources();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 一页大标题行的量值。
class _TitleRow {
  const _TitleRow({
    required this.text,
    required this.drawnFontSize,
    required this.baselineY,
    required this.primary,
  });

  final String text;
  final double drawnFontSize;
  final double baselineY;
  final Rect? primary;

  @override
  String toString() =>
      '"$text" font=${drawnFontSize.toStringAsFixed(2)} '
      'baseline=${baselineY.toStringAsFixed(2)} primary=$primary';
}

/// 当前可见 tab 的大字行（onstage 的 `floating-chrome-row`，取最靠上的一行）。
Finder? _visibleMastheadRow(WidgetTester tester) {
  final List<Element> found = find
      .byKey(const ValueKey<String>('floating-chrome-row'))
      .evaluate()
      .toList();
  if (found.isEmpty) return null;
  double topOf(Element e) =>
      (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
  found.sort((Element a, Element b) => topOf(a).compareTo(topOf(b)));
  final Element top = found.first;
  return find.byElementPredicate((Element e) => e == top);
}

/// 大字行里的主标题：页名（`floating-chrome-shell-title`），没有页名时是一级
/// 切换里字号最大的那一项（选中项）。
_TitleRow _measure(WidgetTester tester, Finder row, HomeTab tab) {
  final Finder shellTitle = find.descendant(
    of: row,
    matching: find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
  );
  final Iterable<Element> candidates = find
      .descendant(
        of: shellTitle.evaluate().isNotEmpty ? shellTitle : row,
        matching: find.byType(RichText),
      )
      .evaluate();
  RenderParagraph? best;
  double bestFont = -1;
  for (final Element e in candidates) {
    final RenderParagraph p = e.renderObject! as RenderParagraph;
    final String plain = p.text.toPlainText().trim();
    if (plain.isEmpty || plain == '/') continue;
    final double styleFont = p.text.style?.fontSize ?? 0;
    // 放不下时的缩放可能走 textScaler（一级切换项），算进画出来的字号。
    final double font = styleFont == 0 ? 0 : p.textScaler.scale(styleFont);
    if (font > bestFont) {
      bestFont = font;
      best = p;
    }
  }
  expect(best, isNotNull, reason: '$tab：大字行里找不到主标题');
  final RenderParagraph title = best!;
  // 绘制缩放：父链上的 paint transform（滚动收缩 / 胶囊整行缩放）都算进去。
  final double top = title.localToGlobal(Offset.zero).dy;
  final double scale =
      (title.localToGlobal(const Offset(0, 100)).dy - top) / 100;
  final TextPainter painter = TextPainter(
    text: title.text,
    textDirection: TextDirection.ltr,
    textScaler: title.textScaler,
    maxLines: 1,
  )..layout();
  final double baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  painter.dispose();
  final Finder primary = find.descendant(
    of: row,
    matching: find.byKey(const ValueKey<String>('floating-chrome-primary')),
  );
  return _TitleRow(
    text: title.text.toPlainText(),
    drawnFontSize: bestFont * scale,
    baselineY: title.localToGlobal(Offset(0, baseline)).dy,
    primary: primary.evaluate().isEmpty ? null : tester.getRect(primary),
  );
}

/// 长标题语言下的一页：主标题字号、主按钮、是否有文字被截断 / 越出 / 压到动作。
Future<void> _expectLongLocaleRow(
  WidgetTester tester,
  HomeTab tab,
  String tag,
) async {
  const FushiPageTitleMetrics m = FushiPageTitleMetrics.phone;
  final Finder row = _visibleMastheadRow(tester)!;
  final _TitleRow measured = _measure(tester, row, tab);
  expect(
    measured.drawnFontSize,
    greaterThanOrEqualTo(
      m.titleFontSize * FushiPageTitleMetrics.minTitleScale - 0.01,
    ),
    reason: '$tag：主标题缩过了规格的 85%：$measured',
  );
  final Rect? primary = measured.primary;
  if (primary != null) {
    expect(
      primary.width,
      greaterThanOrEqualTo(
        m.primaryExtent * FushiPageTitleMetrics.minTitleScale,
      ),
      reason: '$tag：主按钮被压小：$primary',
    );
  }
  final Rect rowRect = tester.getRect(row);
  final Finder actions = find.descendant(
    of: row,
    matching: find.byKey(const ValueKey<String>('floating-chrome-actions')),
  );
  final List<Rect> blockers = <Rect>[
    ?primary,
    if (actions.evaluate().isNotEmpty) tester.getRect(actions),
  ];
  for (final Element e
      in find.descendant(of: row, matching: find.byType(RichText)).evaluate()) {
    final RenderParagraph p = e.renderObject! as RenderParagraph;
    final double font = p.text.style?.fontSize ?? 0;
    // 只看页名 / 一级切换的大字（动作图标字形 24、二级页签小字不在此列）。
    if (font < FushiPageTitleMetrics.headlineIdleFontSize * 0.8) continue;
    if (font == FushiPageTitleMetrics.actionIconSize) continue;
    final String text = p.text.toPlainText();
    expect(p.didExceedMaxLines, isFalse, reason: '$tag：「$text」被截断');
    final Rect r = MatrixUtils.transformRect(
      p.getTransformTo(null),
      Offset.zero & p.size,
    );
    expect(
      r.left >= rowRect.left - 0.5 && r.right <= rowRect.right + 0.5,
      isTrue,
      reason: '$tag：「$text」$r 越出页头 $rowRect',
    );
    for (final Rect b in blockers) {
      expect(
        r.intersect(b).isEmpty ||
            r.intersect(b).width <= 0.5 ||
            r.intersect(b).height <= 0.5,
        isTrue,
        reason: '$tag：「$text」$r 压到右侧按钮 $b',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  test('规格取自书架（库页）当时的实际代码', () {
    const FushiPageTitleMetrics m = FushiPageTitleMetrics.phone;
    expect(m.titleFontSize, 46);
    expect(FushiPageTitleMetrics.titleWeight, FontWeight.w900);
    expect(m.badgeExtent, 22);
    expect(FushiPageTitleMetrics.actionExtent, 48);
    expect(FushiPageTitleMetrics.actionIconSize, 24);
    expect(m.primaryExtent, 48);
    expect(
      FushiPageTitleMetrics.headlineIdleFontSize,
      lessThan(m.titleFontSize),
      reason: '副段缩小',
    );
  });

  testWidgets('402×874 下十个模块页的大标题字号 / 基线 / 主按钮全部一致', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    addTearDown(tester.view.reset);
    await _pumpHome(tester);
    expect(HomePage.debugSelectTab, isNotNull);

    final Map<HomeTab, _TitleRow> rows = <HomeTab, _TitleRow>{};
    for (final HomeTab tab in <HomeTab>[
      HomeTab.books,
      HomeTab.home,
      HomeTab.manga,
      HomeTab.video,
      HomeTab.music,
      HomeTab.games,
      HomeTab.browse,
      HomeTab.srs,
      HomeTab.settings,
      HomeTab.dictionaries,
    ]) {
      HomePage.debugSelectTab!(tab);
      await _settle(tester);
      final Finder? row = _visibleMastheadRow(tester);
      if (tab == HomeTab.dictionaries) {
        expect(row, isNull, reason: '查词页手机上不画页头大字（用户 2026-10-18 / 11-12 拍板）');
        continue;
      }
      expect(row, isNotNull, reason: '$tab：没有页头大字行');
      rows[tab] = _measure(tester, row!, tab);
    }

    final String table = rows.entries
        .map((MapEntry<HomeTab, _TitleRow> e) => '${e.key.name}: ${e.value}')
        .join('\n');
    final _TitleRow shelf = rows[HomeTab.books]!;
    final Rect refPrimary = rows.values
        .map((_TitleRow r) => r.primary)
        .whereType<Rect>()
        .first;
    const FushiPageTitleMetrics m = FushiPageTitleMetrics.phone;
    for (final MapEntry<HomeTab, _TitleRow> e in rows.entries) {
      expect(
        e.value.drawnFontSize,
        moreOrLessEquals(m.titleFontSize, epsilon: 0.01),
        reason: '${e.key.name} 的大标题字号不是规格值\n$table',
      );
      expect(
        e.value.baselineY,
        moreOrLessEquals(shelf.baselineY, epsilon: 0.5),
        reason: '${e.key.name} 的标题基线与书架不在同一条线\n$table',
      );
      final Rect? primary = e.value.primary;
      if (primary != null) {
        expect(
          primary.size,
          Size.square(m.primaryExtent),
          reason: '${e.key.name} 的右端主按钮不是规格尺寸\n$table',
        );
        expect(
          primary.center.dy,
          moreOrLessEquals(refPrimary.center.dy, epsilon: 0.5),
          reason: '${e.key.name} 的主按钮中线与其它页不齐\n$table',
        );
      }
    }
    expect(rows[HomeTab.home]!.primary, isNotNull, reason: '首页头像坐在主按钮位');
    // ignore: avoid_print
    print('TITLE METRICS\n$table');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 10));
  });

  // 长标题语言（德语 / 俄语）放不下时：动作先收进「⋯」，主标题最多缩到规格
  // 85%，再不够就换到单独一行 / 按词换行；主按钮不缩，不截断、不出省略号。
  // 测试字体每个字形 1em 宽，西文比真实字体宽得多，是比真机更严的情形。
  for (final AppLocale locale in <AppLocale>[AppLocale.de, AppLocale.ru]) {
    for (final Size view in const <Size>[Size(402, 874), Size(360, 800)]) {
      final String size = '${view.width.toInt()}×${view.height.toInt()}';
      testWidgets('${locale.name} $size：主标题 ≥ 规格 85%、主按钮不缩、文字不截断', (
        WidgetTester tester,
      ) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = view * 3;
        addTearDown(tester.view.reset);
        // 真实像素预览（FUSHI_PREVIEW_DIR）：图标字体 + 系统西文黑体，否则是
        // 测试字体的方块。断言不依赖它。
        final String? shotDir = Platform.environment['FUSHI_PREVIEW_DIR'];
        if (shotDir != null) {
          await tester.runAsync(() async {
            await loadFushiIconFonts();
            final Uint8List bytes = await File(
              r'C:\Windows\Fonts\seguibl.ttf',
            ).readAsBytes();
            for (final String family in <String>[
              'Roboto',
              '.SF UI Text',
              '.SF Pro Text',
              '.SF UI Display',
              '.SF Pro Display',
            ]) {
              await (FontLoader(family)..addFont(
                    Future<ByteData>.value(ByteData.sublistView(bytes)),
                  ))
                  .load();
            }
          });
        }
        LocaleSettings.setLocale(locale);
        await _pumpHome(tester);
        final Map<String, ui.Image> shots = <String, ui.Image>{};
        for (final HomeTab tab in <HomeTab>[
          HomeTab.home,
          HomeTab.books,
          HomeTab.manga,
          HomeTab.video,
          HomeTab.music,
          HomeTab.games,
          HomeTab.browse,
          HomeTab.srs,
          HomeTab.settings,
        ]) {
          HomePage.debugSelectTab!(tab);
          await _settle(tester);
          await _expectLongLocaleRow(
            tester,
            tab,
            '${locale.name} $size ${tab.name}',
          );
          if (shotDir != null &&
              (tab == HomeTab.video || tab == HomeTab.browse)) {
            final RenderRepaintBoundary boundary = tester
                .renderObjectList<RenderRepaintBoundary>(
                  find.byType(RepaintBoundary),
                )
                .first;
            // 同步取图，编码留到页面卸载之后：页面还挂着时让出真实异步，
            // 首页 initState 里排队的弹窗流程会接着跑（测试里没接主题）。
            shots['title_${locale.name}_${view.width.toInt()}_${tab.name}'] =
                boundary.toImageSync(pixelRatio: 1);
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(Duration.zero);
        await tester.pump(const Duration(milliseconds: 10));
        if (shotDir != null) {
          await tester.runAsync(() async {
            for (final MapEntry<String, ui.Image> e in shots.entries) {
              final ByteData? png = await e.value.toByteData(
                format: ui.ImageByteFormat.png,
              );
              e.value.dispose();
              File(
                '$shotDir/${e.key}.png',
              ).writeAsBytesSync(png!.buffer.asUint8List());
            }
          });
        }
      });
    }
  }
}
