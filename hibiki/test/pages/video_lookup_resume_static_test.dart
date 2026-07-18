import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 视频查词暂停后「关浮层不自动续播」修复（BUG-072）的守卫。
///
/// **根因**：[VideoHibikiPage] 用 [DictionaryPageMixin]（不像阅读器有
/// `onAllPopupsDismissed` 钩子）。`_lookupAt` 打开查词浮层时暂停了视频，但**没有任何
/// 代码**在浮层栈关闭后恢复播放——阅读器靠 `onAllPopupsDismissed`→`_clearLookupState`
/// →`play()`，视频页缺这一环，于是关掉查词窗后视频停在那里，必须手动续播。
///
/// **修法**：① 仅当查词前视频在播放才暂停并置位 `_pausedForLookup`；② `_popNestedPopupAt`
/// 是遮罩点击 / 返回键 / 浮层滑动·Esc 全部关栈路径的唯一汇聚点，在此当**整栈已空**且
/// `_pausedForLookup` 时恢复播放并清标记。
///
/// media_kit/libmpv 在测试宿主不可用（[VideoPlayerController] 延迟构造 Player），无法纯
/// 单测真实播放，故守两层：
/// 1. 纯函数 [VideoHibikiPage.shouldResumeAfterLookupDismiss] 的两条件与门逻辑；
/// 2. 源码守卫：`_lookupAt` 只在 `isPlaying` 时暂停并置位、`_popNestedPopupAt` 关栈后据
///    该纯函数恢复播放并清标记（防回归把恢复环删掉 / 把暂停改回无条件）。
///
/// 合并（守卫审计）：本文件同时承载查词暂停/热槽生命周期的另两份源码守卫——
/// - 原 video_lookup_pause_nonblocking_guard_test.dart（pause 不得阻塞弹窗）的断言并入
///   「_lookupAt 仅在 isPlaying 时暂停并置位」测试；
/// - 原 video_warm_popup_guard_test.dart（BUG-094 常驻热槽）两个 test 整体并入末尾 group。
void main() {
  group('shouldResumeAfterLookupDismiss — 两条件与门', () {
    test('栈空 + 因查词暂停 → 恢复', () {
      expect(
        VideoHibikiPage.shouldResumeAfterLookupDismiss(
          stackEmpty: true,
          pausedForLookup: true,
        ),
        isTrue,
      );
    });

    test('栈非空（关掉递归子层但父层仍在）→ 不恢复', () {
      expect(
        VideoHibikiPage.shouldResumeAfterLookupDismiss(
          stackEmpty: false,
          pausedForLookup: true,
        ),
        isFalse,
      );
    });

    test('查词前本就暂停（未置位）→ 不恢复', () {
      expect(
        VideoHibikiPage.shouldResumeAfterLookupDismiss(
          stackEmpty: true,
          pausedForLookup: false,
        ),
        isFalse,
      );
    });
  });

  group('源码接线守卫', () {
    // TODO-590 batch13: `_lookupAt` 已搬进 lookup_favorite.part.dart，改读合并语料；
    // 其 end marker 由留主壳的 `_popNestedPopupAt` 改成同被搬走、在 part 里紧跟
    // `_lookupAt` 的 `_refreshVideoSentenceFavorite`（合并语料把 part 拼在末尾，旧
    // end marker 在 start 前会切片失败）。`_popNestedPopupAt` 仍在主壳，test2 不变。
    final String page = readVideoHibikiSource();

    test('_lookupAt 仅在 isPlaying 时暂停并置位 _pausedForLookup', () {
      final String lookup = _functionSource(
        page,
        'Future<void> _lookupAt(',
        'Future<void> _refreshVideoSentenceFavorite(',
      );
      // 暂停被 isPlaying 门控（不再无条件 pause）。
      expect(
        lookup.contains('if (controller.isPlaying)'),
        isTrue,
        reason: '查词只在视频播放时暂停，否则关浮层会把本就暂停的视频自动播起来',
      );
      expect(lookup.contains('_pausedForLookup = true'), isTrue);
      // 置位必须在暂停之后、在判空 return 之后（空词不弹浮层 → 不能暂停）。
      expect(
        lookup.indexOf('if (term.isEmpty) return'),
        lessThan(lookup.indexOf('controller.isPlaying')),
        reason: '先判空再暂停，避免暂停后无浮层可关导致卡暂停',
      );
      // Perf guard（查词弹窗弹出慢，源自 video_lookup_pause_nonblocking_guard_test.dart）：
      // media_kit/libmpv `pause()` 桌面端有 IPC 往返，await 它再 pushNestedPopup 会把首次
      // 查词的弹窗拖慢一整个 pause 延迟。pause 是副作用，必须 fire-and-forget（`unawaited`）
      // 同时立即推弹窗。
      expect(lookup, contains('unawaited(controller.pause())'),
          reason: 'pause must be fire-and-forget so it never blocks the popup');
      expect(lookup.contains('await controller.pause()'), isFalse,
          reason:
              'awaiting pause before pushNestedPopup re-introduces the first-'
              'lookup popup delay (perf regression)');
      // The resume contract (BUG-072) still requires the paused flag to be set.
      expect(lookup, contains('_pausedForLookup = true'),
          reason: 'must still mark paused-for-lookup for the resume path');
    });

    test('_popNestedPopupAt 关栈后据纯函数恢复播放并清标记', () {
      final String pop = _functionSource(
        page,
        'void _popNestedPopupAt(',
        'Widget _buildNestedPopupLayer(',
      );
      expect(pop.contains('VideoHibikiPage.shouldResumeAfterLookupDismiss('),
          isTrue);
      // BUG-094：常驻隐藏热槽使 `_popupStack` 永不为空，故「整栈已空」判定改为
      // 「无可见弹窗」(!_hasVisiblePopup)——否则关浮层后热槽仍在、恢复永不触发。
      // TODO-040 后该判定提升为局部 `stackEmpty`（恢复播放与归还焦点共用）。
      expect(pop.contains('final bool stackEmpty = !_hasVisiblePopup;'), isTrue,
          reason: '空栈判定必须源自 !_hasVisiblePopup（热槽不算）');
      expect(pop.contains('stackEmpty: stackEmpty'), isTrue);
      expect(pop.contains('pausedForLookup: _pausedForLookup'), isTrue);
      expect(pop.contains('_pausedForLookup = false'), isTrue,
          reason: '恢复后必须清标记，否则下次关任意子层都会误续播');
      expect(pop.contains('_controller?.play()'), isTrue,
          reason: '整栈关闭后必须恢复播放（BUG-072 核心）');
    });
  });

  /// BUG-094 source guard（源自 video_warm_popup_guard_test.dart）: VideoHibikiPage
  /// seeds one persistent hidden warm popup slot and reuses it for every lookup,
  /// so the popup WebView is never cold-loaded per lookup (the white flash that
  /// lasted "until the auto-read audio finished"). VideoHibikiPage drives
  /// media_kit, so its lookup/pause/resume/overlay behaviour can't be
  /// widget-tested headlessly; these guards lock the wiring instead.
  ///
  /// Post-unification the popup stack is owned by the shared
  /// [DictionaryPopupController]; the warm-slot seed/reuse/hide-and-keep semantics
  /// now live in the controller (behaviourally covered by
  /// dictionary_popup_controller_test.dart + dictionary_page_mixin_warm_slot_test.dart).
  group('BUG-094 常驻热槽 warm popup 源码守卫', () {
    // TODO-590 batch13: `_lookupAt`（含 `reuseWarmSlot: true`）已搬进
    // lookup_favorite.part.dart，改读合并语料。
    test('video seeds and reuses a persistent warm popup slot', () {
      final String src = readVideoHibikiSource();

      // A persistent hidden warm slot is seeded once the video loads successfully
      // via the shared controller (skipped in low memory inside the controller).
      expect(src, contains('void _seedWarmPopup()'));
      expect(src, contains('_popup.seedWarmSlot()'),
          reason: 'seeding must delegate to the shared controller');
      expect(src, contains('DictionaryPopupController('),
          reason: 'controller constructed (with the low-memory budget)');
      expect(src, contains('appModel.lowMemoryMode'),
          reason: 'low-memory budget threaded into the controller');
      expect(src, contains('_seedWarmPopup();'),
          reason: 'the video success path must seed the warm slot');

      // Top lookups reuse that warm slot instead of recreating the WebView.
      expect(src, contains('reuseWarmSlot: true'),
          reason:
              '_lookupAt must reuse the warm slot, not cold-load a new WebView');
    });

    test(
        'closing hides-and-keeps the warm slot; resume/back key off visibility',
        () {
      final String src = readVideoHibikiSource();

      // Close delegates to the controller, which hides-and-keeps the warm slot
      // (rather than clearing it). The video also clears the warm WebView's text
      // selection on close.
      expect(src, contains('_popup.dismissAt(index)'));
      expect(src, contains('_popup.entries.first.isWarmSlot'));

      // The persistent warm slot keeps the stack non-empty, so resume + back must
      // key off "no VISIBLE popup", not "stack empty" — else BUG-072 resume never
      // fires and back never exits the page.
      expect(src, contains('bool get _hasVisiblePopup'));
      // TODO-040 hoisted the emptiness check into a local (shared by resume +
      // keyboard-focus reclaim); it must still derive from !_hasVisiblePopup.
      expect(src, contains('final bool stackEmpty = !_hasVisiblePopup;'),
          reason:
              'resume-after-dismiss must treat the hidden warm slot as empty');
      expect(src, contains('stackEmpty: stackEmpty'),
          reason: 'resume must key off the visible-popup-derived emptiness');
      expect(src, contains('if (_hasVisiblePopup)'),
          reason:
              'back/exit + dismiss barrier must ignore the hidden warm slot');
      expect(src, isNot(contains('stackEmpty: _popup.entries.isEmpty')),
          reason:
              'must not resume off raw stack emptiness with a warm slot present');
    });
  });
}

/// 截取 [source] 中从 [start] 标记到 [end] 标记之间的源码片段（含 [start]、不含 [end]）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
