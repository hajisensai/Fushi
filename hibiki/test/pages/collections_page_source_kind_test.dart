import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1120：收藏夹页四值来源穷尽展示（widget 级）。
///
/// 旧实现用 isVideoSentence bool 把 book/video/audiobook/lyrics 4 值域降成
/// 「视频 vs 其它」两桶——audiobook/lyrics 句在列表来源前缀与长按弹窗图标上被
/// 静默展示成书。本测试 pump 真 CollectionsPage（范式照抄
/// collections_page_test.dart：path_provider mock + 内存库 +
/// wireDatabaseForTesting），各 seed 一条四来源收藏句，断言：
/// - 列表副标题：video 行含 nav_video、audiobook 行含 section_audiobook、
///   lyrics 行含 lyrics_mode、book 行无任何来源前缀；
/// - 长按弹窗：audiobook/lyrics 行图标非 movie_outlined（各自专属图标）且
///   打开按钮标签为 dialog_read（reader 是正确目的地）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collections_kind_pp');
    // AppModel 构造会惰性触碰 DefaultCacheManager → getApplicationSupportDirectory；
    // 不 mock 该 channel 会抛 MissingPluginException 异步泄漏到下一条测试。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = AppModel(testPlatformServices())..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedFourSourceFavorites() async {
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(db);
    // bookKey 全部非空 → 行可跳转（长按弹窗渲染打开按钮）。内存库无对应
    // SrtBook/Audiobook/VideoBook 行 → 音频解析路径全部空跳，不影响展示断言。
    await repo.add(FavoriteSentence(
      text: '本の文です。',
      bookTitle: 'BOOKTITLE_A',
      createdAt: DateTime(2026, 7, 20, 10),
      bookKey: 'book-key-a',
      source: kFavoriteSentenceSourceBook,
    ));
    await repo.add(FavoriteSentence(
      text: 'ビデオの文です。',
      bookTitle: 'VIDEOTITLE_B',
      createdAt: DateTime(2026, 7, 20, 11),
      bookKey: 'video-uid-b',
      source: kFavoriteSentenceSourceVideo,
    ));
    await repo.add(FavoriteSentence(
      text: '朗読の文です。',
      bookTitle: 'AUDIOBOOKTITLE_C',
      createdAt: DateTime(2026, 7, 20, 12),
      bookKey: 'book-key-c',
      source: kFavoriteSentenceSourceAudiobook,
    ));
    await repo.add(FavoriteSentence(
      text: '歌詞の文です。',
      bookTitle: 'LYRICSTITLE_D',
      createdAt: DateTime(2026, 7, 20, 13),
      bookKey: 'book-key-d',
      source: kFavoriteSentenceSourceLyrics,
    ));
  }

  Widget buildPage() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: CollectionsPage()),
        ),
      );

  /// 取「包含 [marker] 的副标题 Text」的完整字符串（列表行元数据）。
  String subtitleContaining(WidgetTester tester, String marker) {
    final Iterable<Text> texts = tester
        .widgetList<Text>(find.textContaining(marker))
        .where((Text w) => (w.data ?? '').contains(' · ') || w.data == marker);
    expect(texts, isNotEmpty, reason: '找不到含 "$marker" 的副标题');
    return texts.first.data!;
  }

  testWidgets('列表副标题按四值来源标注前缀（book 无前缀）', (WidgetTester tester) async {
    await seedFourSourceFavorites();

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 四条句子全部渲染。
    expect(find.text('本の文です。'), findsOneWidget);
    expect(find.text('ビデオの文です。'), findsOneWidget);
    expect(find.text('朗読の文です。'), findsOneWidget);
    expect(find.text('歌詞の文です。'), findsOneWidget);

    // video 行：前缀 nav_video。
    final String videoSub = subtitleContaining(tester, 'VIDEOTITLE_B');
    expect(videoSub, startsWith('${t.nav_video} · '));

    // audiobook 行：前缀 section_audiobook（旧 bool 降维下无前缀=展示成书）。
    final String abSub = subtitleContaining(tester, 'AUDIOBOOKTITLE_C');
    expect(abSub, startsWith('${t.section_audiobook} · '));

    // lyrics 行：前缀 lyrics_mode。
    final String lySub = subtitleContaining(tester, 'LYRICSTITLE_D');
    expect(lySub, startsWith('${t.lyrics_mode} · '));

    // book 行：无任何来源前缀。
    final String bookSub = subtitleContaining(tester, 'BOOKTITLE_A');
    expect(bookSub, startsWith('BOOKTITLE_A'));
    expect(bookSub, isNot(contains(t.section_audiobook)));
    expect(bookSub, isNot(contains(t.lyrics_mode)));
  });

  testWidgets('长按弹窗：audiobook/lyrics 行专属图标 + 打开按钮为 dialog_read', (
    WidgetTester tester,
  ) async {
    await seedFourSourceFavorites();

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // audiobook 行：headphones 图标，非 movie；按钮标签 READ（目的地是 reader）。
    await tester.longPress(find.text('朗読の文です。'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.headphones_outlined), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    expect(
      find.widgetWithText(FilledButton, t.dialog_read),
      findsOneWidget,
      reason: 'audiobook 句的打开目的地是 reader（bookKey 共享 fushi://book/ 身份）',
    );
    // 点击 barrier 关弹窗（showAppDialog 默认 barrierDismissible）。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // lyrics 行：lyrics 图标，非 movie；按钮标签 READ。
    await tester.longPress(find.text('歌詞の文です。'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.lyrics_outlined), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsNothing);
    expect(find.widgetWithText(FilledButton, t.dialog_read), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // video 行：movie 图标 + 按钮标签 nav_video（对照组，行为不变）。
    await tester.longPress(find.text('ビデオの文です。'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.widgetWithText(FilledButton, t.nav_video), findsOneWidget);
  });
}
