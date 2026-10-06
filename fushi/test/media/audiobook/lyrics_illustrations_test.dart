import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi_engine/epub/epub_book.dart';

/// 歌词模式插图（2026-10-07）：小图屏蔽判据、播放位置 → 插图映射、换图 / 回封面 /
/// 前后切换状态机。
LyricsIllustration _item(String key, int chapter, int offset) =>
    LyricsIllustration(
      key: key,
      position: LyricsBookPosition(chapter, offset),
      image: MemoryImage(Uint8List(0)),
    );

void main() {
  group('classifyLyricsIllustration 小图屏蔽', () {
    LyricsIllustrationVerdict judge(
      int w,
      int h, {
      bool inline = false,
      bool cover = false,
    }) => classifyLyricsIllustration(
      size: (width: w, height: h),
      sharesLineWithText: inline,
      isCover: cover,
    );

    test('整页插图 / 跨页大图 / 老书低清插图都通过', () {
      expect(judge(1072, 1528), LyricsIllustrationVerdict.illustration);
      expect(judge(2144, 1528), LyricsIllustrationVerdict.illustration);
      expect(judge(480, 640), LyricsIllustrationVerdict.illustration);
    });

    test('外字 / 章节号小图（宽高都 ≤ 256）被拒', () {
      expect(
        judge(32, 32, inline: true),
        LyricsIllustrationVerdict.inlineSized,
      );
      expect(judge(128, 64), LyricsIllustrationVerdict.inlineSized);
      expect(judge(256, 256), LyricsIllustrationVerdict.inlineSized);
    });

    test('分隔线 / 小装饰图（短边或面积太小）被拒', () {
      expect(judge(600, 40), LyricsIllustrationVerdict.tooSmall);
      expect(judge(300, 300), LyricsIllustrationVerdict.tooSmall);
    });

    test('横幅式标题条（长短边比 > 3）被拒', () {
      expect(judge(1500, 300), LyricsIllustrationVerdict.banner);
    });

    test('排在文字行里的高清外字被拒；带图注的大插图仍通过', () {
      expect(
        judge(420, 420, inline: true),
        LyricsIllustrationVerdict.inlineGlyph,
      );
      expect(
        judge(1072, 1528, inline: true),
        LyricsIllustrationVerdict.illustration,
      );
    });

    test('尺寸读不出（SVG）时只看排版', () {
      expect(
        classifyLyricsIllustration(size: null, sharesLineWithText: false),
        LyricsIllustrationVerdict.illustration,
      );
      expect(
        classifyLyricsIllustration(size: null, sharesLineWithText: true),
        LyricsIllustrationVerdict.inlineGlyph,
      );
    });

    test('封面（含同图另一份文件）不算插图', () {
      expect(judge(1072, 1528, cover: true), LyricsIllustrationVerdict.cover);
      const LyricsIllustrationFileProbe cover = (
        width: 1072,
        height: 1528,
        bytes: 300000,
      );
      expect(
        isSameImageAsCover((width: 1072, height: 1528, bytes: 300000), cover),
        isTrue,
      );
      expect(
        isSameImageAsCover((width: 1072, height: 1528, bytes: 299999), cover),
        isFalse,
      );
      expect(isSameImageAsCover(null, cover), isFalse);
    });
  });

  group('lastReachedLyricsIllustration 播放位置 → 插图', () {
    final List<LyricsIllustration> items = <LyricsIllustration>[
      _item('plate1', 1, 0), // 彩页（纯图章）
      _item('plate2', 2, 0),
      _item('mid', 5, 1200), // 第 5 章正文中段
      _item('end', 5, 4000),
    ];

    test('按（章, 章内偏移）比较，位置不早于插图才算到达', () {
      expect(
        lastReachedLyricsIllustration(items, const LyricsBookPosition(0, 50)),
        -1,
      );
      // 纯图章没有 cue：下一章的第一句一开始，前面的彩页都已走过。
      expect(
        lastReachedLyricsIllustration(items, const LyricsBookPosition(3, 0)),
        1,
      );
      expect(
        lastReachedLyricsIllustration(items, const LyricsBookPosition(5, 1199)),
        1,
      );
      expect(
        lastReachedLyricsIllustration(items, const LyricsBookPosition(5, 1200)),
        2,
      );
      expect(
        lastReachedLyricsIllustration(items, const LyricsBookPosition(9, 0)),
        3,
      );
    });
  });

  group('LyricsIllustrationController 状态机', () {
    List<LyricsIllustration> items() => <LyricsIllustration>[
      _item('a', 1, 0),
      _item('b', 2, 0),
      _item('c', 5, 1200),
    ];

    test('进歌词模式时已过的插图只记为已听到，不盖住封面', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(3, 10),
          audioPosition: const Duration(minutes: 30),
        );
      expect(c.reached, 1);
      expect(c.shown, isNull);
      expect(c.hasReached, isTrue);
      expect(c.browseStart, 1);
    });

    test('顺着播走过插图：换上插图并停住，点掉回封面', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(3, 10),
          audioPosition: const Duration(minutes: 30),
        );
      c.observe(
        const LyricsBookPosition(5, 900),
        audioPosition: const Duration(minutes: 30, seconds: 5),
      );
      expect(c.shown, isNull, reason: '还没到插图位置');
      c.observe(
        const LyricsBookPosition(5, 1300),
        audioPosition: const Duration(minutes: 30, seconds: 9),
      );
      expect(c.shown, 2);
      expect(c.shownIllustration!.key, 'c');
      // 继续播放不会自己收回。
      c.observe(
        const LyricsBookPosition(5, 1500),
        audioPosition: const Duration(minutes: 30, seconds: 14),
      );
      expect(c.shown, 2);
      c.dismiss();
      expect(c.shown, isNull);
    });

    test('一次走过多张彩页：从新走过的第一张看起', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(0, 0),
          audioPosition: Duration.zero,
        );
      c.observe(
        const LyricsBookPosition(3, 0),
        audioPosition: const Duration(seconds: 4),
      );
      expect(c.reached, 1);
      expect(c.shown, 0);
      expect(c.canShowPrevious, isFalse);
      expect(c.canShowNext, isTrue);
      c.showNext();
      expect(c.shown, 1);
      expect(c.canShowNext, isFalse, reason: '还没听到的插图不给翻');
      c.showNext();
      expect(c.shown, 1);
      c.showPrevious();
      expect(c.shown, 0);
    });

    test('拖进度条跨过插图只更新已听到范围，不弹出', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(0, 0),
          audioPosition: Duration.zero,
        );
      c.observe(
        const LyricsBookPosition(6, 0),
        audioPosition: const Duration(hours: 2),
      );
      expect(c.reached, 2);
      expect(c.shown, isNull);
    });

    test('往回 seek：超出已听到范围的插图收回封面', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(5, 1199),
          audioPosition: const Duration(minutes: 30),
        );
      c.observe(
        const LyricsBookPosition(5, 1250),
        audioPosition: const Duration(minutes: 30, seconds: 3),
      );
      expect(c.shown, 2);
      c.observe(
        const LyricsBookPosition(2, 5),
        audioPosition: const Duration(minutes: 3),
      );
      expect(c.reached, 1);
      expect(c.shown, isNull);
    });

    test('showAt 夹在已听到范围内；一张都没听到时不动', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(items(), position: const LyricsBookPosition(0, 0));
      c.showAt(2);
      expect(c.shown, isNull);
      expect(c.browseStart, isNull);
      c.load(items(), position: const LyricsBookPosition(3, 0));
      c.showAt(9);
      expect(c.shown, 1);
    });
  });

  test('selectLyricsIllustrations：封面（含同图另一份）与小图屏蔽，按书中顺序', () {
    EpubImageRef ref(
      String key,
      int chapter,
      int offset, {
      bool inline = false,
    }) => EpubImageRef(
      chapterIndex: chapter,
      orderInBook: 0,
      src: key,
      revealKey: key,
      charOffset: offset,
      sharesLineWithText: inline,
    );
    final LyricsIllustrationSelection selection = selectLyricsIllustrations(
      refs: <EpubImageRef>[
        ref('cover.jpg', kEpubCoverChapterIndex, 0),
        ref('cover_page.jpg', 0, 0),
        ref('kuchie1.jpg', 1, 0),
        ref('gaiji.png', 3, 40, inline: true),
        ref('rule.png', 3, 80),
        ref('plate.jpg', 3, 900),
        ref('missing.jpg', 4, 0),
      ],
      pathByKey: <String, String>{
        'cover.jpg': '/b/cover.jpg',
        'cover_page.jpg': '/b/cover_page.jpg',
        'kuchie1.jpg': '/b/kuchie1.jpg',
        'gaiji.png': '/b/gaiji.png',
        'rule.png': '/b/rule.png',
        'plate.jpg': '/b/plate.jpg',
      },
      probes: <String, LyricsIllustrationFileProbe>{
        '/b/cover.jpg': (width: 1072, height: 1528, bytes: 400000),
        '/b/cover_page.jpg': (width: 1072, height: 1528, bytes: 400000),
        '/b/kuchie1.jpg': (width: 2144, height: 1528, bytes: 900000),
        '/b/gaiji.png': (width: 48, height: 48, bytes: 900),
        '/b/rule.png': (width: 800, height: 24, bytes: 2000),
        '/b/plate.jpg': (width: 1072, height: 1528, bytes: 350000),
      },
      coverPath: '/b/cover.jpg',
    );
    expect(
      selection.items.map((LyricsIllustration i) => i.key).toList(),
      <String>['kuchie1.jpg', 'plate.jpg'],
    );
    expect(selection.items.last.position, const LyricsBookPosition(3, 900));
    expect(
      selection.verdicts['cover_page.jpg'],
      LyricsIllustrationVerdict.cover,
    );
    expect(
      selection.verdicts['gaiji.png'],
      LyricsIllustrationVerdict.inlineSized,
    );
    expect(selection.verdicts['rule.png'], LyricsIllustrationVerdict.tooSmall);
    expect(selection.verdicts.containsKey('missing.jpg'), isFalse);
  });
}
