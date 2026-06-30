// TODO-1037 / BUG-487：有声书跨章会一步跳过「独立成章的纯图片页」，即使开了
// 「图片等待」也跳过——因为图片等待原本只在已渲染章同一 DOM 内相邻 cue 锚点间
// 判定（window.__hoshiImageBetween），而纯图片章没有 cue、整章在不同 DOM，跨章
// 时 document.contains(prev) 直接返回 null，onImageDetected 从不触发。
//
// 本测试两层：
//   1) 纯函数 imageOnlyChaptersToPauseBetween 的真值表——构造「文本章之间夹纯
//      图片章」场景，断言开图片等待时枚举出中间图片章、关时返回空、目录页不停留、
//      多张连续图片按阅读顺序、相邻章无停留。
//   2) 源码接线守卫——锁住跨章落定前确实经纯决策枚举 + 逐章导航停留，复用控制器
//      的 await-based 停留与守卫持住机制，不新造定时器、不补丁式绕过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

void main() {
  group('跨章纯图片章停留决策 (TODO-1037 / BUG-487)', () {
    // 章布局：0=封面图片页, 1=文本, 2=纯图片插图, 3=纯图片插图, 4=文本, 5=目录页(图片)
    bool isImageOnly(int i) => i == 0 || i == 2 || i == 3 || i == 5;
    bool isNav(int i) => i == 5;
    const int chapterCount = 6;

    test('文本章 1 → 文本章 4，中间 2/3 是纯图片章 → 枚举出 [2, 3]（按阅读顺序）', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 1,
          toChapter: 4,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        <int>[2, 3],
        reason: '多个连续纯图片章须逐个停留，先经过先停留',
      );
    });

    test('图片等待关 (pauseSec=0) → 返回空列表，调用方按原跨章直跳', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 1,
          toChapter: 4,
          pauseSec: 0,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        isEmpty,
      );
    });

    test('相邻文本章（中间无章）→ 空列表，不停留', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 1,
          toChapter: 2,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        isEmpty,
      );
    });

    test('中间含目录/nav 页（即便是图片）→ 不停留在目录页', () {
      // from=4 → to=...（构造一个跨过目录页 5 的场景）：扩展章布局。
      bool imageOnly(int i) => i == 5 || i == 6;
      bool nav(int i) => i == 5; // 5 是目录页
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 4,
          toChapter: 7,
          pauseSec: 5,
          chapterCount: 8,
          isImageOnly: imageOnly,
          isNav: nav,
        ),
        <int>[6],
        reason: '目录页 5 是 nav，不停留；真正的插图章 6 停留',
      );
    });

    test('中间全是文本章 → 空列表（无图片章可停留）', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 1,
          toChapter: 4,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: (int i) => false,
          isNav: (int i) => false,
        ),
        isEmpty,
      );
    });

    test('同章（from == to）→ 空列表', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 2,
          toChapter: 2,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        isEmpty,
      );
    });

    test('越界 from/to → 空列表（不崩、不停留）', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: -1,
          toChapter: 3,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        isEmpty,
      );
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 1,
          toChapter: 99,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        isEmpty,
      );
    });

    test('回退方向跨章（from > to）→ 按 from→to 阅读方向枚举中间图片章', () {
      expect(
        imageOnlyChaptersToPauseBetween(
          fromChapter: 4,
          toChapter: 1,
          pauseSec: 5,
          chapterCount: chapterCount,
          isImageOnly: isImageOnly,
          isNav: isNav,
        ),
        <int>[3, 2],
        reason: '回退跨章从 4 向 1 经过 3、2，按经过顺序停留',
      );
    });
  });

  group('跨章纯图片章停留接线守卫 (TODO-1037 / BUG-487)', () {
    late String src;
    setUpAll(() {
      src = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
    });

    test('跨章落定前经 _pauseThroughImageOnlyChapters 处理中间图片章', () {
      expect(src.contains('_pauseThroughImageOnlyChapters('), isTrue);
      // 必须在最终 _navigateToChapter(newSection) 之前停留，否则图片章被跳过。
      final int pauseIdx = src.indexOf('await _pauseThroughImageOnlyChapters(');
      final int navIdx =
          src.indexOf('await _navigateToChapter(newSection', pauseIdx);
      expect(pauseIdx >= 0, isTrue);
      expect(navIdx > pauseIdx, isTrue, reason: '停留必须发生在跨章落定到目标章之前');
    });

    test('停留序列经纯决策 imageOnlyChaptersToPauseBetween 枚举中间图片章', () {
      expect(src.contains('imageOnlyChaptersToPauseBetween('), isTrue);
      expect(src.contains('isImageOnly: _book!.isImageOnlyChapter'), isTrue,
          reason: '复用既有 isImageOnlyChapter 能力判定纯图片章');
    });

    test('每个图片章导航后复用控制器 await-based 停留（不新造定时器）', () {
      expect(src.contains('awaitImageChapterPause()'), isTrue);
    });

    test('序列期间持住 holdChapterTransition 防重入跨章', () {
      expect(src.contains('holdChapterTransition()'), isTrue);
    });
  });

  group('控制器跨章图片停留原语守卫 (TODO-1037 / BUG-487)', () {
    late String src;
    setUpAll(() {
      src = File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();
    });

    test('awaitImageChapterPause 受 imagePauseSec>0 门控，复用 _imagePauseTimer', () {
      expect(src.contains('Future<void> awaitImageChapterPause()'), isTrue);
      final int start = src.indexOf('Future<void> awaitImageChapterPause()');
      final String body = src.substring(start, start + 800);
      expect(body.contains('if (sec <= 0) return'), isTrue,
          reason: 'imagePauseSec=0 时不停留');
      expect(body.contains('_imagePauseTimer'), isTrue,
          reason: '复用 triggerImagePause 同一 Timer 字段，不新造定时器语义');
      expect(
          body.contains('_player.pause()') && body.contains('_player.play()'),
          isTrue,
          reason: '主动暂停→等待→恢复，复用同一暂停/恢复原语');
    });

    test('holdChapterTransition 竖起 _chapterTransition 守卫', () {
      expect(src.contains('void holdChapterTransition()'), isTrue);
    });
  });
}
