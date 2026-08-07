import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2603（BUG-1386 派生）接线守卫：阅读器要具备 renderer 死后**重建**的能力，
/// 三处前置必须一直接在真实路径上。
///
/// 判据本身的真行为测在 `reader_restore_anchor_test.dart`（纯函数 +
/// `readerPositionSaveArgs` 走一整圈落库）；本守卫只保证那条规则**被接进生产代码**
/// 且没被悄悄退回旧形态。窗口一律用 [methodBody] 的花括号配对，不用定长字符窗口。
void main() {
  final String navigation = File(
    'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
  ).readAsStringSync();
  final String webview = File(
    'lib/src/pages/implementations/reader_fushi/webview.part.dart',
  ).readAsStringSync();
  final String page = File(
    'lib/src/pages/implementations/reader_fushi_page.dart',
  ).readAsStringSync();

  group('前置 ①：恢复锚由实时进度接管（否则重建 = 回退到章首并落库）', () {
    test('_adoptLiveProgressAsRestoreAnchor 委托纯函数，并写全四个恢复锚字段', () {
      final String body = methodBody(navigation,
          'void _adoptLiveProgressAsRestoreAnchor(double progress, int charOffset) {');
      expect(containsCodeLine(body, 'restoreAnchorOnLiveProgress('), isTrue,
          reason: '在飞/落定判据必须来自纯函数 restoreAnchorOnLiveProgress，不得在此就地写分支');
      expect(
          containsCodeLine(body, 'restoreInFlight: _restoreInFlight,'), isTrue,
          reason: '判据的输入必须是真实的恢复在飞旗');
      for (final String field in <String>[
        '_initialProgress = next.progress;',
        '_initialCharOffset = next.charOffset;',
        '_initialCharOffsetEnd = next.charOffsetEnd;',
        '_initialFragment = next.fragment;',
      ]) {
        expect(containsCodeLine(body, field), isTrue,
            reason: '恢复锚的四个字段必须整体接管（漏一个就是新旧两代锚混用）：$field');
      }
    });

    test('_refreshProgress 在写完实时进度之后、落库之前接管恢复锚', () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      final String code = maskComments(body);

      final int liveWrite =
          code.indexOf('_lastProgressCharOffset = charOffset;');
      final int adopt = code
          .indexOf('_adoptLiveProgressAsRestoreAnchor(progress, charOffset)');
      final int save =
          code.indexOf('_debouncedSavePosition(progress, charOffset)');

      expect(liveWrite, greaterThanOrEqualTo(0),
          reason: '_refreshProgress 必须写实时进度（锚点）');
      expect(adopt, greaterThan(liveWrite),
          reason: '实时进度是恢复锚的唯一来源——不接管，恢复锚就永远停在进章快照，'
              'renderer 死后重建 restore 回章首并把回退位置落库（TODO-2603 前置 ①）');
      expect(save, greaterThan(adopt), reason: '落库的位置与新 WebView 的恢复目标必须同源且同序');
    });

    test('_syncPositionFromWebViewProgress（退出/lifecycle 实时读）同样接管恢复锚', () {
      final String body = methodBody(navigation,
          'Future<void> _syncPositionFromWebViewProgress() async {');
      expect(
          containsCodeLine(body,
              '_adoptLiveProgressAsRestoreAnchor(snapshot.progress, snapshot.charOffset)'),
          isTrue,
          reason: '实时进度的第二个所有者也必须接管恢复锚，否则两条采样路径给出不同的锚');
    });
  });

  group('前置 ②：调试钩子断言按所有者身份判，同一 State 重装不炸', () {
    test('onWebViewCreated 用 debugHookOwner 身份判据，不再判「钩子必须为 null」', () {
      final String body =
          methodBody(webview, 'onWebViewCreated: (controller) {');
      expect(
          containsCodeLine(
              body, 'identical(ReaderFushiPage.debugHookOwner, this)'),
          isTrue,
          reason: '重装合法性必须按所有者身份判（State 不重建，第二次 onWebViewCreated 合法）');
      expect(containsCodeLine(body, 'ReaderFushiPage.debugHookOwner = this;'),
          isTrue,
          reason: '装钩子时必须登记所有者，否则身份判据永远是 null 分支、检测力度归零');
      for (final String stale in <String>[
        'ReaderFushiPage.debugEvaluateJavascript == null,',
        'ReaderFushiPage.debugCaptureWebView == null,',
      ]) {
        expect(containsCodeLine(body, stale), isFalse,
            reason: '旧断言把「同一页重装」误判成「两个阅读器同时活着」，'
                'renderer 死后重建必炸（TODO-2603 前置 ②）：$stale');
      }
    });

    test('dispose 释放钩子所有权', () {
      final String body = methodBody(page, 'void dispose() {');
      expect(containsCodeLine(body, 'ReaderFushiPage.debugHookOwner = null;'),
          isTrue,
          reason: '不释放所有权，下一个阅读器装钩子时会被身份判据判成「两个阅读器」');
    });
  });

  group('前置 ③：_refreshProgress 的 evaluateJavascript 有错误边界', () {
    test('try/catch 包住 evaluateJavascript，且 fail-open 补 ErrorLogService.log',
        () {
      final String body =
          methodBody(navigation, 'Future<void> _refreshProgress() async {');
      final String code = maskComments(body);

      final int tryIdx = code.indexOf('try {');
      final int evalIdx =
          code.indexOf('await _controller!.evaluateJavascript(');
      final int catchIdx = code.indexOf('} catch (e, stack) {');

      expect(tryIdx, greaterThanOrEqualTo(0),
          reason: '报废 controller 上的 evaluateJavascript 会抛（或永不完成），'
              '裸 await 变成未捕获异步错误（TODO-2603 前置 ③）');
      expect(evalIdx, greaterThan(tryIdx));
      expect(catchIdx, greaterThan(evalIdx));
      expect(containsCodeLine(body, "'ReaderFushi._refreshProgress.eval'"),
          isTrue,
          reason: 'fail-open 不得吞成静默：必须带 source tag 落 ErrorLogService.log');
      expect(
          RegExp(r'ErrorLogService\.instance\s*\.log\(').hasMatch(code), isTrue,
          reason: 'catch 里必须真的调 ErrorLogService.instance.log');
    });
  });
}
