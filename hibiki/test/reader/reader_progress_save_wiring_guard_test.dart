import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-736 接线守卫（源码扫描）：锁住 B-1（样式重锚两阶段编排）/ B-3（settle 尾沿去抖）
/// 这两层确实**被接进真实路径**，且 _refreshProgress 的落库门控是「无条件落库」——
/// 旧 B-4（突降伪归零 readerProgressDropIsSpurious + 用户输入打点通道）已删（复核结论 b）。
///
/// 纯函数真值表单测保证逻辑正确，本守卫保证它们接进了真实路径且没退回错误模型。
void main() {
  final String navigation = File(
    'lib/src/pages/implementations/reader_hibiki/navigation.part.dart',
  ).readAsStringSync();
  final String chrome = File(
    'lib/src/pages/implementations/reader_hibiki/chrome.part.dart',
  ).readAsStringSync();
  final String page = File(
    'lib/src/pages/implementations/reader_hibiki_page.dart',
  ).readAsStringSync();
  final String webview = File(
    'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
  ).readAsStringSync();

  /// 切 [src] 里名为 [name] 的方法体（从签名到下一处 `\n  }` 顶层闭合）。
  String methodBody(String src, String signature) {
    final int idx = src.indexOf(signature);
    expect(idx, greaterThanOrEqualTo(0), reason: '找不到方法 $signature');
    final int end = src.indexOf('\n  }', idx);
    expect(end, greaterThan(idx), reason: '找不到方法 $signature 的体结尾');
    return src.substring(idx, end);
  }

  group('B-3：settle 尾沿去抖接进 _handleReaderScroll（在落库刷新之前）', () {
    test(
        '_handleReaderScroll 进门先判 settle 去抖窗并 return，早于 _refreshProgressFromScroll',
        () {
      final String body =
          methodBody(navigation, 'void _handleReaderScroll() {');
      final int settleIdx = body.indexOf('readerScrollWithinReanchorSettle');
      expect(settleIdx, greaterThanOrEqualTo(0),
          reason: '_handleReaderScroll 必须先判 settle 去抖窗');
      expect(body.indexOf('_reanchorClearedAt'), greaterThanOrEqualTo(0),
          reason: '去抖判据须读 _reanchorClearedAt');
      final int refreshIdx = body.indexOf('_refreshProgressFromScroll');
      expect(refreshIdx, greaterThan(settleIdx),
          reason: 'settle 去抖判据必须在 _refreshProgressFromScroll 调用之前——'
              '否则 reflow settle 尾沿的归零 scroll 会先落库（B-3 顺序契约）');
    });
  });

  group('落库门控：_refreshProgress 无条件落库（B-4 已删）', () {
    test('_refreshProgress 调 _debouncedSavePosition，且不再有 B-4 伪归零门控', () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      expect(body, contains('_debouncedSavePosition(progress, charOffset)'),
          reason: '_refreshProgress 必须落库（_debouncedSavePosition）');
      expect(body, isNot(contains('if (!spuriousDrop)')),
          reason: '旧 B-4 伪归零门控已删（复核结论 b：误伤惯性甩动到真章首）；'
              '落库现在无条件（reflow 归零由 _reanchorPending JS 不回传 + B-3 settle 窗双墙覆盖）');
      expect(body, isNot(contains('readerProgressDropIsSpurious')),
          reason: 'readerProgressDropIsSpurious 已删，不得在 _refreshProgress 复活');
      expect(body, isNot(contains('_lastUserInputAt')),
          reason: '用户输入打点通道已删，_refreshProgress 不得再读 _lastUserInputAt');
    });

    test('readerProgressDropIsSpurious / _lastUserInputAt 全仓死符号已清', () {
      expect(page, isNot(contains('bool readerProgressDropIsSpurious(')),
          reason: 'readerProgressDropIsSpurious 纯函数定义已删');
      expect(page, isNot(contains('_lastUserInputAt')),
          reason: '_lastUserInputAt 字段已删');
      expect(webview, isNot(contains('onReaderUserInput')),
          reason: 'onReaderUserInput JS handler + 打点通道已删');
      expect(webview, isNot(contains('_hoshiNotifyUserInput')),
          reason: 'JS 侧 _hoshiNotifyUserInput 输入打点 helper 已删');
    });
  });

  group('B-1：样式重锚两阶段编排接进 _applyStylesLive', () {
    test('_applyStylesLive 调 _reanchorForStyleChange', () {
      expect(page, contains('_reanchorForStyleChange'),
          reason: '_applyStylesLive 必须走样式重锚编排');
    });

    test('_reanchorForStyleChange 用样式专入口 + 编排 + 打 _reanchorClearedAt', () {
      final int idx = chrome.indexOf('Future<void> _reanchorForStyleChange(');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = chrome.indexOf('\n  }\n', idx);
      final String body = chrome.substring(idx, end < 0 ? chrome.length : end);
      expect(body, contains('runUiScaleReanchorOrchestration'),
          reason: '复用两阶段 begin→commit settle-aware 编排');
      expect(body, contains('beginStyleReanchorInvocation'),
          reason: '用样式专用 begin 入口（不复用 appUiScale 那对）');
      expect(body, contains('commitStyleReanchorInvocation'),
          reason: '用样式专用 commit 入口');
      expect(body, contains('readerStyleReanchorAllowed'),
          reason: '门控走 readerStyleReanchorAllowed（两模式都放行）');
      expect(body, contains('_reanchorClearedAt = DateTime.now()'),
          reason: 'commit 完成须打 _reanchorClearedAt 供 B-3 去抖');
    });
  });
}
