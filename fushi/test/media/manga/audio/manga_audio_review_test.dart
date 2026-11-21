import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_review_page.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';

// 拍板台 olQnEI1iBV：演出稿复核在原页上高亮气泡，同屏改说话人并跳下一句。

const String _p = MangaAudioReviewView.keyPrefix;

MokuroBlock _block(double l, double t, double r, double b, {int z = 0}) =>
    MokuroBlock(
      rectangle: MokuroRect.fromLTRB(l, t, r, b),
      isVertical: true,
      fontSize: 20,
      zIndex: z,
      lines: const <String>['あ'],
    );

MangaScriptLine _line(
  int page,
  List<int> blocks, {
  String speaker = kTtsUnknown,
  double? confidence,
  TtsCastSource source = TtsCastSource.llm,
}) => MangaScriptLine(
  page: page,
  blocks: blocks,
  speaker: speaker,
  kind: CastLineKind.spoken,
  confidence: confidence,
  source: source,
);

/// 页 1000x1500，三块：0 左上、1 右下、2 与 0 重叠但 zIndex 更高。
final MokuroImage _image = MokuroImage(
  url: 'p1.jpg',
  size: const MokuroSize(1000, 1500),
  blocks: <MokuroBlock>[
    _block(100, 100, 300, 400),
    _block(600, 900, 900, 1300),
    _block(250, 300, 350, 500, z: 2),
  ],
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  group('复核队列', () {
    final MangaAudioScript script = MangaAudioScript(
      lines: <MangaScriptLine>[
        _line(2, <int>[0]), // 不明 → 待复核
        _line(0, <int>[1], speaker: 'そよ', confidence: 0.9), // 有把握
        _line(0, <int>[0], speaker: '爱音', confidence: 0.2), // 低把握
        _line(1, <int>[0], source: TtsCastSource.user), // 不明但用户确认过
      ],
    );

    test('按页序、页内按演出稿顺序；只看待复核时去掉有把握 / 手改的行', () {
      expect(mangaReviewQueue(script, pendingOnly: false), <String>[
        'p0b1',
        'p0b0',
        'p1b0',
        'p2b0',
      ]);
      expect(mangaReviewQueue(script, pendingOnly: true), <String>[
        'p0b0',
        'p2b0',
      ]);
    });

    test('从当前页开始：取第一条落在该页或之后的行，都在前面则从头', () {
      final List<String> q = mangaReviewQueue(script, pendingOnly: true);
      expect(mangaReviewStartIndex(script, q, 0), 0);
      expect(mangaReviewStartIndex(script, q, 1), 1);
      expect(mangaReviewStartIndex(script, q, 9), 0);
    });

    test('存完一句停在它在队列里的下一句；最后一句 / 不在队列里时为 null', () {
      const List<String> q = <String>['p0b0', 'p1b0', 'p2b0'];
      expect(mangaReviewNextIndex(q, 'p0b0'), 1);
      expect(mangaReviewNextIndex(q, 'p1b0'), 2);
      expect(mangaReviewNextIndex(q, 'p2b0'), isNull);
      expect(mangaReviewNextIndex(q, 'p9b0'), isNull);
    });

    test('块 → 句；原页坐标命中块时重叠取 zIndex 高的', () {
      expect(mangaLineOfBlock(script, 0, 1)?.speaker, 'そよ');
      expect(mangaLineOfBlock(script, 0, 2), isNull);
      expect(mangaBlockAt(_image, const Offset(150, 150)), 0);
      expect(mangaBlockAt(_image, const Offset(280, 350)), 2);
      expect(mangaBlockAt(_image, const Offset(700, 1000)), 1);
      expect(mangaBlockAt(_image, const Offset(500, 50)), isNull);
    });
  });

  Future<List<String>> pump(
    WidgetTester tester, {
    required bool glass,
    MangaScriptLine? line,
    bool locked = false,
    bool saving = false,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<String> calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          textTheme: Typography.material2021().black,
          glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
          glassDesign: glass,
        ),
        home: FushiGlassScope(
          child: Scaffold(
            body: MangaAudioReviewView(
              image: _image,
              line: line,
              text: '雨、やまないね',
              roster: const <TtsCastCharacter>[
                TtsCastCharacter(name: 'そよ'),
                TtsCastCharacter(name: '爱音'),
              ],
              position: 0,
              total: line == null ? 0 : 2,
              pendingOnly: true,
              pendingCount: 2,
              locked: locked,
              saving: saving,
              onFilter: (bool v) => calls.add('filter:$v'),
              onPrevious: () => calls.add('prev'),
              onNext: () => calls.add('next'),
              onSpeaker: (String s) => calls.add('speaker:$s'),
              onNewSpeaker: () => calls.add('new'),
              onBlockTap: (int b) => calls.add('block:$b'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  for (final bool glass in <bool>[false, true]) {
    final String design = glass ? 'Apple' : 'MD3';
    for (final Size size in <Size>[
      const Size(1280, 800),
      const Size(400, 860),
    ]) {
      testWidgets('$design ${size.width.toInt()}宽：高亮当前句的块，改说话人 / 确认 / 点气泡', (
        WidgetTester tester,
      ) async {
        final List<String> calls = await pump(
          tester,
          glass: glass,
          size: size,
          line: _line(0, <int>[0, 2]),
        );
        expect(tester.takeException(), isNull);
        final CustomPaint paint = tester.widget<CustomPaint>(
          find.byKey(const ValueKey<String>('$_p-highlight')),
        );
        final MangaReviewHighlightPainter painter =
            paint.painter! as MangaReviewHighlightPainter;
        expect(painter.highlight, <int>{0, 2});
        expect(painter.progress, 1);
        expect(painter.rects, hasLength(3));
        expect(find.text('雨、やまないね'), findsOneWidget);
        expect(
          find.byKey(const ValueKey<String>('$_p-position')),
          findsOneWidget,
        );
        expect(find.text('保留「不明」的台词用默认声线朗读'), findsOneWidget);

        await _tap(
          tester,
          find.byKey(const ValueKey<String>('$_p-speaker-そよ')),
        );
        await _tap(tester, find.byKey(const ValueKey<String>('$_p-confirm')));
        await _tap(tester, find.byKey(const ValueKey<String>('$_p-next')));
        await _tap(
          tester,
          find.byKey(const ValueKey<String>('$_p-new-speaker')),
        );

        // 点原页右下的块 1（OCR 坐标 750,1100）。
        final Finder page = find.byKey(const ValueKey<String>('$_p-page'));
        final Rect r = tester.getRect(page);
        final double scale = r.width / _image.size.width;
        await tester.tapAt(r.topLeft + const Offset(750, 1100) * scale);
        await tester.pump(const Duration(milliseconds: 500));

        expect(calls, <String>[
          'speaker:そよ',
          'speaker:$kTtsUnknown',
          'next',
          'new',
          'block:1',
        ]);
      });
    }

    testWidgets('$design：标注进行中只能看，不能改', (WidgetTester tester) async {
      final List<String> calls = await pump(
        tester,
        glass: glass,
        locked: true,
        line: _line(0, <int>[1], speaker: 'そよ', confidence: 0.2),
      );
      expect(find.byKey(const ValueKey<String>('$_p-locked')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('$_p-new-speaker')),
        findsNothing,
      );
      await _tap(tester, find.byKey(const ValueKey<String>('$_p-speaker-爱音')));
      await _tap(tester, find.byKey(const ValueKey<String>('$_p-confirm')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls, isEmpty);
    });

    testWidgets('$design：上一句还在存盘时不接受新的提交', (WidgetTester tester) async {
      final List<String> calls = await pump(
        tester,
        glass: glass,
        saving: true,
        line: _line(0, <int>[1], speaker: 'そよ', confidence: 0.2),
      );
      expect(find.byKey(const ValueKey<String>('$_p-locked')), findsNothing);
      await _tap(tester, find.byKey(const ValueKey<String>('$_p-speaker-爱音')));
      await _tap(tester, find.byKey(const ValueKey<String>('$_p-confirm')));
      await _tap(tester, find.byKey(const ValueKey<String>('$_p-new-speaker')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(calls, isEmpty);
    });

    testWidgets('$design：没有待复核的行显示空状态', (WidgetTester tester) async {
      await pump(tester, glass: glass);
      expect(find.byKey(const ValueKey<String>('$_p-empty')), findsOneWidget);
      expect(find.text('没有待复核的台词'), findsOneWidget);
    });
  }
}
