// TODO-807：有声书被动播放跨章时，章末到下章之间那条「书里没有的句子」把跟随
// 高亮甩到了「目录」章节。
//
// 真凶（路径 A·SRT）：cue→章用 _srtCueChapterMap，其 value 是
// CuesToEpub.splitChapters 的人工切章序号（≤500cue/≤10min 切），与 EPUB
// _book!.chapters 的真实 spine index 零映射。旧代码把该序号直接当 chapters
// index 喂给 _navigateToChapter，跨章命中 cue 时滑到 chapters[序号]，常命中目录
// /nav 页（日文 EPUB 把目录作 spine 首项，chapters[0]=目录）。
//
// 本测试两层：
//   1) 纯函数 audiobookSrtCrossChapterTarget 的真值表——构造「chapters[0]=目录
//      页 + SRT 跨章命中 cue」场景，断言不会导航到目录页 index、不兜底 index 0。
//   2) 源码接线守卫——锁住 SRT 跨章确实经反查 + 纯决策，不再裸用 splitChapters
//      序号当导航目标。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

void main() {
  group('SRT 跨章导航目标决策 (TODO-807)', () {
    test('反查到真实正文章（≠当前章、非目录）→ 返回该真实 index', () {
      // 当前在第 1 章（index 1），cue 反查到第 2 章（index 2，正文）。
      expect(
        audiobookSrtCrossChapterTarget(
          resolvedChapter: 2,
          currentChapter: 1,
          resolvedIsNav: false,
        ),
        2,
      );
    });

    test('反查失败（-1）→ 返回 -1 保位，绝不兜底 index 0', () {
      expect(
        audiobookSrtCrossChapterTarget(
          resolvedChapter: -1,
          currentChapter: 3,
          resolvedIsNav: false,
        ),
        -1,
        reason: '章末到下章间的「书里没有的句子」反查不到真实章，必须保位不跳',
      );
    });

    test('反查到的章是目录/nav 页 → 返回 -1 保位（不甩到目录）', () {
      // 即便反查命中 chapters[0]（目录页）也不导航——正是 TODO-807 症状根因。
      expect(
        audiobookSrtCrossChapterTarget(
          resolvedChapter: 0,
          currentChapter: 1,
          resolvedIsNav: true,
        ),
        -1,
        reason: 'chapters[0]=目录页时跨章不能落到它',
      );
    });

    test('反查到的章就是当前章 → 返回 -1（无需导航，下游只高亮）', () {
      expect(
        audiobookSrtCrossChapterTarget(
          resolvedChapter: 2,
          currentChapter: 2,
          resolvedIsNav: false,
        ),
        -1,
      );
    });

    test('回归保护：splitChapters 序号 ≠ 真实 index 时，目标取真实 index 而非序号', () {
      // 模拟：splitChapters 把书切成若干「序号桶」，但 chapters 含一个目录页导致
      // 序号与真实 index 错位。决策只认反查到的真实 index。
      const int splitOrdinalUnused = 0; // 旧代码会拿它当 index → 目录页
      const int realChapter = 3; // 反查到的真实正文章
      // 旧 bug：用 splitOrdinalUnused(0) 导航 → 目录页。新决策：用 realChapter。
      expect(splitOrdinalUnused, isNot(realChapter));
      expect(
        audiobookSrtCrossChapterTarget(
          resolvedChapter: realChapter,
          currentChapter: 1,
          resolvedIsNav: false,
        ),
        realChapter,
      );
    });
  });

  group('SRT 跨章不甩目录接线守卫 (TODO-807)', () {
    late String src;
    setUpAll(() {
      src = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
    });

    test('SRT 跨章经 _resolveSrtCueChapter 反查真实章 index', () {
      expect(src.contains('_resolveSrtCueChapter('), isTrue,
          reason: 'cue→章必须按 chapterHref/正文反查回真实 chapters index');
    });

    test('SRT 跨章经纯决策 audiobookSrtCrossChapterTarget 收口（剔除目录/未命中）', () {
      expect(src.contains('audiobookSrtCrossChapterTarget('), isTrue);
    });

    test('SRT 跨章导航目标用 navTarget（真实 index），不再裸用 cueChapter 序号', () {
      expect(
        RegExp(r'_navigateToChapter\(\s*cueChapter\b').hasMatch(src),
        isFalse,
        reason: 'cueChapter 是 splitChapters 序号，当 index 用会滑到目录/错章',
      );
      expect(src.contains('_navigateToChapter(navTarget'), isTrue);
    });

    test('被动跨章命中 nav 页保位（_navigateToChapter / _handleCueCrossChapter 均守卫）', () {
      final String navSrc = File(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
      ).readAsStringSync();
      expect(navSrc.contains('isChapterNav('), isTrue,
          reason: '_navigateToChapter 纵深防御：被动导航不落 nav 页');
      expect(src.contains('isChapterNav('), isTrue,
          reason: '_handleCueCrossChapter（sasayaki 路径 B）守卫 nav 页');
    });
  });
}
