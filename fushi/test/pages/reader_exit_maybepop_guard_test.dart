import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-782 守卫：阅读器快捷设置面板「退出」按钮直接 `Navigator.pop()` 绕过
/// PopScope，导致关书后书架陈旧、关书自动同步不触发。
///
/// 前因后果：
/// - 阅读器路由外层是 `PopScope(canPop: false)`（reader_fushi_page.dart），
///   它的 `onPopInvokedWithResult` 才是唯一的退出闸门——里面 `await onWillPop()`，
///   而 `BaseSourcePageState.onWillPop` 依次做：
///     ① `onSourcePagePop()`——最终阅读位置 flush 落库（BUG-203 依赖它，否则
///        「退出再进」回不到上次位置）；
///     ② `appModel.closeMedia()`——内部 invalidate `fushiBooksProvider` /
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
      'lib/src/pages/implementations/reader_fushi/chrome.part.dart';

  /// 读整份 chrome.part.dart 源码（相对 `fushi/` 工作目录，与仓库其它
  /// `*_guard_test` 一致）。
  String readSource() {
    return File(path).readAsStringSync();
  }

  /// 取出每处 `onExitReader:` 命名实参的**值**（回调本体）。
  ///
  /// 用 [namedArgumentValues] 按结构收口：值从 `:` 后起，到同层下一个 `,` /
  /// 闭括号止，注释与字符串已掩码。以前用「下一个具名参数 `webViewController:`」
  /// 当终点，BUG-4945 删掉那个参数后锚点失效；现在与相邻参数的名字、顺序都无关，
  /// 上方 BUG-782 注释里复述根因用的「Navigator.pop()」也不会落进切片。
  List<String> readExitCallbacks(String source) {
    final List<String> values = namedArgumentValues(source, 'onExitReader');
    expect(values, isNotEmpty, reason: 'onExitReader 回调应存在');
    return values;
  }

  /// 退出回调直接写 `maybePop(`，或经 `_exitReaderBook(`（显式退书：在 maybePop
  /// 在途期间挂 `_exitBookRequested`，让歌词层在场时 PopScope 不把它截成「关歌词
  /// 层」）。后者本身必须走 maybePop，由下一条断言钉住。
  bool routesThroughMaybePop(String slice) {
    return slice.contains('maybePop(') || slice.contains('_exitReaderBook(');
  }

  test('_exitReaderBook 本身走 maybePop（不绕过 PopScope）', () {
    final String source = readSource();
    final int start = source.indexOf('Future<void> _exitReaderBook()');
    expect(start, greaterThanOrEqualTo(0), reason: '_exitReaderBook 应存在');
    final int end = source.indexOf('\n  }\n', start);
    final String body = source.substring(start, end);
    expect(body.contains('maybePop('), isTrue);
    expect(body.contains('Navigator.of(context).pop('), isFalse);
  });

  test('onExitReader 回调必须走 maybePop（触发 PopScope→onWillPop 链）', () {
    final String slice = readExitCallbacks(readSource()).first;
    expect(
      routesThroughMaybePop(slice),
      isTrue,
      reason:
          '退出必须经 maybePop() 触发 PopScope 的 onWillPop 闸门，'
          '否则 flush / closeMedia(invalidate) / 自动同步全跳过（BUG-782）',
    );
  });

  test('onExitReader 回调不得直接 Navigator.pop()（绕过 PopScope）', () {
    final String slice = readExitCallbacks(readSource()).first;
    // 精确复发形态：`Navigator.of(context).pop(`。maybePop 写作
    // `Navigator.of(context).maybePop(`，不含该子串，故不会误命中。
    expect(
      slice.contains('Navigator.of(context).pop('),
      isFalse,
      reason:
          '直接 Navigator.of(context).pop() 会绕过 PopScope(canPop:false)，'
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
    // chrome.part.dart 里 onExitReader 只应有一处；逐处校验回调本体，
    // 未来若新增第二处退出入口也强制走 maybePop。
    final List<String> callbacks = readExitCallbacks(readSource());
    for (int i = 0; i < callbacks.length; i++) {
      final String callback = callbacks[i];
      expect(
        routesThroughMaybePop(callback),
        isTrue,
        reason: '第 ${i + 1} 处 onExitReader 回调必须走 maybePop()',
      );
      expect(
        callback.contains('Navigator.of(context).pop(') ||
            callback.contains('Navigator.pop(context'),
        isFalse,
        reason: '第 ${i + 1} 处 onExitReader 回调不得直接 pop（绕过 PopScope）',
      );
    }
  });
}
