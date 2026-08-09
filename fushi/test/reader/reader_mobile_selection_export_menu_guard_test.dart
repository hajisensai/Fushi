import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1366：手机拖选选区菜单补「导出片段」守卫（自绘拖选 TODO-1317/BUG-624 的遗留缺口）。
///
/// 手机长按拖选出的是 **app 自绘选区**（`onSelectionMenu` -> Flutter 非模态操作条，即
/// `_handleSelectionMenu`），此前只有「查词 / 复制」，缺桌面右键 / 原生 ActionMode 早有的
/// 「导出片段」。本守卫钉死：
///   ① 手机拖选菜单含「导出片段」（`t.audiobook_export_clip`），与桌面同 i18n key，且同门控
///      （本书有音频 cue，`chapterCueCount`）；
///   ② 「导出片段」复用桌面同一后端 `_exportAudiobookClip`——但从 app 自绘选区 payload 填状态
///      （`_exportAudiobookClipFromSelectionData` -> `_fillLookupStateFromSelectionData(...,
///      extractNativeImages: false)`），因为触屏拖选无原生选区（TODO-1279）；
///   ③ 桌面右键 / 原生选区路径零回归：仍走 `_fillLookupStateFromSelectionData(...,
///      extractNativeImages: true)`（选区仍在，抽取夹带插图）。
///
/// 真机触屏 WebView 才能跑真手势 + 菜单，故用 Dart 源码扫描钉死契约（与既有
/// reader_longpress_selection_menu_guard / reader_mobile_context_menu_order_guard 同法）。
String _between(String src, String startMarker, String endMarker) {
  final int start = src.indexOf(startMarker);
  final int end = src.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  expect(end, greaterThan(start), reason: '找不到 $endMarker（在 $startMarker 之后）');
  return src.substring(start, end);
}

void main() {
  final String chrome =
      File('lib/src/pages/implementations/reader_fushi/chrome.part.dart')
          .readAsStringSync();

  group('① 手机拖选菜单补「导出片段」（同桌面 i18n key + 同音频门控）', () {
    test('_handleSelectionMenu 菜单项含 export + 查词 + 复制', () {
      final String body = _between(chrome, 'Future<void> _handleSelectionMenu(',
          'Future<void> _clearReaderAppSelection(');
      expect(body, contains("'export'"), reason: '缺「导出片段」操作项');
      expect(body, contains('t.audiobook_export_clip'),
          reason: '导出项必须复用桌面同一 i18n key');
      // 门控：本书有音频 cue 才出现（与桌面 _showReaderTextContextMenu 同判据）。
      expect(body, contains('chapterCueCount'), reason: '导出项必须按本书是否有音频 cue 门控');
      // 查词 / 复制两条老出口仍在（共存，不回退）。
      expect(body, contains('t.search'));
      expect(body, contains('t.copy'));
    });

    test('switch export 分支复用后端 _exportAudiobookClip（经 selection-data 变体）', () {
      final String body = _between(chrome, 'Future<void> _handleSelectionMenu(',
          'Future<void> _clearReaderAppSelection(');
      expect(body, contains("case 'export':"));
      expect(body, contains('_exportAudiobookClipFromSelectionData(data)'),
          reason: '导出必须从 app 自绘选区 payload 填状态后导出');
      // 查词收敛后隐藏手柄（手柄只描述可调整的拖选区间）。
      expect(body, contains('_hideReaderSelectionHandles()'));
    });
  });

  group('② 拖选导出从 app 选区 payload 填状态（无原生选区）', () {
    test('_exportAudiobookClipFromSelectionData 填状态 + 走既有导出链', () {
      final String body = _between(
          chrome,
          'Future<void> _exportAudiobookClipFromSelectionData(',
          'Future<void> _hideReaderSelectionHandles(');
      expect(
          body,
          contains(
              '_fillLookupStateFromSelectionData(data, extractNativeImages: false)'),
          reason: '移动端自绘拖选无原生选区，抽图关闭');
      expect(body, contains('_exportAudiobookClip();'),
          reason: '必须复用桌面同一后端导出链');
    });
  });

  group('③ 桌面 / 原生选区路径零回归', () {
    test('_fillLookupStateFromNativeSelection 仍抽取原生选区夹带插图', () {
      final String body = _between(
          chrome,
          'Future<ReaderSelectionData?> _fillLookupStateFromNativeSelection(',
          'Future<void> _fillLookupStateFromSelectionData(');
      expect(
          body,
          contains(
              '_fillLookupStateFromSelectionData(data, extractNativeImages: true)'),
          reason: '原生选区路径抽图开启（BUG-455 / TODO-1127 契约不变）');
    });

    test('桌面文字右键菜单仍 isWindowsPlatform 门控 + 走原生选区导出', () {
      final String body = _between(
          chrome,
          'Future<void> _showReaderTextContextMenu(',
          'Future<void> _handleSelectionMenu(');
      expect(body, contains('isWindowsPlatform'), reason: '桌面右键菜单门控不得回退');
      expect(body, contains('_exportAudiobookClipFromSelection()'),
          reason: '桌面导出仍走原生选区变体（零回归）');
    });
  });

  group('④ 点空白取消残留拖选（自然清除路径）', () {
    test('onTapEmpty 清除 app 自绘选区', () {
      final String webview =
          File('lib/src/pages/implementations/reader_fushi/webview.part.dart')
              .readAsStringSync();
      final String body = _between(
          webview, "handlerName: 'onTapEmpty'", "handlerName: 'onSwipe'");
      expect(body, contains('_clearReaderAppSelection()'),
          reason: '点空白必须能取消残留的拖选高亮 + 手柄');
    });
  });
}
