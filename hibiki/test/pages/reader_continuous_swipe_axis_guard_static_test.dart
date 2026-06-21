import 'package:flutter_test/flutter_test.dart';
import 'reader_hibiki_page_source_corpus.dart';

/// BUG-239 源码守卫：阅读器统一手势 `_gestureEnd` 的 onSwipe 回传必须被连续模式
/// 门控（连续模式不发跨轴 onSwipe）。headless WebView 不可用，门控数值正确性由
/// continuous_swipe_axis_test.dart 纯函数影子覆盖，这里锁 JS 注入 + 门控不回退。
void main() {
  late String source;

  setUpAll(() {
    // TODO-589 batch8: setup 脚本(_buildReaderSetupScript)已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    source = readReaderPageSource();
  });

  test('setup script injects the continuousMode flag from settings', () {
    expect(
      source.contains('final bool continuousMode = s.isContinuousMode;'),
      isTrue,
      reason: '必须从 ReaderSettings.isContinuousMode 注入 continuousMode 标志',
    );
    expect(
      source.contains(r'var hoshiContinuousMode = $continuousMode;'),
      isTrue,
      reason: 'setup 脚本必须把 continuousMode 注入成 JS 变量 hoshiContinuousMode',
    );
  });

  test('onSwipe firing in _gestureEnd is gated by !hoshiContinuousMode', () {
    // _gestureEnd 的滑动→onSwipe 分支必须以 !hoshiContinuousMode 开头。
    expect(
      source.contains('if (!hoshiContinuousMode && absDx > absDy'),
      isTrue,
      reason: '连续模式不得在 _gestureEnd 回传 onSwipe（轴向冲突），必须 !hoshiContinuousMode 门控',
    );
  });

  test('does not regress to the unconditional horizontal-only onSwipe', () {
    // 旧实现是无条件的 `if (absDx > absDy && (...)`（无 hoshiContinuousMode 门控）。
    expect(
      source.contains('if (absDx > absDy && (absDx >='),
      isFalse,
      reason: '旧的无门控水平滑动 onSwipe 必须移除，否则连续模式回归轴向冲突',
    );
  });
}
