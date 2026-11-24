import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart'
    show AudiobookPlayerController;
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:image/image.dart' as img;

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

    test('文件头认不出位图格式（SVG / 残缺 / 加扰）一律不当插图（BUG-5408）', () {
      expect(
        classifyLyricsIllustration(size: null, sharesLineWithText: false),
        LyricsIllustrationVerdict.undecodable,
      );
      expect(
        classifyLyricsIllustration(size: null, sharesLineWithText: true),
        LyricsIllustrationVerdict.undecodable,
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

    test('进歌词模式时基线位置解析不出：第一次观测只当基线，不弹出', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(items(), audioPosition: const Duration(minutes: 30));
      expect(c.reached, -1);
      c.observe(
        const LyricsBookPosition(3, 10),
        audioPosition: const Duration(minutes: 30, seconds: 2),
      );
      expect(c.reached, 1);
      expect(c.shown, isNull);
      // 之后顺着播走过下一张才弹出。
      c.observe(
        const LyricsBookPosition(5, 1300),
        audioPosition: const Duration(minutes: 30, seconds: 40),
      );
      expect(c.reached, 2);
      expect(c.shown, 2);
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

    test('showAt：未解锁的不放上插图位；一张都没听到时浏览从第一张看起', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(items(), position: const LyricsBookPosition(0, 0));
      c.showAt(2);
      expect(c.shown, isNull);
      expect(c.browseStart, 0, reason: '全部插图可浏览（遮着），不再是 null');
      c.load(items(), position: const LyricsBookPosition(3, 0));
      c.showAt(9);
      expect(c.shown, isNull, reason: '夹到最后一张，它还没听到：不动');
      c.showAt(1);
      expect(c.shown, 1);
      expect(
        (LyricsIllustrationController()..load(const <LyricsIllustration>[]))
            .browseStart,
        isNull,
      );
    });

    // 反馈 wV1kvoLjI3：大图浏览列出全部插图；还没听到的遮着，点一下揭开。揭开
    // 状态与阅读器共用（load 的 revealed 种子 + onReveal 回写）。
    test('未解锁 = 没听到且没揭开；揭开回写宿主，插图位翻页跳过未解锁的', () {
      final List<String> written = <String>[];
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..onReveal = written.add
        ..load(
          <LyricsIllustration>[...items(), _item('d', 7, 0)],
          position: const LyricsBookPosition(1, 5),
          revealed: const <String>['d'],
        );
      expect(c.reached, 0);
      expect(c.isLocked(0), isFalse);
      expect(c.isLocked(1), isTrue);
      expect(c.isLocked(2), isTrue);
      expect(c.isLocked(3), isFalse, reason: '阅读器里揭开过的不遮');
      expect(c.isLocked(-1), isTrue);
      expect(c.isLocked(9), isTrue);

      c.showAt(0);
      expect(c.canShowNext, isTrue, reason: '后面有揭开过的 d');
      c.showNext();
      expect(c.shown, 3, reason: '跳过未解锁的 b、c');
      c.showPrevious();
      expect(c.shown, 0);

      int notified = 0;
      c.addListener(() => notified++);
      c.reveal(1);
      expect(c.isLocked(1), isFalse);
      expect(written, <String>['b']);
      expect(notified, 1);
      c.reveal(1);
      expect(written, <String>['b'], reason: '重复揭开不重复回写');
      c.showNext();
      expect(c.shown, 1);
    });

    test('往回 seek：揭开过的插图留在插图位，没揭开的收回封面', () {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30),
        );
      c
        ..reveal(2)
        ..showAt(2);
      c.observe(
        const LyricsBookPosition(1, 5),
        audioPosition: const Duration(minutes: 3),
      );
      expect(c.reached, 0);
      expect(c.shown, 2, reason: '揭开过的不算剧透，不收回');
      c.showAt(1);
      expect(c.shown, 2, reason: 'b 未解锁：showAt 不动');
    });
  });

  // 反馈 yR5QF92EHO / BUG-4065：卡的弹出与收起必须成对。旧实现只有「停留结束」
  // 会收卡，图片暂停 0 秒 / 跳着经过插图 / 窗口不可见时卡永久留在左下角。
  group('LyricsIllustrationController 插图卡自动收起', () {
    List<LyricsIllustration> items() => <LyricsIllustration>[
      _item('a', 1, 0),
      _item('b', 2, 0),
      _item('c', 5, 1200),
    ];

    LyricsIllustrationController revealed() {
      final LyricsIllustrationController c = LyricsIllustrationController()
        ..load(
          items(),
          position: const LyricsBookPosition(3, 10),
          audioPosition: const Duration(minutes: 30),
        );
      expect(
        c.observe(
          const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30, seconds: 9),
        ),
        isTrue,
      );
      expect(c.cardVisible, isTrue);
      return c;
    }

    test('没有停留：到展示时长自动收卡，插图位仍留缩略图', () {
      fakeAsync((FakeAsync async) {
        final LyricsIllustrationController c = revealed();
        int notified = 0;
        c.addListener(() => notified++);
        async.elapse(
          lyricsIllustrationCardDisplayDuration(0) -
              const Duration(milliseconds: 1),
        );
        expect(c.cardVisible, isTrue);
        async.elapse(const Duration(milliseconds: 1));
        expect(c.cardVisible, isFalse);
        expect(c.shown, 2, reason: '只收卡，插图位不回封面');
        expect(notified, 1);
        expect(c.debugCardAutoClosePending, isFalse);
      });
    });

    test('展示时长跟「图片暂停」秒数走：0 秒用打开停留的默认秒数', () {
      expect(
        lyricsIllustrationCardDisplayDuration(12),
        const Duration(seconds: 12),
      );
      expect(
        lyricsIllustrationCardDisplayDuration(0),
        const Duration(seconds: AudiobookPlayerController.imagePauseOnSec),
      );
    });

    test('设了图片暂停秒数：没进停留的卡按该秒数收起（不是固定 5 秒）', () {
      fakeAsync((FakeAsync async) {
        final ValueNotifier<int> pause = ValueNotifier<int>(12);
        addTearDown(pause.dispose);
        final LyricsIllustrationController c = LyricsIllustrationController()
          ..imagePauseSec = pause
          ..load(
            items(),
            position: const LyricsBookPosition(3, 10),
            audioPosition: const Duration(minutes: 30),
          );
        expect(
          c.observe(
            const LyricsBookPosition(5, 1300),
            audioPosition: const Duration(minutes: 30, seconds: 9),
          ),
          isTrue,
        );
        async.elapse(const Duration(seconds: 11));
        expect(c.cardVisible, isTrue, reason: '12 秒的停留设置下 11 秒时卡还在');
        async.elapse(const Duration(seconds: 1));
        expect(c.cardVisible, isFalse);
        expect(c.shown, 2);
      });
    });

    test('停留接管（holdCardOpen）后不再按展示时长收卡', () {
      fakeAsync((FakeAsync async) {
        final LyricsIllustrationController c = revealed()..holdCardOpen();
        async.elapse(lyricsIllustrationCardDisplayDuration(0) * 3);
        expect(c.cardVisible, isTrue);
        // 停留结束由调用方收卡。
        c.closeCard();
        expect(c.cardVisible, isFalse);
      });
    });

    test('用户翻看插图 / 手动关卡 / 回封面 / 重新装载都作废计时', () {
      fakeAsync((FakeAsync async) {
        final LyricsIllustrationController browsing = revealed()..showAt(0);
        expect(browsing.debugCardAutoClosePending, isFalse);
        async.elapse(lyricsIllustrationCardDisplayDuration(0) * 2);
        expect(browsing.cardVisible, isTrue, reason: '用户接手后留到自己关');

        final LyricsIllustrationController closed = revealed()..closeCard();
        expect(closed.debugCardAutoClosePending, isFalse);

        final LyricsIllustrationController dismissed = revealed()..dismiss();
        expect(dismissed.debugCardAutoClosePending, isFalse);

        final LyricsIllustrationController reloaded = revealed()
          ..load(items(), position: const LyricsBookPosition(0, 0));
        expect(reloaded.debugCardAutoClosePending, isFalse);

        final LyricsIllustrationController disposed = revealed();
        disposed.dispose();
        expect(disposed.debugCardAutoClosePending, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('红点模式（不自动弹卡）不起计时', () {
      fakeAsync((FakeAsync async) {
        final LyricsIllustrationController c = LyricsIllustrationController()
          ..autoOpenCard = false
          ..load(
            items(),
            position: const LyricsBookPosition(3, 10),
            audioPosition: const Duration(minutes: 30),
          );
        c.observe(
          const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30, seconds: 9),
        );
        expect(c.shown, 2);
        expect(c.cardVisible, isFalse);
        expect(c.debugCardAutoClosePending, isFalse);
      });
    });
  });

  // 反馈 VaaRL9s3Tg：缩略图「新插图」提示点看过也不消失。旧实现提示点条件只有
  // 「插图位不是封面」，控制器没有「已看过」状态。
  group('LyricsIllustrationController 已看过（新插图提示点）', () {
    List<LyricsIllustration> items() => <LyricsIllustration>[
      _item('a', 1, 0),
      _item('b', 2, 0),
      _item('c', 5, 1200),
    ];

    LyricsIllustrationController dotMode() => LyricsIllustrationController()
      // 「红点」提示方式：不弹卡，只换缩略图 + 提示点。
      ..autoOpenCard = false
      ..load(
        items(),
        position: const LyricsBookPosition(1, 10),
        audioPosition: const Duration(minutes: 30),
      );

    test('换上新插图时未看过，打开大图（markSeen）后已看过，再换新插图又未看过', () {
      final LyricsIllustrationController c = dotMode();
      expect(c.shownUnseen, isFalse, reason: '封面没有提示点');
      expect(
        c.observe(
          const LyricsBookPosition(2, 10),
          audioPosition: const Duration(minutes: 30, seconds: 5),
        ),
        isTrue,
      );
      expect(c.shown, 1);
      expect(c.shownUnseen, isTrue);

      int notified = 0;
      c.addListener(() => notified++);
      c
        ..showAt(1)
        ..markSeen(1);
      expect(c.isSeen(1), isTrue);
      expect(c.shownUnseen, isFalse, reason: '打开过大图：提示点消失');
      expect(notified, 1);
      c.markSeen(1);
      expect(notified, 1, reason: '重复记已看过不再通知');

      expect(
        c.observe(
          const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30, seconds: 9),
        ),
        isTrue,
      );
      expect(c.shown, 2);
      expect(c.shownUnseen, isTrue, reason: '换上新插图：提示点重新出现');

      c.showAt(1);
      expect(c.shownUnseen, isFalse, reason: '翻回看过的那张不带提示点');
    });

    test('大图里翻页：showAt + markSeen 把翻到的页记为已看过', () {
      final LyricsIllustrationController c = dotMode()
        ..observe(
          const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30, seconds: 5),
        );
      expect(c.reached, 2);
      expect(c.isSeen(0), isFalse);
      c
        ..showAt(0)
        ..markSeen(0);
      expect(c.isSeen(0), isTrue);
      expect(c.isSeen(1), isFalse);
      c.markSeen(99);
      expect(c.isSeen(99), isFalse, reason: '越界下标忽略');
    });

    test('插图卡完整展示后自动收起：记为已看过，缩略图不再带提示点', () {
      fakeAsync((FakeAsync async) {
        final LyricsIllustrationController c = LyricsIllustrationController()
          ..load(
            items(),
            position: const LyricsBookPosition(3, 10),
            audioPosition: const Duration(minutes: 30),
          );
        c.observe(
          const LyricsBookPosition(5, 1300),
          audioPosition: const Duration(minutes: 30, seconds: 9),
        );
        expect(c.cardVisible, isTrue);
        expect(c.shownUnseen, isTrue, reason: '卡还没展示完');
        async.elapse(c.cardAutoCloseAfter + const Duration(milliseconds: 1));
        expect(c.cardVisible, isFalse);
        expect(c.shown, 2, reason: '插图位仍留缩略图');
        expect(c.isSeen(2), isTrue);
        expect(c.shownUnseen, isFalse);
      });
    });

    test('点 ✕ 回封面不算看过；重新装入同一批插图时看过的仍算看过', () {
      final LyricsIllustrationController c = dotMode()
        ..observe(
          const LyricsBookPosition(2, 10),
          audioPosition: const Duration(minutes: 30, seconds: 5),
        );
      c.dismiss();
      expect(c.isSeen(1), isFalse);
      c
        ..markSeen(0)
        ..load(
          items(),
          position: const LyricsBookPosition(1, 10),
          audioPosition: const Duration(minutes: 31),
        );
      expect(c.isSeen(0), isTrue);
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

  test('BUG-5408：EPUB 里加扰过的 PNG（文件头不是位图）经真实文件探测后不进插图列表', () {
    final Directory dir = Directory.systemTemp.createTempSync(
      'lyrics_undecodable_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    // 合法 PNG 头：签名 + IHDR（1072×1528）。
    Uint8List pngHead(int width, int height) {
      final ByteData d = ByteData(33);
      const List<int> sig = <int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ];
      for (int i = 0; i < sig.length; i++) {
        d.setUint8(i, sig[i]);
      }
      d.setUint32(8, 13);
      const List<int> ihdr = <int>[0x49, 0x48, 0x44, 0x52];
      for (int i = 0; i < ihdr.length; i++) {
        d.setUint8(12 + i, ihdr[i]);
      }
      d.setUint32(16, width);
      d.setUint32(20, height);
      d.setUint8(24, 8);
      d.setUint8(25, 3);
      return d.buffer.asUint8List();
    }

    final Uint8List plate = pngHead(1072, 1528);
    // 反馈 U5nBMFFVwO 那本书的 `bookwalker.png`：扩展名与 manifest 都说 PNG，
    // 字节却整段加扰（开头 b8 d2 1a c1 …），任何解码器都认不出。
    final Uint8List scrambled = Uint8List.fromList(
      List<int>.generate(plate.length, (int i) => plate[i] ^ 0x31),
    );
    final String platePath = '${dir.path}${Platform.pathSeparator}k001.png';
    final String scrambledPath =
        '${dir.path}${Platform.pathSeparator}bookwalker.png';
    File(platePath).writeAsBytesSync(plate);
    File(scrambledPath).writeAsBytesSync(scrambled);

    final Map<String, LyricsIllustrationFileProbe> probes =
        probeLyricsIllustrationFiles(<String>[platePath, scrambledPath]);
    EpubImageRef ref(String key, int chapter) => EpubImageRef(
      chapterIndex: chapter,
      orderInBook: 0,
      src: key,
      revealKey: key,
      charOffset: 0,
      sharesLineWithText: false,
    );
    final LyricsIllustrationSelection selection = selectLyricsIllustrations(
      refs: <EpubImageRef>[ref('k001.png', 1), ref('bookwalker.png', 34)],
      pathByKey: <String, String>{
        'k001.png': platePath,
        'bookwalker.png': scrambledPath,
      },
      probes: probes,
    );
    expect(
      selection.items.map((LyricsIllustration i) => i.key).toList(),
      <String>['k001.png'],
    );
    expect(
      selection.verdicts['bookwalker.png'],
      LyricsIllustrationVerdict.undecodable,
    );
  });

  testWidgets('BUG-5408：探针不比解码器挑剔——段间夹杂字节的 JPEG 解码器能解，探针也要认出尺寸', (
    WidgetTester tester,
  ) async {
    final Uint8List clean = img.encodeJpg(img.Image(width: 320, height: 480));
    // SOI 之后第一个段（APP0 / JFIF）结束处插入杂字节：段长写错的文件就是这个形状。
    final int app0End = 4 + ((clean[4] << 8) | clean[5]);
    final Uint8List junk = Uint8List.fromList(<int>[
      ...clean.sublist(0, app0End),
      0x00, 0x12, 0x34, 0x56, //
      ...clean.sublist(app0End),
    ]);
    final Directory dir = Directory.systemTemp.createTempSync(
      'lyrics_jpeg_junk_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}${Platform.pathSeparator}k002.jpg';
    File(path).writeAsBytesSync(junk);

    final ({int width, int height})? decoded = await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(junk);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ({int width, int height}) size = (
        width: frame.image.width,
        height: frame.image.height,
      );
      frame.image.dispose();
      codec.dispose();
      return size;
    });
    expect(decoded, (width: 320, height: 480));

    final Map<String, LyricsIllustrationFileProbe> probes =
        probeLyricsIllustrationFiles(<String>[path]);
    expect(probes[path]?.width, 320);
    expect(probes[path]?.height, 480);
  });
}
