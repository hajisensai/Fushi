import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 跨章两条回归（用户反馈 qMRtA75fhO）：
///
/// - BUG-3221：换章装载期间多滑的几下，新章装好后被逐页消费（「加载完后它还真给
///   往后翻几页」）。
/// - BUG-3222：翻回上一章时先闪一下上一章开头，再跳到末尾。
void main() {
  final String source = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync();

  String body(String signature, String nextSignature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: signature);
    final int end = source.indexOf(nextSignature, start);
    expect(end, greaterThan(start), reason: nextSignature);
    return source.substring(start, end);
  }

  group('BUG-3221 换章期间的翻页输入', () {
    test('换章开始时清空队列：撞到章尾之前攒下的步数不会在新章上继续消费', () async {
      final MangaTurnQueue queue = MangaTurnQueue();
      final Completer<void> chapterLoaded = Completer<void>();
      final List<int> applied = <int>[];
      bool switching = false;
      bool canApply() => !switching;

      // 第一步撞到章尾 → 换章：与生产一致，先置 switching、清队列，再 await 装载。
      Future<void> applyStep(int step) async {
        applied.add(step);
        if (applied.length == 1) {
          switching = true;
          queue.clear();
          await chapterLoaded.future;
          switching = false;
        }
      }

      final Future<void> first = queue.enqueue(
        1,
        maxMagnitude: 100,
        canApply: canApply,
        applyStep: applyStep,
      );
      await Future<void>.delayed(Duration.zero);
      expect(applied, <int>[1]);
      // 换章装载期间用户嫌卡又滑了三下：生产里 _onMangaTurn 在 _switchingChapter
      // 时直接 return，不进队列（这里不 enqueue 就是那条早退）。
      chapterLoaded.complete();
      await first;
      expect(applied, <int>[1], reason: '新章装好后不得自己往后翻');
      expect(queue.pendingDelta, 0);
    });

    test('长按攒下的步数撞到章尾：换章后剩余步数被丢弃', () async {
      final MangaTurnQueue queue = MangaTurnQueue();
      final Completer<void> stepInFlight = Completer<void>();
      final Completer<void> chapterLoaded = Completer<void>();
      final List<int> applied = <int>[];
      bool switching = false;

      // 第一步在飞（翻页 / 窗口装载）时长按又攒了 4 步；第一步随后撞到章尾换章。
      Future<void> applyStep(int step) async {
        applied.add(step);
        if (applied.length == 1) {
          await stepInFlight.future;
          switching = true;
          queue.clear();
          await chapterLoaded.future;
          switching = false;
        }
      }

      final Future<void> first = queue.enqueue(
        1,
        maxMagnitude: 100,
        canApply: () => !switching,
        applyStep: applyStep,
      );
      for (int i = 0; i < 4; i++) {
        unawaited(
          queue.enqueue(
            1,
            maxMagnitude: 100,
            canApply: () => !switching,
            applyStep: applyStep,
          ),
        );
      }
      expect(queue.pendingDelta, 4);
      stepInFlight.complete();
      await Future<void>.delayed(Duration.zero);
      chapterLoaded.complete();
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(applied, <int>[1], reason: '攒下的步数属于旧章，换章时丢弃');
    });

    test('接线：_onMangaTurn 换章中早退；_switchToChapter 置位后立刻清队列', () {
      final String turn = body(
        'Future<void> _onMangaTurn(String dir) async {',
        'Future<void> _applyMangaTurnStep(int delta) async {',
      );
      final int guard = turn.indexOf('if (_switchingChapter) return;');
      expect(guard, greaterThanOrEqualTo(0));
      expect(turn.indexOf('_turnQueue.enqueue('), greaterThan(guard));

      final String switchBody = body(
        'Future<void> _switchToChapter(',
        'Future<void> _saveCurrentChapterState(',
      );
      final int flag = switchBody.indexOf('_switchingChapter = true;');
      final int clear = switchBody.indexOf('_turnQueue.clear();');
      expect(flag, greaterThanOrEqualTo(0));
      expect(clear, greaterThan(flag));
    });

    test('换章装载中有可见的加载指示（接线）', () {
      expect(
        source,
        contains('Positioned.fill(child: _buildChapterSwitchingOverlay())'),
      );
      expect(source, contains('visible: _switchingChapter,'));
    });

    test('章末不再弹「下一章」卡片', () {
      expect(source, isNot(contains('MangaChapterEndCard')));
      expect(source, isNot(contains('manga_chapter_end_card')));
    });
  });

  group('BUG-3222 翻回上一章直接落在末页', () {
    test('换章往回翻：末页作为装载起始页传下去，装好后不再二次跳页', () {
      final String switchBody = body(
        'Future<void> _switchToChapter(',
        'Future<void> _saveCurrentChapterState(',
      );
      expect(
        switchBody,
        isNot(contains('_jumpToPage(')),
        reason: '「先按第 0 页装好再跳末页」就是那一下闪回',
      );
      expect(switchBody, contains('landOnLastPage: landOnLastPage,'));

      final String open = body(
        'Future<void> _openShelfChapter({',
        'Future<bool> _openStreamingChapter({',
      );
      expect(
        open,
        contains(
          'int initialPage = landOnLastPage ? kMangaLandOnLastPage : 0;',
        ),
      );
      // 起始页在页数已知处钳到末页：本地卷 / 已下载章走 _presentPayload，
      // 在线直读的落点页也用同一个钳位（落点页就是先取的那一页）。
      expect(
        source,
        contains(
          'restoredPage = initialPage.clamp(\n'
          '        0,\n'
          '        math.max(0, payload.images.length - 1),\n'
          '      );',
        ),
      );
      expect(
        source,
        contains('final int landing = initialPage.clamp(0, pages.length - 1);'),
      );
      expect(kMangaLandOnLastPage.clamp(0, 41), 41);
    });

    String doc({required String direction, required int current}) =>
        mangaWindowDocument(
          <MokuroImage>[
            for (int i = 0; i < 6; i++)
              const MokuroImage(
                url: 'p.png',
                size: MokuroSize(1000, 1414),
                blocks: <MokuroBlock>[],
              ),
          ],
          <String>[for (int i = 0; i < 6; i++) 'p$i.png'],
          mode: MangaReadingMode.spread,
          spreadDirection: direction,
          inlineSelectionJs: '',
          pageSpreadIndices: <int>[0, 1, 2, 3, 4, 5],
          currentSpread: current,
        );

    test('首帧就停在落点跨页：strip 的初始 transform 写在文档里，不等脚本重投影', () {
      // LTR：DOM 正序，末跨页（5）在第 5 个槽位。此前首帧是 transform:none，
      // 屏上是 DOM 最左的跨页 0——即上一章的开头。
      expect(
        doc(direction: 'ltr', current: 5),
        contains('<div id="manga-root" style="transform:translateX(-500vw)">'),
      );
      // RTL：DOM 倒序，末跨页在槽位 0。
      expect(
        doc(direction: 'rtl', current: 5),
        contains('<div id="manga-root" style="transform:translateX(-0vw)">'),
      );
      expect(
        doc(direction: 'rtl', current: 0),
        contains('<div id="manga-root" style="transform:translateX(-500vw)">'),
      );
    });

    test('落在末页时第 0 页的图不抢先加载（不会被画出来，也不占首屏带宽）', () {
      final String d = doc(direction: 'ltr', current: 5);
      final RegExp page0 = RegExp(
        r'data-page="0"[^>]*>.*?<img [^>]*loading="(\w+)"',
      );
      final RegExp page5 = RegExp(
        r'data-page="5"[^>]*>.*?<img [^>]*loading="(\w+)"',
      );
      expect(page0.firstMatch(d)!.group(1), 'lazy');
      expect(page5.firstMatch(d)!.group(1), 'eager');
    });
  });
}
