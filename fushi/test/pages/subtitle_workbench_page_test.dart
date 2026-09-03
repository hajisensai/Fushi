import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 全屏字幕工作台：作用域开关只在「本集 + 合集」都有时出现；默认落本集；切换换面板。
class _Host implements SubtitleWorkbenchHost {
  _Host(this.database);

  @override
  final FushiDatabase database;
  @override
  VideoSubtitleRegistry? get subtitleRegistry =>
      VideoSubtitleRegistry(const <VideoSubtitleProvider>[]);
  @override
  String get jimakuApiKey => '';
  @override
  Future<void> setJimakuApiKey(String key) async {}
  @override
  Future<http.Client> createHttpClient() async =>
      MockClient((_) async => http.Response('', 404));
  @override
  String? preferredLanguageFor(String seriesKey) => null;
  @override
  Future<void> setPreferredLanguage(String seriesKey, String langCode) async {}
  @override
  String? get defaultContentLanguage => null;
  @override
  Future<void> persistRemoteSubtitle(String bookUid, String path) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory tempDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('subtitle_workbench_');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<SubtitleCollectionSpec> seedCollection() async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('video/show-01'),
        title: Value<String>('Show - 01'),
        videoPath: Value<String>('C:/video/Show - 01.mkv'),
      ),
    );
    final VideoBookRow member = (await VideoBookRepository(
      db,
    ).getByBookUid('video/show-01'))!;
    final int id = await db.createMediaCollection(
      'Show',
      collectionType: 'collection',
    );
    return SubtitleCollectionSpec(
      collection: (await db.getMediaCollectionById(id))!,
      members: <VideoBookRow>[member],
    );
  }

  const SubtitleEpisodeSearchSpec episode = SubtitleEpisodeSearchSpec(
    initialQuery: 'Show',
    seriesKey: 'show',
  );

  Widget wrap(Widget page) =>
      TranslationProvider(child: MaterialApp(home: page));

  testWidgets('有合集上下文：默认本集，作用域开关切到整个合集', (WidgetTester tester) async {
    final SubtitleCollectionSpec collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          episode: episode,
          collection: collection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.video_subtitle_workbench_title), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsOneWidget,
    );
    // 分段开关是纯图标 + tooltip（见页面里的溢出说明），按 tooltip 文案定位——
    // 它仍是同一条 i18n key，改名会连带这里一起红。
    await tester.tap(find.byTooltip(t.video_subtitle_scope_collection));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-collection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsNothing,
    );
  });

  testWidgets('只有本集：没有作用域开关', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          episode: episode,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-episode')),
      findsOneWidget,
    );
  });

  testWidgets('只有合集（库页入口）：直接落合集面板', (WidgetTester tester) async {
    final SubtitleCollectionSpec collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          collection: collection,
          initialScope: SubtitleWorkbenchScope.collection,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('subtitle-workbench-collection')),
      findsOneWidget,
    );
  });

  testWidgets('作用域开关与标题同一行：不再挂 AppBar.bottom 多占一行', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final SubtitleCollectionSpec collection = await seedCollection();
    await tester.pumpWidget(
      wrap(
        SubtitleWorkbenchPage(
          host: _Host(db),
          saveDirectory: tempDir.path,
          episode: episode,
          collection: collection,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<AppBar>(find.byType(AppBar)).bottom, isNull);
    // 同行判据是**垂直中心重合**：挂在 bottom 上时两者也都在 AppBar 里，但差着
    // 整整一行（56px），标题行右半边全空。
    final Rect title = tester.getRect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text(t.video_subtitle_workbench_title),
      ),
    );
    final Rect scope = tester.getRect(
      find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
    );
    expect((title.center.dy - scope.center.dy).abs(), lessThan(8));
  });

  // 360x780 = 常见手机竖屏。1400x900 那条用例照不到这里：`AppBar.actions` 不给
  // 子级宽度上界，带文字标签的分段开关宽度随译文长度走，宽屏永远撑得下。
  //
  // 语言必须遍历而不是只跑 zh：改动落地前实测 zh 只是把标题压到 44px（看着像
  // 「窄但没坏」），同一份布局在 en/de/fr/ru 下是 `RenderFlex overflowed by
  // 127~296 pixels`、标题宽度直接归零。只按中文验会整批漏掉。
  for (final AppLocale locale in <AppLocale>[
    AppLocale.zhCn,
    AppLocale.en,
    AppLocale.de,
    AppLocale.fr,
    AppLocale.ru,
  ]) {
    testWidgets('窄屏 360x780 AppBar 不溢出、标题留得住宽度（${locale.languageTag}）', (
      WidgetTester tester,
    ) async {
      LocaleSettings.setLocale(locale);
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final SubtitleCollectionSpec collection = await seedCollection();
      await tester.pumpWidget(
        wrap(
          SubtitleWorkbenchPage(
            host: _Host(db),
            saveDirectory: tempDir.path,
            episode: episode,
            collection: collection,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // ① 布局没溢出。`takeException` 必须在断言宽度**之前**取：溢出时子级仍会
      // 被摆到越界位置，只量宽度会看到一个「合理」的数字。
      expect(tester.takeException(), isNull, reason: '窄屏 AppBar 溢出（$locale）');

      // ② 开关和标题都还在同一行里，且开关没吃掉整条 AppBar。
      final Rect appBar = tester.getRect(find.byType(AppBar));
      final Rect scope = tester.getRect(
        find.byKey(const ValueKey<String>('subtitle-workbench-scope')),
      );
      expect(scope.right, lessThanOrEqualTo(appBar.right));
      final Finder titleFinder = find.descendant(
        of: find.byType(AppBar),
        matching: find.text(t.video_subtitle_workbench_title),
      );
      final Rect title = tester.getRect(titleFinder);
      // ③ 标题要么拿到它需要的全部宽度，要么至少拿到 AppBar 的 40%。
      //
      // 三处刻意的选择：
      // - 「自然宽度」独立于本次布局：拿 `RenderParagraph` 已解析好的 span 另跑
      //   一次**无界** `TextPainter`，不是把受约束后的渲染读两遍互相印证。
      // - 不写成 `title.width >= 某常量`：`字幕` 只有两个字，自然宽度本来就只有
      //   44px，常量判据会把「没被挤」误判成「被挤了」。
      // - 也不写成 `title.width == 自然宽度`：测试字体 Ahem 每个字符恰好一个字号
      //   宽，`Subtitles` 在这里量到 198px（真机约一半），窄屏下本来就该省略号
      //   收尾，苛求逐字等宽等于在测 Ahem 而不是测布局。
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
        titleFinder,
      );
      final TextPainter natural = TextPainter(
        text: paragraph.text,
        textDirection: paragraph.textDirection,
        textScaler: paragraph.textScaler,
      )..layout();
      final double titleBudget = math.min(natural.width, appBar.width * 0.4);
      expect(
        title.width,
        greaterThanOrEqualTo(titleBudget - 0.5),
        reason:
            '标题被开关挤掉（$locale：绘制 ${title.width}px / 自然 '
            '${natural.width}px / 底线 ${titleBudget}px）',
      );
      expect(title.right, lessThanOrEqualTo(scope.left));
    });
  }
}
