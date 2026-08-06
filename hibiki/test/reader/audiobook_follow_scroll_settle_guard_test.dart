import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-825：连续/滚动模式有声书逐句高亮跟随滚动，恢复平滑动画且不再「滚动结束闪一下屏幕」。
///
/// 背景：TODO-803 为修闪屏把跟随滚动从 `behavior:'smooth'` 砍成 `behavior:'instant'`
/// （瞬时一帧到位）。用户明确反对——要求恢复平滑动画且仍不闪。
///
/// 真因（不是 smooth 动画本身）：连续模式 cue reveal 经 Dart
/// `AudiobookBridge.highlight(reveal:true)` → JS `fushiReader.scrollToTarget`
/// （位于 `_continuousShellScript`）平滑滚动到当前句。这条**程序化跟随滚动当年没武装
/// B-3 250ms settle 保护窗**（eaa151581 只武装 恢复/缩放/换样式 三条 reanchor commit）→
/// smooth 动画落定那帧 WebView 回弹的 scroll 经 `_handleReaderScroll` 回传 → 触发
/// `_refreshProgress` setState 重绘 + 可能命中 TODO-798 非自愿归零判据被反手二次滚动 =
/// 「停下 → 被拽回」闪屏。
///
/// 根因修（保留动画）：
///   ① `scrollToTarget` 三条 scrollBy 全部恢复 `behavior:'smooth'`（动画回来）；
///   ② 在 Dart 跟随滚动调用点（`_onCueChanged` 的 `reveal` 分支）武装
///      `_reanchorClearedAt = DateTime.now()`，让 `readerScrollWithinReanchorSettle` 在平滑
///      滚动落定尾沿 250ms 内一律 return 不落库/不复位 → 从源头消除二次反弹（闪烁治住，
///      不靠砍动画）。
///
/// 本守卫双向锁住修复点：跟随滚动若再退化成 instant（动画被砍）→ 红；
/// 跟随滚动 reveal 分支若不武装 settle 窗（闪屏修复被撤）→ 红。
void main() {
  final String scripts = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  ).readAsStringSync();
  final String audiobookPart = File(
    'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
  ).readAsStringSync();

  /// 取 `_continuousShellScript` 函数体（连续模式那份 fushiReader），避免误把分页 shell
  /// 的滚动函数当成命中。从签名起到下一个顶层 `static String` 声明之间。
  String continuousShellBody() {
    final int start = scripts.indexOf('static String continuousShellSource(');
    expect(start, greaterThanOrEqualTo(0),
        reason: '找不到 continuousShellSource 定义');
    final int next = scripts.indexOf('\n  static ', start + 1);
    final int end = next >= 0 ? next : scripts.length;
    return scripts.substring(start, end);
  }

  /// 取 `scrollToTarget` 函数体（从签名到本函数末尾 `},` 之前）。
  String scrollToTargetBody() {
    final String shell = continuousShellBody();
    final int fnIdx = shell.indexOf('scrollToTarget: function(target)');
    expect(fnIdx, greaterThanOrEqualTo(0),
        reason: '连续 shell 必须有 scrollToTarget（有声书 cue reveal 跟随滚动原语）');
    final int end = shell.indexOf('revealElement: function', fnIdx);
    return shell.substring(fnIdx, end >= 0 ? end : shell.length);
  }

  group('TODO-825 跟随滚动恢复平滑动画（不得退化 instant）', () {
    // 墨水屏模式（eink）更新：三条 scrollBy 的 behavior 收敛为一个共享变量——
    // 默认仍是 'smooth'（TODO-825 契约不变），仅当 CSS 变量
    // --hoshi-reader-eink-mode === '1'（用户显式开墨水屏模式）才取 'auto' 瞬时。
    // 守卫从「三处 smooth 字面量」改为锁这个变量化后的等价不变式：
    //   ① behavior 变量的 smooth 默认 + eink 门控必须存在；
    //   ② 三条 scrollBy 都必须走该变量（不得偷偷写死 instant/auto）。
    test('scrollToTarget：behavior 默认 smooth、仅 eink 降 auto', () {
      final String body = scrollToTargetBody();
      expect(
        RegExp(r'--hoshi-reader-eink-mode').hasMatch(body),
        isTrue,
        reason: 'behavior 的瞬时分支必须由墨水屏模式 CSS 变量门控（用户显式 opt-in），'
            '不得无条件砍动画',
      );
      expect(
        RegExp(r"\?\s*'auto'\s*:\s*'smooth'").hasMatch(body),
        isTrue,
        reason: 'behavior 三元的默认分支必须是 smooth（用户要求恢复平滑动画，'
            'TODO-803 砍成 instant 已被驳回；eink 才允许 auto）',
      );
      final int hits = RegExp(r'behavior:\s*behavior').allMatches(body).length;
      expect(
        hits,
        greaterThanOrEqualTo(3),
        reason: 'scrollToTarget 竖排 rl / 竖排 lr / 横排三条 scrollBy 都必须走共享的 '
            'behavior 变量（默认 smooth）',
      );
    });

    test('scrollToTarget 不得写死 behavior:instant/smooth 之外的字面量（砍动画回归）', () {
      final String body = scrollToTargetBody();
      expect(
        RegExp(r"behavior:\s*'instant'").hasMatch(body),
        isFalse,
        reason: '跟随滚动退化成 instant = 砍掉动画 = 回归 TODO-803 被驳回的修法；'
            '闪烁必须靠 settle 窗治住，不靠砍动画',
      );
      expect(
        RegExp(r"behavior:\s*'auto'").hasMatch(body),
        isFalse,
        reason: "写死 behavior:'auto' 同样是无条件砍动画；瞬时只能经 eink 门控的 "
            'behavior 变量',
      );
    });
  });

  group('TODO-825 闪屏靠 settle 窗治住（reveal 分支必须武装 _reanchorClearedAt）', () {
    /// 取 `_onCueChanged` 方法体（从签名到下一个 `Future<void> _handleCueCrossChapter`）。
    String onCueChangedBody() {
      final int start = audiobookPart.indexOf('void _onCueChanged() {');
      expect(start, greaterThanOrEqualTo(0), reason: '找不到 _onCueChanged 定义');
      final int end =
          audiobookPart.indexOf('Future<void> _handleCueCrossChapter(', start);
      return audiobookPart.substring(
          start, end >= 0 ? end : audiobookPart.length);
    }

    test('cue reveal 分支在发起跟随滚动前打 _reanchorClearedAt 武装 B-3 窗', () {
      final String body = onCueChangedBody();
      // reveal 分支：if (reveal) { _reanchorClearedAt = DateTime.now(); } 必须在
      // AudiobookBridge.highlight(reveal: reveal) 之前。
      final int armIdx = body.indexOf('_reanchorClearedAt = DateTime.now()');
      expect(
        armIdx,
        greaterThanOrEqualTo(0),
        reason: 'TODO-825：cue 权威驱动视口跟随（reveal=true）的平滑滚动必须武装 '
            '_reanchorClearedAt，否则动画落定尾沿 scroll 触发 _refreshProgress 重绘 / '
            'TODO-798 二次复位 = 闪屏（撤此打点即闪屏回归）',
      );
      final int highlightIdx = body.indexOf('AudiobookBridge.highlight(\n');
      expect(highlightIdx, greaterThanOrEqualTo(0),
          reason: '_onCueChanged 末尾必须经 AudiobookBridge.highlight 发起 cue 跟随滚动');
      expect(armIdx, lessThan(highlightIdx),
          reason: 'settle 窗必须在发起平滑跟随滚动之前武装，才能覆盖落定尾沿');
    });
  });
}
