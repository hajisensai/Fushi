import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show absoluteCharOffsetOf;
import 'package:fushi/src/stats/read_unit_ledger.dart';

/// EPUB 侧「读过」判据的边界表（`docs/plans/2026-09-06-read-unit-ledger.md` 第 2 节）：
///
///  * [absoluteCharOffsetOf]：JS 回传的章内学习单位偏移 → 全书绝对偏移（账本坐标）；
///  * 用 [ReadUnitLedger] 按页面接线（`_refreshProgress` 每次采样 arrive、跳句 / 导航 /
///    同章跳转 leave、字数补算 reset、导航失败 discard）模拟每一行边界场景，断言
///    交给 `StudyClock.addChars` 的字数。
void main() {
  // 三章书：字数 [1000, 2000, 3000]，章首累计 [0, 1000, 3000]。
  const List<int> counts = <int>[1000, 2000, 3000];
  const List<int> cumulative = <int>[0, 1000, 3000];

  int abs(int chapter, int offset) => absoluteCharOffsetOf(
    chapterCumulativeChars: cumulative,
    chapterCharCounts: counts,
    chapter: chapter,
    charOffset: offset,
  );

  group('absoluteCharOffsetOf：章内偏移 → 全书绝对偏移', () {
    test('章首累计 + 章内偏移', () {
      expect(abs(0, 0), 0);
      expect(abs(0, 345), 345);
      expect(abs(1, 0), 1000);
      expect(abs(1, 1999), 2999);
      expect(abs(2, 3000), 6000);
    });

    test('章内偏移超过本章字数 → clamp 到章末（不越章）', () {
      expect(abs(0, 1200), 1000);
      expect(abs(1, 99999), 3000);
    });

    test('偏移 < 0（JS 拿不到 caret）→ -1，不当章首', () {
      expect(abs(0, -1), -1);
      expect(abs(1, -7), -1);
    });

    test('章越界 / 计数未就绪 → -1', () {
      expect(abs(-1, 10), -1);
      expect(abs(3, 10), -1);
      expect(
        absoluteCharOffsetOf(
          chapterCumulativeChars: const <int>[],
          chapterCharCounts: const <int>[],
          chapter: 0,
          charOffset: 10,
        ),
        -1,
      );
      expect(
        absoluteCharOffsetOf(
          chapterCumulativeChars: cumulative,
          chapterCharCounts: const <int>[1000],
          chapter: 1,
          charOffset: 10,
        ),
        -1,
        reason: '两表长度不齐（计数尚在补算）时按未就绪处理',
      );
    });
  });

  group('账本模拟：计划文档第 2 节边界表', () {
    late int credited;
    late ReadUnitLedger ledger;

    setUp(() {
      credited = 0;
      ledger = ReadUnitLedger(
        onCredit: (List<(int, int)> fresh) =>
            credited += readUnitsLength(fresh),
        onRetract: (List<(int, int)> retracted) =>
            credited -= readUnitsLength(retracted),
      );
    });

    /// 页面接线：`_refreshProgress` 拿到 (章, start, end) 后的 arrive 门。
    void sample(int chapter, int start, int end) {
      final int s = abs(chapter, start);
      final int e = abs(chapter, end);
      if (s >= 0 && e > s) ledger.arrive(s, e);
    }

    test('顺序读到章末翻入下一章：末页在新章首页 arrive 时结算，章边界透明', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      expect(credited, 400);
      sample(0, 800, 1000); // 章末页
      expect(credited, 800);
      sample(1, 0, 500); // 翻入下一章首页
      expect(credited, 1000, reason: '末页 [800,1000) 在新章首页到达时结算');
      sample(1, 500, 1000);
      expect(credited, 1500, reason: '新章首页翻走时全额计');
    });

    test('章末页 JS 报 end 超章字数：clamp 到章末，不吞下一章', () {
      sample(0, 800, 1500);
      sample(1, 0, 400);
      expect(credited, 200);
    });

    test('往回翻到上一章：撤回落点之后已计的；再前翻按并集恢复；越过最远处才新计', () {
      sample(0, 600, 1000);
      sample(1, 0, 400);
      sample(1, 400, 800); // 已计 [600,1400)
      expect(credited, 800);
      sample(1, 0, 400); // 回翻一页：[1400,1800) 并入并集，位置退到 1000
      expect(credited, 400, reason: '[1000,1400) 撤回');
      sample(0, 600, 1000); // 回到上一章末页：位置 600
      expect(credited, 0, reason: '[600,1000) 也撤回');
      sample(1, 0, 400); // 再前翻：并集恢复 [600,1000)
      expect(credited, 400);
      sample(1, 400, 800); // 恢复 [1000,1400)
      sample(1, 800, 1200); // 恢复 [1400,1800)
      expect(credited, 1200, reason: '翻过的按并集恢复，不用重读也不双计');
      sample(1, 1200, 1600); // 结算 [1800,2200)：新页
      expect(credited, 1600);
    });

    test('目录 / 进度条 / 搜索 / 收藏跳转：跳走前那页计、跳过的不计、落点页翻走时计', () {
      sample(0, 0, 400);
      // 跳转（页面不做任何账本动作），落点直接 arrive。
      sample(2, 1000, 1400);
      expect(credited, 400, reason: '跳走前那页 [0,400) 计入');
      sample(2, 1400, 1800);
      expect(credited, 800, reason: '落点页翻走时计；被跳过的 [400,4000) 从未成为当前单元');
    });

    test('听书显式跳句：leave() 结算当前页，跳过的段落不计', () {
      sample(0, 0, 400);
      ledger.leave(); // onExplicitCueJump
      expect(credited, 400);
      sample(0, 700, 1000); // 跟随滚动落到目标 cue
      expect(credited, 400, reason: '到达不计，[400,700) 不计');
      sample(1, 0, 300);
      expect(credited, 700);
    });

    test('听书跳句回到上一句（后跳）：撤回落点之后的，再听回来按并集恢复', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      ledger.leave();
      expect(credited, 800);
      sample(0, 0, 400); // 后跳落到首页：位置 0
      expect(credited, 0, reason: '[0,800) 全部撤回');
      sample(0, 400, 800);
      expect(credited, 400, reason: '[0,400) 恢复');
      ledger.leave();
      expect(credited, 800, reason: '重听重读不重复计，总额仍是 800');
    });

    test(
      '宽变 / 分页↔连续（同章重恢复经 _beginNavigation）：leave 提前结算同页，新边界只补多露出的行，总额不变',
      () {
        sample(0, 0, 400);
        ledger.leave(); // _beginNavigation
        expect(credited, 400, reason: '离开时按单元终点入账（用户确实在这页）');
        sample(0, 0, 520); // 恢复落回同一页（多露出几行）：位置回到 0
        expect(ledger.current, (0, 520));
        expect(credited, 0, reason: '同页重新成为当前单元，翻走前不计（撤回）');
        sample(0, 520, 1000);
        expect(credited, 520, reason: '翻走时按并集入账 [0,520)，总额与旧口径一致');
      },
    );

    test('改字号 CSS 热换（不经导航）：同页新边界 arrive 只并入不入账，翻走时总额同上', () {
      sample(0, 0, 400);
      sample(0, 0, 520);
      expect(credited, 0, reason: '位置仍是 0，当前页翻走前不计');
      sample(0, 520, 1000);
      expect(credited, 520);
    });

    test('BUG-2225 同章进度条跳转：JS notifyRestoreComplete 抢先也不丢跳走前那页', () {
      // 旧实现：_onRestoreComplete 判原位 → rebaseOnNextArrive → 落点 arrive 不结算
      // [0,400)。新实现：跳转入口先 leave。
      sample(0, 0, 400);
      ledger.leave(); // _jumpToGlobalCharOffset 同章分支
      expect(credited, 400);
      sample(0, 800, 1000); // 落点页（restoreComplete / scroll 回传顺序无关）
      expect(credited, 400, reason: '跳过的 [400,800) 不计');
      sample(1, 0, 400);
      expect(credited, 600);
    });

    test('BUG-2225 VN 同章拖动（无 scroll 事件）：同上，旧屏不再被 rebase 掉', () {
      sample(0, 0, 100);
      ledger.leave();
      sample(0, 500, 600);
      expect(credited, 100);
    });

    test(
      'BUG-2226 跨章导航装载失败 / 兜底超时：_beginNavigation 已 leave，discard 不再丢上一页',
      () {
        sample(0, 600, 1000);
        ledger.leave(); // _beginNavigation
        ledger.discard(); // _failNavigation
        expect(credited, 400, reason: '旧实现在此 discard 掉的正是用户真读过的这页');
        sample(1, 0, 400);
        sample(1, 400, 800);
        expect(credited, 800);
      },
    );

    test('首次开书 / 恢复到存档页：存档页是当前单元，翻走时计一次，不预置', () {
      sample(1, 600, 1000); // 存档页
      expect(credited, 0);
      expect(ledger.coverage.isEmpty, isTrue, reason: '不预置存档页之前的正文');
      sample(1, 1000, 1400);
      expect(credited, 400);
    });

    test('纯图片章 / 封面：snapshot == null 不 arrive，账本不动', () {
      sample(0, 800, 1000);
      // 图片章：页面不调 arrive。
      sample(2, 0, 400);
      expect(credited, 200);
    });

    test('导航发起后新页曾短暂 arrive 再失败：discard() 只丢那个未读的新单元', () {
      sample(0, 0, 400);
      ledger.discard();
      expect(credited, 0);
      sample(1, 0, 400);
      expect(credited, 0, reason: '丢弃的单元不在并集里也不结算');
      sample(1, 400, 800);
      expect(credited, 400);
    });

    test('章字数后台补算落定：reset() 清并集 + 丢当前，之后从头起单元', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      expect(credited, 400);
      ledger.reset();
      expect(ledger.coverage.isEmpty, isTrue);
      expect(ledger.current, isNull);
      sample(0, 0, 400); // 新口径下同一页：到达不计
      expect(credited, 400);
      sample(0, 400, 800);
      expect(credited, 800, reason: '旧口径的并集不再有意义，新坐标下重新计');
    });

    test('连续模式惯性滚动：每次落定采样一个单元，入账随视口顶部推进', () {
      sample(0, 0, 500);
      sample(0, 300, 800);
      sample(0, 600, 1100); // end clamp 到 1000
      expect(credited, 600, reason: '并集 [0,800)，位置 600 → 入账 [0,600)');
      sample(1, 0, 500);
      expect(credited, 1000);
    });

    test('JS 拿不到终点（三段协议 / 探测失败，end = -1）：不 arrive，宁可不计', () {
      sample(0, 0, -1);
      expect(ledger.current, isNull);
      sample(0, 400, 800);
      expect(credited, 0);
      sample(0, 800, 1000);
      expect(credited, 400);
    });

    test('JS 拿不到起点（start = -1）：不 arrive，也不把章首当起点', () {
      sample(0, -1, 400);
      expect(ledger.current, isNull);
    });

    test('end <= start（探测倒挂）：不 arrive', () {
      sample(0, 400, 400);
      sample(0, 400, 300);
      expect(ledger.current, isNull);
    });

    test('关书：leave() 结算最后一页，同一会话对象不再复用', () {
      sample(0, 0, 400);
      sample(0, 400, 800);
      ledger.leave();
      expect(credited, 800);
      expect(ledger.current, isNull);
    });

    /// 「拖有声书进度条 → 立刻关书」的字数结算时序（沿真实代码路径核对，2026-09-06）。
    ///
    /// 生产调用链（`packages/fushi_audio/lib/src/audiobook/audiobook_controller.dart`
    /// + `fushi/lib/src/pages/implementations/reader_fushi/*.part.dart`）：
    ///
    ///  1. 拖进度条 → `AudiobookPlayerController.seekMs`（audiobook_controller.dart:1060）
    ///     → `_clearExplicitSeekSuppression()` → `_player.seek(...)` → `notifyListeners()`。
    ///     **seekMs 全程不调 `onExplicitCueJump`**——那是 `skipToCue` 漏斗独有的
    ///     （audiobook_controller.dart:1134），所以拖进度条**不会**触发
    ///     `_handleExplicitCueJump`（reader_fushi/audiobook.part.dart:858）的
    ///     `_readLedger.leave()`。快进快退 `seekRelative`（:1077）复用 seekMs，同理。
    ///  2. 125ms positionStream tick → `_updateCurrentCue`（:1326）解析出新 cue →
    ///     `notifyListeners()` → `AudiobookSession._onControllerChanged`
    ///     （media/audiobook/audiobook_session.dart:224）→ reader `_onCueChanged`
    ///     （reader_fushi/audiobook.part.dart:554）。
    ///  3. `_onCueChanged` 的分叉点是 `controller.shouldRevealCurrentCue`
    ///     （audiobook_controller.dart:1430 = `followAudio && _hasPlayedOnce &&
    ///     _player.playing && _stopAtPositionMs == null`）：
    ///     * **reveal=true**（播放中 + 跟随音频开）：先打点 `_reanchorClearedAt`
    ///       （:680）武装 B-3 窗，再 `AudiobookBridge.highlight(reveal: true)`（:682）
    ///       把视口滚到目标 cue，最后 `_scheduleReanchorSettleProgressRefresh()`（:689）排一个
    ///       `kReaderReanchorSettleMs`=250ms 的 Timer 补刷 `_refreshProgress`。
    ///       这 250ms 内跟随滚动的 scroll 回传被 `readerScrollWithinReanchorSettle`
    ///       （reader_fushi_page.dart:884）在 `_handleReaderScroll` 里直接丢掉，
    ///       **不会 arrive**。
    ///     * **reveal=false**（暂停态 / 跟随音频关 / 还没按过播放）：只加高亮 class、
    ///       不动视口、不打点、不排补刷 → 可见区间没变，本来就不该 arrive。
    ///  4. 关书 `onSourcePagePop`（reader_fushi_page.dart:2758）：
    ///     `await _syncAndFlushPosition()` → `_readLedger.leave()` → `_flushReadingStats()`。
    ///     退出探针 `_syncPositionFromWebViewProgress`（navigation.part.dart:1231）
    ///     **只写 `_lastProgress*` / 恢复锚，不碰账本**——全语料唯一的 `arrive` 点是
    ///     `_refreshProgress`（navigation.part.dart:1066，arrive 在 :1152）。`dispose()`（:2639）随后
    ///     `_readLedger.leave()`（对已清空的账本是 no-op）并 cancel
    ///     `_revealProgressRefreshTimer`（:2679），未到期的补刷永不执行。
    ///
    /// 结论：**250ms 内关书结算的是「拖前那页」**（拖后那页从未 arrive、不计）；
    /// **250ms 后关书两页都计**（拖前页在补刷 arrive 时结算、拖后页在 leave 时结算）。
    group('拖音频进度条后关书', () {
      test('播放跟随 + 250ms 内关书：只结算拖前那页，拖后那页不计', () {
        sample(0, 0, 400);
        sample(0, 400, 800); // 拖前停在这一页（当前单元 [400,800)）
        expect(credited, 400);

        // 拖进度条：seekMs 不走 onExplicitCueJump → 账本零动作，当前单元不变。
        expect(ledger.current, (400, 800));

        // reveal=true 的跟随滚动落到第 3 章某处；这 250ms 内 scroll 回传被 B-3 窗
        // 丢掉，补刷 Timer 尚未到期 → 没有任何 arrive。
        //
        // 关书：onSourcePagePop 的 leave() 结算「拖前那页」。
        ledger.leave();
        expect(credited, 800, reason: '拖前那页 [400,800) 计入；拖后那页从未成为当前单元');
        expect(ledger.current, isNull);

        // dispose() 的兜底 leave() 对已清空账本是 no-op，不会重复计。
        ledger.leave();
        expect(credited, 800);
      });

      test('播放跟随 + 250ms 后关书：补刷 arrive 结算拖前页，关书 leave 结算拖后页', () {
        sample(0, 0, 400);
        sample(0, 400, 800);
        expect(credited, 400);

        // 250ms 到期 → _scheduleReanchorSettleProgressRefresh 的 Timer 触发 _refreshProgress
        // → arrive(拖后那页)：切换单元的同时结算拖前那页。
        sample(2, 1200, 1600);
        expect(credited, 800, reason: '拖前那页 [400,800) 在补刷 arrive 时结算');

        ledger.leave();
        expect(credited, 1200, reason: '拖后那页 [4200,4600) 翻走（关书）时全额计');
      });

      test('暂停态 / 跟随音频关（reveal=false）：视口不动，关书仍只结算当前那页', () {
        sample(1, 0, 500);
        expect(credited, 0);

        // reveal=false → 只换高亮 class，不滚视口、不打点、不排补刷 → 无 arrive。
        ledger.leave();
        expect(credited, 500, reason: '可见区间没变，结算的就是拖前 = 拖后的同一页');
      });

      test('拖到同一页内（视口未动）：补刷 arrive 同区间是 no-op，关书只计一次', () {
        sample(1, 0, 500);
        sample(1, 0, 500); // 250ms 后的补刷读回同一个可见区间
        expect(ledger.current, (1000, 1500));
        ledger.leave();
        expect(credited, 500);
      });

      test('拖回本会话已读过的位置：撤回落点之后的，关书只计到落点页末', () {
        sample(0, 0, 400);
        sample(0, 400, 800);
        sample(0, 800, 1000);
        expect(credited, 800);

        // 拖回开头，250ms 后补刷 arrive 到首页：位置退到 0，之前入账的全部撤回。
        sample(0, 0, 400);
        expect(credited, 0, reason: '并集 [0,1000) 不减，但位置之后的不入账');
        ledger.leave();
        expect(credited, 400, reason: '关书按落点页末入账 [0,400)');
      });

      test('与显式跳句（skipToCue）总额等价：leave 提前只改结算时刻，不改总额', () {
        // A：拖进度条（无 onExplicitCueJump）。
        sample(0, 0, 400);
        sample(2, 1200, 1600); // 250ms 后补刷
        ledger.leave();
        final int viaSeek = credited;

        credited = 0;
        ledger = ReadUnitLedger(
          onCredit: (List<(int, int)> fresh) =>
              credited += readUnitsLength(fresh),
          onRetract: (List<(int, int)> retracted) =>
              credited -= readUnitsLength(retracted),
        );

        // B：点句跳转（skipToCue → onExplicitCueJump → leave）。
        sample(0, 0, 400);
        ledger.leave(); // _handleExplicitCueJump
        sample(2, 1200, 1600);
        ledger.leave();
        expect(
          credited,
          viaSeek,
          reason: 'arrive 自带「切换即结算」，提前 leave 只是把同一笔挪到跳转那一刻',
        );
      });
    });
  });
}
