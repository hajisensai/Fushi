import 'dart:ui' show Rect;

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/video_pause_ocr_scope.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

List<List<double>> _quad(double l, double t, double r, double b) =>
    <List<double>>[
      <double>[l, t],
      <double>[r, t],
      <double>[r, b],
      <double>[l, b],
    ];

void main() {
  // BUG-3314：《新・のび太の海底鬼岩城》PGS 第 3 条字幕贴在 1920×1080 帧上走暂停 OCR
  // 的真实结果——检测块框把注音区也框进来（812–1003），两行实际只在 826–885、
  // 890–951，第一行「（スタッフA）」横向只占 578–926。以前按行数均分块框、再沿整块
  // 宽度均分每行，第一行 7 个字被摊到 548–1377，点哪儿都查到别的字。
  group('暂停 OCR 点击框按识别器的行框落位', () {
    final MokuroBlock block = MokuroBlock(
      rectangle: const MokuroRect.fromLTRB(548.1, 812.5, 1376.9, 1003.1),
      isVertical: false,
      fontSize: 91,
      zIndex: 0,
      lines: const <String>['(スタッフA)', 'Aフレーム振り出しスロー'],
      linesCoords: <List<List<double>>>[
        _quad(578.3, 826.4, 926.2, 885.2),
        _quad(604.1, 889.9, 1348.8, 951.0),
      ],
    );
    const Rect line1 = Rect.fromLTRB(578.3, 826.4, 926.2, 885.2);
    const Rect line2 = Rect.fromLTRB(604.1, 889.9, 1348.8, 951.0);

    test('每个字都落在自己那一行的行框里', () {
      final List<GraphicSubtitleOcrChar> chars = graphicSubtitleOcrCharsOf(
        block,
      );
      final int firstLineLength = block.lines.first.characters.length;
      expect(chars, hasLength(block.lines.join().characters.length));
      for (final GraphicSubtitleOcrChar char in chars) {
        final Rect line = char.graphemeIndex < firstLineLength ? line1 : line2;
        expect(
          line.inflate(0.01).contains(char.rect.center),
          isTrue,
          reason: '第 ${char.graphemeIndex} 个字 ${char.rect} 不在 $line 里',
        );
        expect(char.rect.top, closeTo(line.top, 0.01));
        expect(char.rect.bottom, closeTo(line.bottom, 0.01));
      }
      expect(chars.first.rect.left, closeTo(578.3, 0.01));
      expect(chars.first.sentence, '(スタッフA)Aフレーム振り出しスロー');
    });

    test('没有行框（旧缓存）时仍按块均分，不丢字', () {
      final MokuroBlock legacy = MokuroBlock(
        rectangle: block.rectangle,
        isVertical: false,
        fontSize: 91,
        zIndex: 0,
        lines: block.lines,
      );
      expect(
        graphicSubtitleOcrCharsOf(legacy),
        hasLength(block.lines.join().characters.length),
      );
    });

    // 审查回归：字级区域是旧文字的偏移（文字已被大模型改写变长），有一个对不上就
    // 整块改走行框，而不是逐个丢掉对不上的、留下残缺的可点框。
    test('字级区域有一个对不上文字时整块改按行框落位，不留残缺框', () {
      final MokuroBlock stale = MokuroBlock(
        rectangle: block.rectangle,
        isVertical: false,
        fontSize: 91,
        zIndex: 0,
        lines: block.lines,
        linesCoords: block.linesCoords,
        regions: const <MangaOcrTextRegion>[
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTRB(0, 0, 10, 10),
            utf16Start: 0,
            utf16End: 1,
          ),
          // 超出句长：对不上。
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTRB(10, 0, 20, 10),
            utf16Start: 999,
            utf16End: 1000,
          ),
        ],
      );
      final List<GraphicSubtitleOcrChar> chars = graphicSubtitleOcrCharsOf(
        stale,
      );
      expect(chars, hasLength(block.lines.join().characters.length));
      expect(chars.first.rect.left, closeTo(578.3, 0.01));
      expect(chars.first.rect.top, closeTo(826.4, 0.01));
    });

    test('字级区域全部对得上时照用引擎给的区域', () {
      final MokuroBlock lens = MokuroBlock(
        rectangle: block.rectangle,
        isVertical: false,
        fontSize: 91,
        zIndex: 0,
        lines: const <String>['あい'],
        regions: const <MangaOcrTextRegion>[
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTRB(1, 2, 3, 4),
            utf16Start: 0,
            utf16End: 1,
          ),
          MangaOcrTextRegion(
            rectangle: MokuroRect.fromLTRB(5, 6, 7, 8),
            utf16Start: 1,
            utf16End: 2,
          ),
        ],
      );
      expect(
        <Rect>[
          for (final GraphicSubtitleOcrChar c in graphicSubtitleOcrCharsOf(
            lens,
          ))
            c.rect,
        ],
        <Rect>[
          const Rect.fromLTRB(1, 2, 3, 4),
          const Rect.fromLTRB(5, 6, 7, 8),
        ],
      );
    });
  });

  group('VideoPauseOcrScope', () {
    test('BUG-3342：默认关闭（需用户手动开启）；未知值回退默认；存过的值照旧', () {
      expect(VideoPauseOcrScope.defaultScope, VideoPauseOcrScope.off);
      expect(VideoPauseOcrScope.fromWireName(null), VideoPauseOcrScope.off);
      expect(VideoPauseOcrScope.fromWireName('x'), VideoPauseOcrScope.off);
      for (final VideoPauseOcrScope scope in VideoPauseOcrScope.values) {
        expect(VideoPauseOcrScope.fromWireName(scope.wireName), scope);
      }
    });

    test('BUG-3342：只有识别关着且是图片字幕时才提示开启', () {
      expect(
        VideoPauseOcrScope.off.offersEnableHint(graphicSubtitleActive: true),
        isTrue,
      );
      expect(
        VideoPauseOcrScope.off.offersEnableHint(graphicSubtitleActive: false),
        isFalse,
        reason: '文本字幕 / 无字幕不提示',
      );
      for (final VideoPauseOcrScope on in <VideoPauseOcrScope>[
        VideoPauseOcrScope.all,
        VideoPauseOcrScope.graphicSubtitles,
      ]) {
        for (final bool graphic in <bool>[false, true]) {
          expect(
            on.offersEnableHint(graphicSubtitleActive: graphic),
            isFalse,
            reason: '已开启时不再提示',
          );
        }
      }
    });

    test('所有视频：图形字幕必识别；文字字幕在屏时让位，没有时识别画面', () {
      const VideoPauseOcrScope s = VideoPauseOcrScope.all;
      expect(
        s.shouldRecognize(
          graphicSubtitleActive: true,
          textCueOnScreen: false,
          textCuesLoading: false,
        ),
        isTrue,
      );
      expect(
        s.shouldRecognize(
          graphicSubtitleActive: false,
          textCueOnScreen: false,
          textCuesLoading: false,
        ),
        isTrue,
      );
      expect(
        s.shouldRecognize(
          graphicSubtitleActive: false,
          textCueOnScreen: true,
          textCuesLoading: false,
        ),
        isFalse,
      );
    });

    test('所有视频：内封文字字幕还在抽取时先不识别画面，图形字幕不受影响', () {
      const VideoPauseOcrScope s = VideoPauseOcrScope.all;
      expect(
        s.shouldRecognize(
          graphicSubtitleActive: false,
          textCueOnScreen: false,
          textCuesLoading: true,
        ),
        isFalse,
      );
      expect(
        s.shouldRecognize(
          graphicSubtitleActive: true,
          textCueOnScreen: false,
          textCuesLoading: true,
        ),
        isTrue,
      );
    });

    test('仅图片字幕 = 扩大前的行为；关闭则一律不识别', () {
      for (final bool text in <bool>[false, true]) {
        expect(
          VideoPauseOcrScope.graphicSubtitles.shouldRecognize(
            graphicSubtitleActive: true,
            textCueOnScreen: text,
            textCuesLoading: false,
          ),
          isTrue,
        );
        expect(
          VideoPauseOcrScope.graphicSubtitles.shouldRecognize(
            graphicSubtitleActive: false,
            textCueOnScreen: text,
            textCuesLoading: false,
          ),
          isFalse,
        );
        for (final bool graphic in <bool>[false, true]) {
          expect(
            VideoPauseOcrScope.off.shouldRecognize(
              graphicSubtitleActive: graphic,
              textCueOnScreen: text,
              textCuesLoading: false,
            ),
            isFalse,
          );
        }
      }
    });
  });
}
