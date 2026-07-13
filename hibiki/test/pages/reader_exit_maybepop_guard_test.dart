import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-782 守卫：阅读器快捷设置面板「退出」按钮直接 `Navigator.pop()` 绕过
/// PopScope，导致关书后书架陈旧、关书自动同步不触发。
///
/// 前因后果：
/// - 阅读器路由外层是 `PopScope(canPop: false)`（reader_hibiki_page.dart），
///   它的 `onPopInvokedWithResult` 才是唯一的退出闸门——里面 `await onWillPop()`，
///   而 `BaseSourcePageState.onWillPop` 依次做：
///     ① `onSourcePagePop()`——最终阅读位置 flush 落库（BUG-203 依赖它，否则
///        「退出再进」回不到上次位置）；
///     ② `appModel.closeMedia()`——内部 invalidate `hibikiBooksProvider` /
///        `bookLastReadAtProvider`（BUG-777 依赖它刷新书架「继续阅读」hero 与进度），
///        并还原沉浸模式 / wakelock / mediaOpenNotifier；
///     ③ `triggerAutoSyncAfterClose()`——关书触发远端自动同步。
/// - 快捷设置面板（reader_quick_settings_sheet.dart）退出按钮先 pop 掉面板自身，
///   postFrame 再回调 `onExitReader`。BUG-782 之前 `onExitReader` 是
///   `Navigator.of(context).pop()`——**直接 pop 阅读器路由**，didPop 已为 true，
///   PopScope 的 `onPopInvokedWithResult` 根本不触发 → 上面①②③整条链全跳过。
///   桌面端唯一可见的退出按钮就是它，症状：用户看了另一本书，书架顶部「继续阅读」
///   还是旧书、进度不动，且「好像也没同步远端」。
/// - 正确范式：走 `Navigator.of(context).maybePop()`，它触发 PopScope 回调 →
///   `onWillPop()` → 真正 `nav.pop()`，与键盘 ESC / 手柄 B 分支
///   （caret.part.dart 的 `readerDismissDict`）完全同径。
///
/// 阅读器整页依赖 WebView / DB，pumpWidget 过重，故沿用本仓库 `*_guard_test`
/// 的源码切片范式：切出 `onExitReader` 回调块做静态断言，防复发。
void main() {
  const String path =
      'lib/src/pages/implementations/reader_hibiki/chrome.part.dart';

  /// 读整份 chrome.part.dart 源码（相对 `hibiki/` 工作目录，与仓库其它
  /// `*_guard_test` 一致）。
  String readSource() {
    return File(path).readAsStringSync();
  }

  /// 切出 `onExitReader:` 回调块——从 `onExitReader:` 起，到下一个具名参数
  /// `webViewController:` 止（不含其上方的 BUG-782 中文注释，避免注释里
  /// 复述根因用的「Navigator.pop()」字样污染下面的「无裸 pop」断言）。
  String readExitCallbackSlice(String source) {
    const String start = 'onExitReader:';
    const String end = 'webViewController:';
    final int startIdx = source.indexOf(start);
    final int endIdx = source.indexOf(end, startIdx);
    expect(startIdx, greaterThanOrEqualTo(0), reason: 'onExitReader 回调应存在');
    expect(endIdx, greaterThan(startIdx),
        reason: 'onExitReader 之后应有 webViewController 具名参数作为切片终点');
    return source.substring(startIdx, endIdx);
  }

  test('onExitReader 回调必须走 maybePop（触发 PopScope→onWillPop 链）', () {
    final String slice = readExitCallbackSlice(readSource());
    expect(
      slice.contains('maybePop('),
      isTrue,
      reason: '退出必须经 maybePop() 触发 PopScope 的 onWillPop 闸门，'
          '否则 flush / closeMedia(invalidate) / 自动同步全跳过（BUG-782）',
    );
  });

  test('onExitReader 回调不得直接 Navigator.pop()（绕过 PopScope）', () {
    final String slice = readExitCallbackSlice(readSource());
    // 精确复发形态：`Navigator.of(context).pop(`。maybePop 写作
    // `Navigator.of(context).maybePop(`，不含该子串，故不会误命中。
    expect(
      slice.contains('Navigator.of(context).pop('),
      isFalse,
      reason: '直接 Navigator.of(context).pop() 会绕过 PopScope(canPop:false)，'
          'onWillPop 链全跳过（BUG-782 根因）',
    );
    // 防另一书写变体 `Navigator.pop(context)` 同样绕过 PopScope。
    expect(
      slice.contains('Navigator.pop(context'),
      isFalse,
      reason: 'Navigator.pop(context) 变体同样直接 pop 阅读器路由、绕过 PopScope',
    );
  });

  test('全文件级：每处 onExitReader 回调都必须走 maybePop、无裸 pop（防复发变体）', () {
    final String source = readSource();
    const String marker = 'onExitReader:';
    // chrome.part.dart 里 onExitReader 只应有一处定义；逐处切窗校验，
    // 未来若新增第二处退出入口也强制走 maybePop。
    int cursor = source.indexOf(marker);
    expect(cursor, greaterThanOrEqualTo(0), reason: '至少应有一处 onExitReader');
    int occurrences = 0;
    while (cursor >= 0) {
      occurrences++;
      // 取 onExitReader 后 200 字符窗口（足够覆盖单行 lambda 体）。
      final int windowEnd =
          (cursor + 200) > source.length ? source.length : cursor + 200;
      final String window = source.substring(cursor, windowEnd);
      expect(
        window.contains('maybePop('),
        isTrue,
        reason: '第 $occurrences 处 onExitReader 附近必须出现 maybePop()',
      );
      expect(
        window.contains('Navigator.of(context).pop(') ||
            window.contains('Navigator.pop(context'),
        isFalse,
        reason: '第 $occurrences 处 onExitReader 附近不得直接 pop（绕过 PopScope）',
      );
      cursor = source.indexOf(marker, cursor + marker.length);
    }
    expect(occurrences, greaterThanOrEqualTo(1),
        reason: 'onExitReader 回调应存在且被逐处校验');
  });
}
