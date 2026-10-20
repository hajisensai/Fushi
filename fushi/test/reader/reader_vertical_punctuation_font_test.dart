import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_vertical_punctuation_font.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-3606：竖排引号方向不一致（「」、。横着躺、ー …… 竖着）。
///
/// 根因：竖排 mixed 下这些标点靠字体的 `vert` 换竖排字形，Blink 在字体缺 `vert` 时不旋转、
/// 直接画横排字形。修法：竖排时正文字体链首放随包标点子集（带 `vert`，unicode-range 只覆盖
/// 这些标点），横排不注入。这里钉 CSS 生成层；真 Chrome 渲染断言见
/// `vertical_punctuation_render_test.dart`。
void main() {
  Future<ReaderSettings> settingsFor({
    required String writingMode,
    required String viewMode,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
    return settings;
  }

  /// 正文 `body` 规则里的 font-family 值（三种布局各一份 body 规则，取全部）。
  List<String> bodyFamilies(String css) => RegExp(
    r'font-family: ([^;]*) !important;',
  ).allMatches(css).map((RegExpMatch m) => m.group(1)!).toList();

  const String family = ReaderVerticalPunctuationFont.family;

  group('正文 CSS', () {
    for (final String viewMode in <String>['paginated', 'continuous', 'vn']) {
      test('竖排 $viewMode：链首是标点子集，@font-face 带 unicode-range', () async {
        final ReaderSettings settings = await settingsFor(
          writingMode: 'vertical-rl',
          viewMode: viewMode,
        );
        for (final String css in <String>[
          ReaderContentStyles.css(settings: settings),
          ReaderContentStyles.css(
            settings: settings,
            fontFaces: '@font-face { font-family: "UserFont"; }',
            fontFamily: '"UserFont"',
          ),
        ]) {
          final List<String> families = bodyFamilies(css);
          expect(families, isNotEmpty);
          for (final String f in families) {
            expect(f, startsWith('"$family", '));
          }
          expect(css, contains(ReaderVerticalPunctuationFont.fontFace()));
          expect(
            css,
            contains(
              'unicode-range: ${ReaderVerticalPunctuationFont.unicodeRange};',
            ),
          );
          expect(css, contains(ReaderVerticalPunctuationFont.urlPath));
        }
      });

      test('横排 $viewMode：完全不出现', () async {
        final ReaderSettings settings = await settingsFor(
          writingMode: 'horizontal-tb',
          viewMode: viewMode,
        );
        final String css = ReaderContentStyles.css(settings: settings);
        expect(css, isNot(contains(family)));
        expect(css, isNot(contains(ReaderVerticalPunctuationFont.urlPath)));
      });
    }

    test('用户字体仍紧跟在标点子集之后', () async {
      final ReaderSettings settings = await settingsFor(
        writingMode: 'vertical-rl',
        viewMode: 'paginated',
      );
      final String css = ReaderContentStyles.css(
        settings: settings,
        fontFaces: '@font-face { font-family: "UserFont"; }',
        fontFamily: '"UserFont"',
      );
      expect(bodyFamilies(css).first, startsWith('"$family", "UserFont"'));
    });
  });

  group('歌词竖排共用同一子集', () {
    String lyrics({required bool vertical}) => LyricsModeHtml.generate(
      cues: <AudioCue>[
        AudioCue()
          ..id = 1
          ..bookKey = 'book'
          ..chapterHref = 'chapter'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = '「床に」'
          ..startMs = 0
          ..endMs = 900
          ..audioFileIndex = 0,
      ],
      currentIndex: 0,
      backgroundColor: 'transparent',
      textColor: '#888888',
      accentColor: '#3366cc',
      fontSize: 24,
      vertical: vertical,
      contentLanguage: 'ja',
    );

    test('竖排注入并排链首', () {
      final String html = lyrics(vertical: true);
      expect(html, contains(ReaderVerticalPunctuationFont.fontFace()));
      expect(html, contains('body { font-family: "$family", '));
    });

    test('横排不注入', () {
      expect(lyrics(vertical: false), isNot(contains(family)));
    });
  });

  group('随包资产', () {
    test('子集字体是 WOFF2、体积小、unicode-range 覆盖「」、。', () {
      final File font = File(ReaderVerticalPunctuationFont.assetKey);
      expect(font.existsSync(), isTrue);
      final List<int> bytes = font.readAsBytesSync();
      expect(String.fromCharCodes(bytes.take(4)), 'wOF2');
      expect(bytes.length, lessThan(16 * 1024));
      bool covered(int cp) => ReaderVerticalPunctuationFont.codepointRanges.any(
        ((int, int) r) => cp >= r.$1 && cp <= r.$2,
      );
      for (final int cp in '「」『』、。（）'.runes) {
        expect(covered(cp), isTrue, reason: 'U+${cp.toRadixString(16)}');
      }
      // 本来就按旋转处理、与 vert 无关的字符不收，免得无谓换字形。
      for (final int cp in 'ー…‥—―'.runes) {
        expect(covered(cp), isFalse, reason: 'U+${cp.toRadixString(16)}');
      }
    });

    test('许可已登记（assets/licenses 自动注册）', () {
      final File license = File('assets/licenses/noto-serif-jp.txt');
      expect(license.existsSync(), isTrue);
      final String text = license.readAsStringSync();
      expect(text, contains('FushiVerticalPunctuation.woff2'));
      expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
    });

    test('阅读器拦截器下发这一固定路径', () {
      final String source = File(
        'lib/src/pages/implementations/reader_fushi/webview.part.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('if (path == ReaderVerticalPunctuationFont.urlPath)'),
      );
      expect(source, contains('ReaderVerticalPunctuationFont.assetKey'));
    });
  });
}
