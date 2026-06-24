import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-806 守卫：框选 tap 坐标探针 + barrier-hover 真坐标系修复（源码扫描，
/// 沿用 `reader_live_settings_guard_test.dart` 的合并语料 + `contains` 静态断言
/// 模式）。reader 页含真实 `InAppWebView` 平台视图，无法在 widget 测试里挂载，
/// 故以结构守卫代替手动设备复测：任一处退回原状本测试即红。
///
/// 守护两件事：
/// - A. JS 端 onTap 发射点有 `[806-TAP]` 调试探针，且**门控**在
///   `${DebugLogService.instance.enabled}` 后（与 `[792-REVEAL]`/`[753-DIAG]` 同
///   一注入期门控开关），口径注释写明 = WebView CSS 视口像素。撤回探针或去掉门控
///   即红。
/// - B. `onDismissBarrierHover` 用 WebView 的 RenderBox `globalToLocal` 把全局
///   指针位置映成 WebView 局部坐标（与 onShiftHover 口径一致），**不再**把
///   `event.localPosition`（相对 dismiss barrier）直接喂给 `_selectTextAt`。撤回
///   到裸 `_selectTextAt(event.localPosition...)` 即红。
void main() {
  final String src = readReaderPageSource();

  group('TODO-806 selection coord probe + barrier-hover frame', () {
    test('A. [806-TAP] onTap probe exists and is debug-log gated', () {
      expect(src, contains('[806-TAP]'),
          reason: 'onTap 框选坐标探针被移除——日志里又没有标明口径的真实点击坐标。');

      // 探针必须落在注入期门控块内：截取探针前后一小段，断言门控开关在 console.log
      // 之前出现（gate 用 `${DebugLogService.instance.enabled}` 在拼 JS 字符串时
      // 决定是否注入这段）。
      final int probeIdx = src.indexOf("console.log('[806-TAP]");
      expect(probeIdx, greaterThan(0),
          reason: '[806-TAP] 必须经 console.log 走 onConsoleMessage 管道。');
      final String window =
          src.substring((probeIdx - 400).clamp(0, src.length), probeIdx);
      expect(
        window.contains(r'if (${DebugLogService.instance.enabled})'),
        isTrue,
        reason: '[806-TAP] 探针必须门控在 \${DebugLogService.instance.enabled} 后，'
            '默认 off，开调试日志才注入打印（沿用 [792-REVEAL] 同开关，别新造）。',
      );

      // 口径注释：明确是 WebView CSS 视口像素，非 OS 屏幕坐标。
      expect(src, contains('CSS 视口像素'),
          reason: '[806-TAP] 必须注释口径=WebView CSS 视口像素以正本清源。');
    });

    test('B. barrier-hover maps global→WebView-local via globalToLocal', () {
      // 取 onDismissBarrierHover 方法体切片做断言。
      final int start = src.indexOf('void onDismissBarrierHover(');
      expect(start, greaterThan(0),
          reason: '找不到 onDismissBarrierHover——方法被改名或移除。');
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);

      // 必须经 WebView 的 RenderBox 把全局指针位置映成局部坐标。
      expect(body, contains('_webViewKey'),
          reason: 'barrier-hover 必须用 WebView 的 GlobalKey 拿 RenderBox 换算坐标。');
      expect(body, contains('globalToLocal(event.position)'),
          reason: 'barrier-hover 必须用 globalToLocal(event.position) 映成 '
              'WebView 局部坐标，而非相对 barrier 的 event.localPosition 直传。');

      // 撤回守卫：不得把 event.localPosition 直接喂给 _selectTextAt。
      expect(
        body.contains('_selectTextAt(event.localPosition'),
        isFalse,
        reason: 'barrier-hover 退回裸 _selectTextAt(event.localPosition...) 会按 '
            'chrome inset 整体偏移命中错字符（TODO-806 根因），守卫禁止回退。',
      );
    });
  });
}
