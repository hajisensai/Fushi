import 'dart:ui' show Color, Rect, Size;

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/cjk_font_families.dart'
    show CjkFontStyle, cjkFontsFor;
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/media_pref_keys.dart';

/// 歌词模式反馈批次：BUG-3279（竖排查词弹窗）/ BUG-3280（WebKit 竖排长句扫过
/// 消失）/ BUG-3281（标点字形与正文不一致）/ BUG-3282（滚动掉帧）以及每本书
/// 独立记忆歌词模式。
const LyricsHtmlTheme _theme = LyricsHtmlTheme(
  textColor: Color(0xFF888888),
  currentColor: Color(0xFF3366CC),
  accentColor: Color(0x553366CC),
  selectionTextColor: Color(0xFFFFFFFF),
  contextOpacities: <double>[0.6, 0.5, 0.4, 0.3],
  browsingOpacity: 0.7,
  deselectedScale: 0.95,
  anchorY: 0.45,
  edgeFade: 0.06,
  alignStart: true,
  contextBlurPx: 0,
  rowRadius: 16,
  hoverFill: Color(0x14000000),
);

AudioCue _cue(int i, String text) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _html({
  bool vertical = true,
  LyricsHtmlTheme? theme = _theme,
  String? contentLanguage = 'ja',
  String orientation = 'mixed',
  String fontFamilyCss = '',
  TargetPlatform platform = TargetPlatform.windows,
}) => LyricsModeHtml.generate(
  cues: <AudioCue>[_cue(0, '「“彼女”は言った」'), _cue(1, '雪ノ下を見る。')],
  currentIndex: 0,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
  vertical: vertical,
  theme: theme,
  contentLanguage: contentLanguage,
  verticalTextOrientation: orientation,
  fontFamilyCss: fontFamilyCss,
  platform: platform,
);

/// 选择器 → 声明块（只取不含嵌套花括号的规则）。
Map<String, String> _rules(String html) {
  final Map<String, String> out = <String, String>{};
  for (final RegExpMatch m in RegExp(
    r'([^{}]+)\{([^{}]*)\}',
  ).allMatches(html)) {
    out[m.group(1)!.trim().split('\n').last.trim()] = m.group(2)!;
  }
  return out;
}

void main() {
  group('BUG-3279 歌词竖排查词弹窗走左右避让', () {
    test('歌词模式按歌词自己的竖排开关判，不再一律横排', () {
      expect(
        readerPopupVerticalWriting(
          lyricsMode: true,
          lyricsVerticalWriting: true,
          writingMode: 'horizontal-tb',
        ),
        isTrue,
      );
      expect(
        readerPopupVerticalWriting(
          lyricsMode: true,
          lyricsVerticalWriting: false,
          writingMode: 'vertical-rl',
        ),
        isFalse,
        reason: '正文竖排不连坐横排歌词',
      );
      expect(
        readerPopupVerticalWriting(
          lyricsMode: false,
          lyricsVerticalWriting: true,
          writingMode: 'vertical-rl',
        ),
        isTrue,
      );
      expect(
        readerPopupVerticalWriting(
          lyricsMode: false,
          lyricsVerticalWriting: true,
          writingMode: null,
        ),
        isFalse,
      );
    });

    test('跨列的词（选区纵贯整屏）：竖排避让给出完整弹窗，横排只剩细缝', () {
      const Size screen = Size(1200, 800);
      // 词的前半在右列列底、后半在左邻列列顶：并集矩形几乎贯穿上下。
      const Rect crossColumn = Rect.fromLTRB(560, 12, 640, 790);
      final Rect horizontal = calcPopupPosition(
        selectionRect: crossColumn,
        screen: screen,
        maxWidth: 400,
        maxHeight: 400,
      );
      final Rect vertical = calcPopupPosition(
        selectionRect: crossColumn,
        screen: screen,
        maxWidth: 400,
        maxHeight: 400,
        verticalWriting: true,
      );
      // 修前（歌词模式恒按横排）：上下两侧都只剩几像素，弹窗被压扁。
      expect(horizontal.height, lessThan(20));
      expect(vertical.height, 400);
      expect(vertical.width, 400);
      expect(
        vertical.overlaps(crossColumn),
        isFalse,
        reason: '竖排避让放在列的左 / 右侧，不压被查的词',
      );
    });
  });

  group('BUG-3280 / BUG-3346 WebKit 竖排长句扫过不消失', () {
    // BUG-3346：iOS 模拟器实测 clone 与 slice 一样整句消失，只有把 .tx 变成
    // inline-block（原子盒）长句才看得见。CI 没有 WebKit，这里钉住规则形态。
    test('识别不了无前缀 slice 的引擎把 .tx 变成 inline-block', () {
      final String html = _html();
      final int at = html.indexOf(
        '@supports not (box-decoration-break: slice)',
      );
      expect(at, isNonNegative);
      final String block = html.substring(at, html.indexOf('}\n}', at) + 3);
      // 回退只限竖排：WebKit 上这条 @supports 恒成立；横排多行长句在 WebKit 上
      // slice 扫过正常（实测），改成 inline-block 反而丢掉跨行接续。
      final Map<String, String> fallbackRules = _rules(block);
      expect(fallbackRules.keys, <String>[
        'body.ly-sweep.ly-vertical:not(.ly-paused) '
            '.cue.current:not(.ly-nosweep) .tx',
      ]);
      expect(fallbackRules.values.single, contains('display: inline-block;'));
      // clone 在 WebKit 上照样消失，不能再作为回退出现。
      expect(html, isNot(contains('box-decoration-break: clone')));
      // .tx 只在竖排选择器下变 inline-block：横排扫过保持行内盒 + slice。
      final Iterable<MapEntry<String, String>> blockTx = _rules(html).entries
          .where(
            (MapEntry<String, String> e) =>
                e.key.contains('.tx') &&
                e.value.contains('display: inline-block'),
          );
      expect(blockTx, isNotEmpty);
      for (final MapEntry<String, String> e in blockTx) {
        expect(e.key, contains('.ly-vertical'), reason: e.key);
      }
      // 回退规则在扫过规则之后，同特异性下后者胜。
      expect(
        at,
        greaterThan(html.indexOf('-webkit-box-decoration-break: slice;')),
      );
    });
  });

  group('BUG-3281 歌词标点与正文同源', () {
    test('回退链 = 正文同款内容语言 CJK 链，不以拉丁系统字体打头', () {
      final String html = _html();
      final String chain = contentFontFamilyCss(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
        style: CjkFontStyle.sansSerif,
      );
      expect(chain, isNotEmpty);
      expect(html, contains('body { font-family: $chain; }'));
      final String bodyFont = RegExp(
        r'body \{ font-family: ([^;]*); \}',
      ).firstMatch(html)!.group(1)!;
      expect(bodyFont, isNot(contains('system-ui')));
      expect(bodyFont, isNot(contains('-apple-system')));
    });

    test('用户正文字体仍排在链首', () {
      final String html = _html(fontFamilyCss: '"MyFont"');
      expect(html, contains('body { font-family: "MyFont", '));
    });

    test('无主题（旧观感）用衬线链', () {
      final String html = _html(theme: null, platform: TargetPlatform.android);
      final String chain = contentFontFamilyCss(
        languageTag: 'ja',
        platform: TargetPlatform.android,
        style: CjkFontStyle.serif,
      );
      expect(html, contains('body { font-family: $chain; }'));
    });

    test('非 CJK / 未知内容语言不套日文 CJK 链（没有全局学习语言）', () {
      final Set<String> cjkFaces = <String>{
        for (final TargetPlatform p in <TargetPlatform>[
          TargetPlatform.windows,
          TargetPlatform.iOS,
        ])
          for (final CjkFontStyle s in CjkFontStyle.values)
            for (final List<String> fs in cjkFontsFor(p, s).values) ...fs,
      };
      String bodyFont(String html) => RegExp(
        r'body \{ font-family: ([^;]*); \}',
      ).firstMatch(html)!.group(1)!;
      String head(String chain) =>
          chain.split(',').first.trim().replaceAll('"', '');

      for (final String? lang in <String?>['en', 'es', null]) {
        for (final TargetPlatform p in <TargetPlatform>[
          TargetPlatform.windows,
          TargetPlatform.iOS,
        ]) {
          final String themed = bodyFont(
            _html(contentLanguage: lang, platform: p),
          );
          final String plain = bodyFont(
            _html(theme: null, contentLanguage: lang, platform: p),
          );
          for (final String chain in <String>[themed, plain]) {
            expect(cjkFaces, isNot(contains(head(chain))), reason: '$lang $p');
            for (final String face in cjkFaces) {
              expect(chain, isNot(contains('"$face"')), reason: '$lang $p');
            }
          }
          // 与正文 _bodyFontFamily 同口径：无主题落 serif。
          expect(plain, 'serif');
          expect(themed, 'system-ui, -apple-system, sans-serif');
        }
      }
      // 用户正文字体照旧排链首，后接通用族。
      expect(
        bodyFont(_html(contentLanguage: 'en', fontFamilyCss: '"MyFont"')),
        '"MyFont", system-ui, -apple-system, sans-serif',
      );
    });

    test('竖排字形朝向跟正文设置；横排不输出；非法值回落 mixed', () {
      expect(
        _html(orientation: 'upright'),
        contains('text-orientation: upright;'),
      );
      expect(
        _html(vertical: false, orientation: 'upright'),
        isNot(contains('text-orientation')),
      );
      expect(
        _html(orientation: 'x; color: red'),
        contains('text-orientation: mixed;'),
      );
    });
  });

  group('BUG-3282 歌词滚动不再给每行建合成层', () {
    test('will-change 只在当前行 ±3 的动画窗口', () {
      final Map<String, String> rules = _rules(_html());
      expect(rules['.cue'], isNotNull);
      expect(rules['.cue'], isNot(contains('will-change')));
      final String window = rules.keys.singleWhere(
        (String s) => s.startsWith('.cue.current, .cue.near-1'),
      );
      expect(rules[window], contains('will-change: transform, opacity;'));
      expect(
        'will-change'.allMatches(_html()).length,
        1,
        reason: '整页只有动画窗口这一处声明合成层',
      );
    });

    test('滚轮横竖排都接管成无极缓动，不再一格一跳', () {
      for (final bool vertical in <bool>[true, false]) {
        final String html = _html(vertical: vertical);
        final int at = html.indexOf(
          "window.addEventListener('wheel', function(e)",
        );
        expect(at, isNonNegative, reason: 'vertical=$vertical');
        final String handler = html.substring(
          at,
          html.indexOf('}, {passive: false});', at),
        );
        expect(handler, contains('e.preventDefault();'));
        expect(handler, contains('_lyWheelTarget += px;'));
        expect(handler, contains('requestAnimationFrame(_lyWheelFrame)'));
        // 一步落位只留给「减弱动态效果」与触控板这类小增量（本就连续）。
        final int direct = handler.indexOf(
          '_lySetAxisPos(s, _lyAxisPos(s) + px)',
        );
        expect(direct, isNonNegative);
        expect(
          handler.substring(0, direct),
          contains('if (window.__lyricsReduceMotion ||'),
        );
        // 不再只给竖排注册（横排原生滚轮同样逐格停顿）。
        expect(
          html,
          isNot(contains('if (__lyricsVertical) {\n  window.addEventListener')),
        );
      }
      final String html = _html();
      expect(
        html,
        contains('function __lyricsWheelStep(cur, target, dtMs, tauMs)'),
      );
      // 程序化回中接管时停掉在途滚轮动画。
      final int center = html.indexOf('function scrollToCenter(');
      expect(
        html.substring(center, html.indexOf('_animId++;', center)),
        contains('_lyWheelStop();'),
      );
    });
  });

  group('每本书独立记忆歌词模式', () {
    tearDown(() async {
      await ReaderFushiSource.instance.setLyricsMode(false);
    });

    test('没有本书记录时回落全局值；写入后各书独立', () async {
      final ReaderFushiSource src = ReaderFushiSource.instance;
      await src.setLyricsMode(true);
      expect(src.lyricsModeForBook('book-a'), isTrue, reason: '全局值当默认');

      await src.setLyricsModeForBook('book-a', false);
      await src.setLyricsModeForBook('book-b', true);
      expect(src.lyricsModeForBook('book-a'), isFalse);
      expect(src.lyricsModeForBook('book-b'), isTrue);
      // 全局值跟最近一次切换走：给没碰过的书当默认。
      expect(src.lyricsMode, isTrue);
      expect(src.lyricsModeForBook('book-c'), isTrue);

      await src.setLyricsModeForBook('book-b', false);
      expect(src.lyricsModeForBook('book-a'), isFalse);
      expect(src.lyricsModeForBook(null), isFalse);
    });

    test('每书记录不进 Profile 快照，全局默认值照旧随 Profile', () {
      final String perBook = dbSourcePrefKey(
        kReaderSourcePersistedKey,
        ReaderFushiSource.lyricsModeBookPrefKey('book-a'),
      );
      expect(perBook, startsWith(kLyricsModeBookPrefDbPrefix));
      expect(ProfileKeys.isExcludedPref(perBook), isTrue);
      expect(
        ProfileKeys.isExcludedPref(
          dbSourcePrefKey(kReaderSourcePersistedKey, 'lyrics_mode'),
        ),
        isFalse,
      );
    });
  });
}
