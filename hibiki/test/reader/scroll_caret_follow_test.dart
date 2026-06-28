import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show readerScrollCaretFollowAllowed;

import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-937：连续/滚动模式下手动滚动正文时，字符级焦点环（caret）不跟随可视区
/// （用户：「滚动模式，焦点不会跟着页面动」）。
///
/// 根因：caret 没有 JS scroll 监听，只在 Dart 显式调 `_caretRefresh()`（refresh 原语，
/// 锚字符离开视口时 `_firstVisibleStop()` 重锚首个可见字符）时移动。分页模式翻页走
/// `_caretReanchor` 焦点跟随；但连续模式手动滚动只走 `_handleReaderScroll` →
/// `_refreshProgressFromScroll`（navigation.part.dart）刷进度，整链从不碰 caret，
/// 旧锚字符随内容滚出视口后焦点环钉死在屏外。
///
/// 修复：在 `_refreshProgressFromScroll` 进度刷新落地的同一 50ms 节流相位
/// （已对齐 hoshi 安卓 CONTINUOUS_PROGRESS_THROTTLE_MS，高频滚动只刷一次 + 停止后
/// 尾沿补一发），经纯函数 [readerScrollCaretFollowAllowed] 门控追加一次 `_caretRefresh()`。
/// 严格在 `readerScrollProgressRefreshAllowed`（恢复期/重锚 settle/歌词/未就绪统一抑制）
/// 之后；只在连续模式 + caret 激活在正文（非弹窗非歌词）时触发，分页模式 / caret 未激活
/// / 弹窗滚动零影响。
///
/// reader_hibiki_page.dart 太重（WebView + DB + provider）不便整页 mount，门控逻辑抽成
/// [readerScrollCaretFollowAllowed] 纯函数在此锁定真值表；调用点接线与节流去抖由
/// 源码扫描守卫锁定，防回归。
void main() {
  group('readerScrollCaretFollowAllowed（滚动焦点环跟随门控真值表）', () {
    test('连续模式 + caret 激活在正文：滚动后重定位焦点环', () {
      expect(
        readerScrollCaretFollowAllowed(
          continuousMode: true,
          caretActive: true,
          caretOnReader: true,
        ),
        isTrue,
      );
    });

    test('分页模式（!continuousMode）抑制——翻页走 _caretReanchor 已跟随，不重复', () {
      expect(
        readerScrollCaretFollowAllowed(
          continuousMode: false,
          caretActive: true,
          caretOnReader: true,
        ),
        isFalse,
        reason: '分页模式焦点环由翻页 _caretReanchor 放置，手动滚动支不得触发',
      );
    });

    test('caret 未激活（!caretActive）抑制——纯触屏无键盘/手柄用户零开销', () {
      expect(
        readerScrollCaretFollowAllowed(
          continuousMode: true,
          caretActive: false,
          caretOnReader: true,
        ),
        isFalse,
        reason: 'caret 未激活时无焦点环可跟随，不应发任何 JS',
      );
    });

    test('caret 不在正文（!caretOnReader，弹窗/歌词表面）抑制', () {
      expect(
        readerScrollCaretFollowAllowed(
          continuousMode: true,
          caretActive: true,
          caretOnReader: false,
        ),
        isFalse,
        reason: '弹窗滚动焦点是另一套 _scrollIntoView，正文滚动支不得触碰',
      );
    });
  });

  group('源码守卫：滚动支去抖调 _caretRefresh 且经纯函数门控', () {
    final String source = readReaderPageSource();

    test(
        '_refreshProgressFromScroll 内经 readerScrollCaretFollowAllowed 门控调 _caretRefresh',
        () {
      // 限定在 _refreshProgressFromScroll 方法体内取门控调用点（语料首处
      // readerScrollCaretFollowAllowed( 是纯函数定义，须从方法起点之后再找）。
      final int methodIdx = source.indexOf('void _refreshProgressFromScroll()');
      expect(methodIdx, greaterThanOrEqualTo(0));
      final int gateIdx =
          source.indexOf('readerScrollCaretFollowAllowed(', methodIdx);
      expect(gateIdx, greaterThanOrEqualTo(0), reason: '滚动支必须经纯函数门控决定是否跟随焦点环');
      final int refreshIdx = source.indexOf('_caretRefresh()', gateIdx);
      expect(refreshIdx, greaterThanOrEqualTo(0),
          reason: '门控通过后必须实际调 _caretRefresh() 重定位焦点环');
      // 门控与 _caretRefresh 必须靠得很近（同一 if 块内），不是文件别处巧合命中。
      expect(refreshIdx - gateIdx, lessThan(220),
          reason: 'readerScrollCaretFollowAllowed 与 _caretRefresh 必须在同一 if 块');
    });

    test('该 _caretRefresh 调用挂在 _refreshProgressFromScroll 的节流相位（与进度刷新同相去抖）',
        () {
      final int methodIdx = source.indexOf('void _refreshProgressFromScroll()');
      expect(methodIdx, greaterThanOrEqualTo(0));
      final int gateIdx =
          source.indexOf('readerScrollCaretFollowAllowed(', methodIdx);
      expect(gateIdx, greaterThanOrEqualTo(0),
          reason: '焦点环跟随必须落在 _refreshProgressFromScroll 内，复用其 50ms 节流/尾沿去抖，'
              '不得另起 Future.delayed 轮询或逐 scroll 回传重测');
      // 节流相位锚点：跟随门控必须在 _lastScrollProgressAt 更新（穿过节流闸门）之后。
      final int throttlePassIdx =
          source.indexOf('_lastScrollProgressAt = now;', methodIdx);
      expect(throttlePassIdx, greaterThanOrEqualTo(0));
      expect(gateIdx, greaterThan(throttlePassIdx),
          reason: '焦点环跟随必须在穿过 50ms 节流闸门之后，与进度刷新同相，不在节流早退分支');
    });
  });
}
