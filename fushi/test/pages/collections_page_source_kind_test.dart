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

  testWidgets('列表按来源标注前缀（book 无前缀），书名升级为媒体小节头', (
    WidgetTester tester,
  ) async {
    // 阶段 3（收藏夹按合集/媒体分节）：所属书/视频名不再拼进行副标题，而是
    // 作为媒体小节头独立成行；来源前缀（BUG-1120 四值穷尽）仍在行副标题。
    await seedFourSourceFavorites();

    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // 四条句子全部渲染。
    expect(find.text('本の文です。'), findsOneWidget);
    expect(find.text('ビデオの文です。'), findsOneWidget);
    expect(find.text('朗読の文です。'), findsOneWidget);
    expect(find.text('歌詞の文です。'), findsOneWidget);

    // 四个媒体小节头（书名/视频名独立成行，不再藏在副标题里）。
    expect(find.text('BOOKTITLE_A'), findsOneWidget);
    expect(find.text('VIDEOTITLE_B'), findsOneWidget);
    expect(find.text('AUDIOBOOKTITLE_C'), findsOneWidget);
    expect(find.text('LYRICSTITLE_D'), findsOneWidget);

    // 来源前缀各自恰好一处（四行只有对应行标注；book 行无前缀，故各前缀
    // findsOneWidget 同时排除了「book 行被贴前缀」的旧降维回归）。
    expect(find.textContaining(t.nav_video), findsOneWidget);
    expect(find.textContaining(t.section_audiobook), findsOneWidget);
    expect(find.textContaining(t.lyrics_mode), findsOneWidget);
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
