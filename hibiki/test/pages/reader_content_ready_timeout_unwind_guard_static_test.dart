import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-868 源码守卫：打开 EPUB 偶发「看似打开、翻页永久失效、进度不保存」。
///
/// 根因 = 内容就绪兜底看门狗 `_startContentReadyTimeout` 的超时回调只翻
/// `_readerContentReady = true` 摘掉遮罩，却漏了复位导航态
/// （`_restoreInFlight` / `_isNavigatingToChapter` / `_restoreCompleter`）。
/// 当 `window.fushiReader` 偶发不回 `onRestoreComplete` 时，这三者恒悬空 →
/// `_paginationInFlight`（chrome.part.dart：`_restoreInFlight || !_readerContentReady
/// || _isNavigatingToChapter`）恒真 → 翻页 tick 全被守卫吞掉、位置保存也停摆。
///
/// 修复 = 超时回调在强制置 `_readerContentReady = true` 的同一路径里，连同解开导航态：
/// `_isNavigatingToChapter = false` + `_failNavigation()`（清 `_restoreInFlight`、
/// complete(false) 并清空 `_restoreCompleter`），与 `_navigateToChapterAndWait` 的
/// 等待超时收尾同构。
///
/// 守卫断言修复结构在位：①超时回调体内既有 `_readerContentReady = true` 又有
/// `_isNavigatingToChapter = false` 与 `_failNavigation()`；②`_failNavigation` helper
/// 本身仍清 `_restoreInFlight` 并 complete/清空 completer（防被掏空）。删掉任一即红。
/// ReaderHibikiPage 过重（WebView + 音频 + 全 ProviderContainer），无法在 widget test
/// 可靠拉起跑该超时回调，故落在最强可靠可落地的源码语料层（与 reader_* 一系列
/// *_static_test 同纪律）。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '文件不存在：$rel');
    return f.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('内容就绪兜底超时回调必须连同解开导航态（restore/navigate/completer）', () {
    final String src = read(
        'lib/src/pages/implementations/reader_hibiki/navigation.part.dart');

    // 取 `_startContentReadyTimeout` 体到下一个方法 `_clearContentReadyTimeout` 之间，
    // 保证断言只落在该超时回调上、不被文件别处的同名语句误判为通过。
    final int start = src.indexOf('void _startContentReadyTimeout() {');
    expect(start, greaterThan(-1), reason: '找不到 _startContentReadyTimeout');
    final int end = src.indexOf('void _clearContentReadyTimeout() {', start);
    expect(end, greaterThan(start),
        reason: '找不到 _clearContentReadyTimeout（用于界定超时体范围）');
    final String body = src.substring(start, end);

    // ① 超时回调仍走「强制摘遮罩」这条路径。
    expect(body.contains('_readerContentReady = true;'), isTrue,
        reason: '超时回调应强制置内容就绪摘掉遮罩');

    // ② 同一超时回调里必须解开导航态，否则 _paginationInFlight 恒真、翻页永久卡死。
    // 解开导航态的唯一途径是 _failNavigation()（③ 钉住它确实清了三样东西）。此处
    // **不再**要求回调里另有一行裸 `_isNavigatingToChapter = false;`——那行与
    // _failNavigation 内部完全重复，当年只为满足本断言而保留，删掉不改变任何行为。
    expect(body.contains('_failNavigation();'), isTrue,
        reason: '超时回调必须 _failNavigation 清导航态（含 _isNavigatingToChapter / '
            '_restoreInFlight）并收尾 completer');

    // ③ _failNavigation helper 自身仍复位导航/恢复旗并 complete/清空 completer。
    // 断言下移到 helper 内部后，「超时回调解开导航态」这一不变量依然被完整钉住。
    final int failStart = src.indexOf('void _failNavigation() {');
    expect(failStart, greaterThan(-1), reason: '找不到 _failNavigation helper');
    final int failEnd = src.indexOf('\n  }', failStart);
    final String failBody = src.substring(failStart, failEnd);
    expect(failBody.contains('_isNavigatingToChapter = false;'), isTrue,
        reason: '_failNavigation 必须清 _isNavigatingToChapter（否则 '
            '_paginationInFlight 恒真、翻页永久卡死）');
    expect(failBody.contains('_restoreInFlight = false;'), isTrue,
        reason: '_failNavigation 必须清 _restoreInFlight');
    expect(failBody.contains('_restoreCompleter!.complete(false);'), isTrue,
        reason: '_failNavigation 必须完成挂起的 restore completer，放行等待方');
    expect(failBody.contains('_restoreCompleter = null;'), isTrue,
        reason: '_failNavigation 必须清空 _restoreCompleter');
  });
}
