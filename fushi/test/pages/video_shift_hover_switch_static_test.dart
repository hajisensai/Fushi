import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

import 'video_fushi_page_source_corpus.dart';

/// BUG-861：视频「按住 Shift 连续切换查词」在首弹后失效的修复守卫。
///
/// **根因**：首次悬停查词弹出的浮层在根 Overlay 铺一层全屏 dismiss barrier 盖在字幕之上，
/// 字幕盒自己的 [MouseRegion.onHover]（`VideoSubtitleOverlay._handleShiftHover`）被遮住收不到
/// hover。阅读器早在 barrier 外层挂 `Listener(onPointerHover: onDismissBarrierHover)` 转发换词，
/// 视频页此前只有 `GestureDetector`（无 hover 转发），故首弹后无法再连续切换查词。
///
/// **修法**：barrier 外层挂 `Listener(onPointerHover: _onDismissBarrierHover)`；`_onDismissBarrierHover`
/// 按住 Shift / 悬停即查词门控 + 8px 节流 + `_subtitleHitTester` 反查 + `shouldSwitchWordOnBarrierTap`
/// 非嵌套门控 → `_handleSubtitleHoverLookup`（与字幕盒 `onCharHover` 共用的同句同 grapheme 去重
/// 入口）→ `_handleSubtitleLookupTap`（`replaceStack` 换词）。
///
/// 浮层需真实平台视图，无法纯单测真实 hover→换词，故守两层：
/// 1. 纯函数 [VideoFushiPage.shouldSwitchWordOnBarrierTap] 门控（悬停切词复用同一判据）；
/// 2. 源码接线守卫：barrier 挂 Listener.onPointerHover、`_onDismissBarrierHover` 门控/节流/去重
///    入口、`onCharHover` 走去重入口、关栈复位去重键（防回归把这些环删掉 / 改回无 hover 转发）。
void main() {
  group('shouldSwitchWordOnBarrierTap — 悬停切词复用的非嵌套+命中门控', () {
    test('非嵌套（仅顶层）+ 命中字幕字符 → 换词', () {
      expect(
        VideoFushiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 0,
          hitSubtitle: true,
        ),
        isTrue,
      );
    });

    test('仅剩隐藏热槽（topVisibleIndex == -1）+ 命中 → 换词', () {
      expect(
        VideoFushiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: -1,
          hitSubtitle: true,
        ),
        isTrue,
      );
    });

    test('嵌套态（存在父层）→ 不换词（否则误替整栈）', () {
      expect(
        VideoFushiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 1,
          hitSubtitle: true,
        ),
        isFalse,
      );
    });

    test('未命中字幕字符 → 不换词', () {
      expect(
        VideoFushiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: 0,
          hitSubtitle: false,
        ),
        isFalse,
      );
    });
  });

  group('barrierHoverThresholdPx — 与字幕盒 8px 阈值同构', () {
    test('阈值为 8px', () {
      expect(VideoFushiPage.barrierHoverThresholdPx, 8);
    });
  });

  group('源码接线守卫', () {
    final String page = readVideoFushiSource();

    test('dismiss barrier 外层挂 Listener 转发 hover 给 _onDismissBarrierHover', () {
      final String overlay = _functionSource(
        page,
        'Widget _buildPopupOverlay(',
        'Future<MinePopupResult> onMineEntry(',
      );
      // barrier 段：Listener(onPointerHover:) 包住 GestureDetector（有 onTapUp 的那层）。
      expect(
        overlay.contains('onPointerHover: _onDismissBarrierHover'),
        isTrue,
        reason: 'barrier 必须转发 onPointerHover，否则首弹后连续切换查词失效',
      );
      // Listener 必须在 barrier 的 GestureDetector 之外（先出现）。
      expect(
        overlay.indexOf('onPointerHover: _onDismissBarrierHover'),
        lessThan(overlay.indexOf('onTapUp: (TapUpDetails d) =>')),
        reason: 'Listener 应包在 barrier GestureDetector 外层',
      );
    });

    test('_onDismissBarrierHover：门控 + 节流 + 反查 + 非嵌套门控 → 去重入口', () {
      final String hover = _functionSource(
        page,
        'void _onDismissBarrierHover(PointerHoverEvent event) {',
        'void _handleSubtitleHoverLookup(',
      );
      // 门控与字幕盒 _handleShiftHover 一致：按住 Shift 或开「悬停即查词」。
      expect(
          hover.contains('HardwareKeyboard.instance.isShiftPressed'), isTrue);
      expect(
        hover.contains('ReaderFushiSource.instance.hoverAutoLookup'),
        isTrue,
      );
      // 8px 平方阈值节流。
      expect(
        hover.contains('barrierHoverThresholdPx'),
        isTrue,
        reason: '必须 8px 节流，避免每像素抖动都查',
      );
      // 全局坐标反查复用字幕命中句柄。
      expect(
          hover.contains('_subtitleHitTester.hitTest(event.position)'), isTrue);
      // 非嵌套 + 命中门控复用纯函数。
      expect(
        hover.contains('VideoFushiPage.shouldSwitchWordOnBarrierTap('),
        isTrue,
      );
      // 换词经统一去重入口。
      expect(hover.contains('_handleSubtitleHoverLookup('), isTrue);
    });

    test('_handleSubtitleHoverLookup：同句同 grapheme 去重后转发查词', () {
      final String funnel = _functionSource(
        page,
        'void _handleSubtitleHoverLookup(',
        'void _onDismissBarrierTap(',
      );
      expect(
        funnel.contains('_barrierHoverLastSentence') &&
            funnel.contains('_barrierHoverLastGrapheme'),
        isTrue,
        reason: '两条 hover 路径共用同句同 grapheme 去重键',
      );
      expect(funnel.contains('_handleSubtitleLookupTap('), isTrue);
    });

    test('字幕盒 onCharHover 走去重入口（非直连 _handleSubtitleLookupTap）', () {
      // layout.part.dart 在合并语料里；onCharHover 必须指向去重入口。
      expect(
        page.contains('onCharHover: _handleSubtitleHoverLookup'),
        isTrue,
        reason: 'onCharHover 直连 _handleSubtitleLookupTap 会与 barrier hover 双查同词',
      );
      // onCharTap（点击查词）仍直连，重复点同字要能重查。
      expect(page.contains('onCharTap: _handleSubtitleLookupTap'), isTrue);
    });

    test('_popNestedPopupAt 关栈会话结束复位悬停去重键', () {
      final String pop = _functionSource(
        page,
        'void _popNestedPopupAt(',
        'Widget _buildNestedPopupLayer(',
      );
      expect(
        pop.contains('_barrierHoverLastSentence = \'\'') &&
            pop.contains('_barrierHoverLastGrapheme = -1'),
        isTrue,
        reason: '会话结束不复位则关掉浮层后再悬停同字符会被去重键挡住不重查',
      );
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
