// TODO-746: 有声书播放往前倒到「书里没有的句子」(属另一章) 时，跨章导航不再用
// _navigateToChapter 缺省 progress=0.0 归零滑到第一章。归零真凶=跨章没复用 restore
// 路径已算好的章内进度公式 → progress<=0 → JS scrollToChapterStart 六重清零。
//
// 本测试两层：
//   1) 纯函数 audiobookSrt/SasayakiCrossChapterProgress —— 章内进度公式的真值表，
//      含「拿不到句内偏移返 null」(调用方据此不归零) 的边界。
//   2) 源码接线守卫 —— 锁住两条运行时跨章路径确实复用纯函数、不再裸调
//      _navigateToChapter(newSection)/(cueChapter) 走缺省 progress=0.0。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

void main() {
  group('SRT 跨章章内进度 (TODO-746)', () {
    test('cue 落在该章中段 → (idx-first)/span，不归 0', () {
      // 第 N 章 sentenceIndex 范围 10..20，cue=15 → (15-10)/(20-10)=0.5
      expect(
        audiobookSrtCrossChapterProgress(
            sentenceIndex: 15, first: 10, last: 20),
        0.5,
      );
    });
    test('cue 是该章首句 → 0.0 (章首是真实位置，非归零哨兵)', () {
      expect(
        audiobookSrtCrossChapterProgress(
            sentenceIndex: 10, first: 10, last: 20),
        0.0,
      );
    });
    test('cue 是该章末句 → 1.0', () {
      expect(
        audiobookSrtCrossChapterProgress(
            sentenceIndex: 20, first: 10, last: 20),
        1.0,
      );
    });
    test('单句章 span=0 → null (拿不到句内偏移，调用方保位)', () {
      expect(
        audiobookSrtCrossChapterProgress(
            sentenceIndex: 10, first: 10, last: 10),
        isNull,
      );
    });
    test('越界保护：cue 超出范围 → clamp 不溢出', () {
      expect(
        audiobookSrtCrossChapterProgress(
            sentenceIndex: 99, first: 10, last: 20),
        1.0,
      );
    });
  });

  group('sasayaki 跨章章内进度 (TODO-746)', () {
    test('frag 落在该章中段 → normCharStart/chapterChars，不归 0', () {
      expect(
        audiobookSasayakiCrossChapterProgress(
            normCharStart: 250, chapterChars: 1000),
        0.25,
      );
    });
    test('章字符数为 0 (未知/空章) → null (调用方退回该章章首 0.0，非归到第一章)', () {
      expect(
        audiobookSasayakiCrossChapterProgress(
            normCharStart: 250, chapterChars: 0),
        isNull,
      );
    });
    test('clamp 上界：normCharStart 超章字符 → 1.0 不溢出', () {
      expect(
        audiobookSasayakiCrossChapterProgress(
            normCharStart: 2000, chapterChars: 1000),
        1.0,
      );
    });
  });

  group('跨章不归零接线守卫 (TODO-746)', () {
    late String src;
    setUpAll(() {
      src = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
    });

    test('sasayaki 跨章 (_handleCueCrossChapter) 复用章内进度纯函数', () {
      expect(
        src.contains('audiobookSasayakiCrossChapterProgress('),
        isTrue,
        reason: '跨章必须复用进度公式落到 cue 真实位置，不得走缺省 progress=0.0',
      );
    });

    test('SRT 跨章 (_onCueChanged) 复用章内进度纯函数', () {
      expect(
        src.contains('audiobookSrtCrossChapterProgress('),
        isTrue,
        reason: 'SRT 跨章必须复用进度公式，不得裸调 _navigateToChapter(cueChapter)',
      );
    });

    test('不再裸调 _navigateToChapter(newSection) 走缺省 progress=0.0 归零', () {
      expect(
        RegExp(r'_navigateToChapter\(\s*newSection\s*\)').hasMatch(src),
        isFalse,
        reason: '裸 _navigateToChapter(newSection) → 缺省 progress=0.0 → 滑到第一章',
      );
    });

    test('不再裸调 _navigateToChapter(cueChapter) 走缺省 progress=0.0 归零', () {
      expect(
        RegExp(r'_navigateToChapter\(\s*cueChapter\s*\)').hasMatch(src),
        isFalse,
        reason: '裸 _navigateToChapter(cueChapter) → 缺省 progress=0.0 → 归零',
      );
    });
  });
}
