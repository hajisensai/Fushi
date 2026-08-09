import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show readerPositionSaveArgs;
import 'package:fushi/src/reader/reader_restore_anchor.dart';

/// TODO-2603（BUG-1386 派生）：阅读器恢复锚的生命周期真行为测。
///
/// 被守的行为不是「某个函数返回了什么」，而是**一整条会丢用户进度的链**：
///
/// ```
/// 跨章翻进新章（恢复锚 = 章首目标 0.0/-1）
///   → 恢复落定 → 用户读到章中（实时进度 0.62 / char 1500）
///   → renderer 被 OOM 回收 → 换 key 重建 → 新 WebView 按恢复锚 restore
///   → _onRestoreComplete → _refreshProgress → _debouncedSavePosition 落库
/// ```
///
/// 修复前：恢复锚停在进章快照 `0.0 / -1`，重建 restore 回章首，随后把**章首**如实
/// 落库，覆盖掉 DB 里更靠后的真实进度（不可逆）。
/// 修复后：恢复落定之后实时进度接管恢复锚（[restoreAnchorOnLiveProgress]），重建
/// restore 回 0.62/1500，落库值与重建前逐字相同。
///
/// 下面的 [_ReaderProgressLoop] 按真实调用顺序把这条链跑一遍，落库那一步走生产的
/// [readerPositionSaveArgs]（`_persistPosition` 用的同一个纯函数），所以断言的是
/// **真正写进 DB 的那两个值**，不是中间变量。
void main() {
  group('恢复锚生命周期：恢复在飞 = 导航目标，恢复落定 = 当前进度', () {
    test('恢复在飞时，旧页面的实时进度采样不得覆盖尚未消费的导航目标', () {
      const ReaderRestoreAnchor pendingTarget = ReaderRestoreAnchor(
        progress: 0.4,
        charOffset: 900,
      );

      final ReaderRestoreAnchor next = restoreAnchorOnLiveProgress(
        current: pendingTarget,
        restoreInFlight: true,
        // 旧页面还在屏上，采到的是上一章的位置。
        liveProgress: 0.97,
        liveCharOffset: 4200,
      );

      expect(next, pendingTarget, reason: '恢复尚未落定 = 目标还没被消费，采样属于旧页面，绝不能顶掉目标');
    });

    test('恢复落定后，实时进度接管恢复锚', () {
      final ReaderRestoreAnchor next = restoreAnchorOnLiveProgress(
        current: ReaderRestoreAnchor.chapterStart,
        restoreInFlight: false,
        liveProgress: 0.62,
        liveCharOffset: 1500,
      );

      expect(next.progress, 0.62);
      expect(next.charOffset, 1500);
      expect(next.isChapterStart, isFalse,
          reason: '恢复锚必须跟着用户读到的位置走，否则重建就是回退到章首');
    });

    test('一次性字段（句尾锚 / 内链 fragment）在接管时清空', () {
      final ReaderRestoreAnchor next = restoreAnchorOnLiveProgress(
        current: const ReaderRestoreAnchor(
          progress: 0,
          charOffset: 800,
          charOffsetEnd: 830,
          fragment: 'sec3',
        ),
        restoreInFlight: false,
        liveProgress: 0.62,
        liveCharOffset: 1500,
      );

      expect(next.charOffsetEnd, -1,
          reason: '收藏句整句对齐只对发起它的那次导航有效，不得带进下一次 WebView 创建');
      expect(next.fragment, isNull,
          reason: '内链 fragment 同理，一次性；否则重建会跳回内链锚点而不是当前位置');
    });
  });

  group('重建不丢进度（TODO-2603 前置 ①）', () {
    test('读到章中 → renderer 死 → 重建恢复：落库位置 = 重建前位置，不是章首', () {
      final _ReaderProgressLoop reader = _ReaderProgressLoop();

      // ① 跨章翻进第 3 章：导航目标就是章首（_beginNavigation 恒写 0.0 / -1）。
      reader.beginNavigation(
          chapter: 3, target: ReaderRestoreAnchor.chapterStart);
      reader.restoreLands();
      expect(reader.restoredTo, ReaderRestoreAnchor.chapterStart);

      // ② 用户读到章中，进度采样两次（scroll 回传 / 10s 轮询）。
      reader.refreshProgress(progress: 0.31, charOffset: 740);
      reader.refreshProgress(progress: 0.62, charOffset: 1500);
      final ({int normCharOffset, int? charOffset}) beforeCrash =
          reader.lastPersisted!;
      expect(beforeCrash.normCharOffset, 6200);
      expect(beforeCrash.charOffset, 1500);

      // ③ renderer 被系统回收：flush 当前位置 → 换 key 重建 → 新 WebView 按恢复锚
      //    restore → 恢复完成后照常刷新进度并落库。
      reader.rendererGoneAndRebuild();

      expect(reader.restoredTo.isChapterStart, isFalse,
          reason: '重建 restore 必须回到用户读到的位置，回章首就是丢进度');
      expect(reader.restoredTo.charOffset, 1500);
      expect(reader.lastPersisted, beforeCrash,
          reason: '重建后落库的位置必须与重建前逐字相同——'
              '这一条红 = 重建把 DB 里更靠后的真实进度覆盖回退了');
    });

    test('崩溃发生在恢复尚未落定时：落库仍是导航目标，不被旧页面采样污染', () {
      final _ReaderProgressLoop reader = _ReaderProgressLoop();
      reader.beginNavigation(
          chapter: 3, target: ReaderRestoreAnchor.chapterStart);
      reader.restoreLands();
      reader.refreshProgress(progress: 0.62, charOffset: 1500);

      // 用户点了目录跳到第 7 章 25% 处，恢复还没落定就死了。
      reader.beginNavigation(
        chapter: 7,
        target: const ReaderRestoreAnchor(progress: 0.25, charOffset: 610),
      );
      reader.rendererGoneAndRebuild();

      expect(reader.restoredTo.charOffset, 610,
          reason: '恢复在飞期间恢复锚仍是导航目标，重建后接着去目标章位置');
      expect(reader.lastPersisted!.charOffset, 610);
    });
  });
}

/// 阅读器「实时进度 ↔ 恢复锚 ↔ 落库」这一圈的最小复刻。
///
/// 每个方法对应 `reader_fushi/navigation.part.dart` 里的一段真实调用顺序，注释里
/// 标了对应的生产符号；跨过的只有 WebView / DB 这两个 I/O 边界。
class _ReaderProgressLoop {
  /// `_initialProgress` / `_initialCharOffset` / `_initialCharOffsetEnd` /
  /// `_initialFragment` 四个字段的聚合视图（生产里是 `_restoreAnchor` getter）。
  ReaderRestoreAnchor anchor = ReaderRestoreAnchor.chapterStart;

  /// `_restoreInFlight`。
  bool restoreInFlight = false;

  /// `_lastProgressValue` / `_lastProgressCharOffset`。
  double lastProgressValue = 0;
  int lastProgressCharOffset = -1;

  /// 新 WebView 实际被 restore 到哪儿（= 创建那一刻的恢复锚）。
  ReaderRestoreAnchor restoredTo = ReaderRestoreAnchor.chapterStart;

  /// 最后一次真正写进 `reader_positions` 的两个列值。
  ({int normCharOffset, int? charOffset})? lastPersisted;

  /// `_beginNavigation`：恢复锚 := 导航目标，置在飞旗。
  void beginNavigation({
    required int chapter,
    required ReaderRestoreAnchor target,
  }) {
    anchor = target;
    lastProgressValue = target.progress;
    lastProgressCharOffset = target.charOffset;
    restoreInFlight = true;
  }

  /// 新 WebView 起来 → 按恢复锚 restore → `_onRestoreComplete` 清在飞旗。
  void restoreLands() {
    restoredTo = anchor;
    restoreInFlight = false;
  }

  /// `_refreshProgress`：写实时进度 → `_adoptLiveProgressAsRestoreAnchor` → 落库。
  void refreshProgress({required double progress, required int charOffset}) {
    lastProgressValue = progress;
    lastProgressCharOffset = charOffset;
    anchor = restoreAnchorOnLiveProgress(
      current: anchor,
      restoreInFlight: restoreInFlight,
      liveProgress: progress,
      liveCharOffset: charOffset,
    );
    if (restoreInFlight) {
      // `_debouncedSaveReaderPosition` 在恢复期早退。
      return;
    }
    _persist(progress, charOffset);
  }

  /// renderer 死亡处置：`flushBeforeRebuild`（落盘缓存位置）→ 换 epoch key 重建 →
  /// 新 WebView 按恢复锚 restore → 恢复完成刷新进度并落库。
  void rendererGoneAndRebuild() {
    // `_flushPosition()`：落缓存的 `_lastProgress*`。
    _persist(lastProgressValue, lastProgressCharOffset);
    restoreInFlight = true;
    restoreLands();
    // 恢复完成后 `_refreshProgress` 读到的就是 WebView 当前真实位置。
    refreshProgress(
      progress: restoredTo.progress,
      charOffset: restoredTo.charOffset,
    );
  }

  void _persist(double progress, int charOffset) {
    lastPersisted =
        readerPositionSaveArgs(progress: progress, charOffset: charOffset);
  }
}
