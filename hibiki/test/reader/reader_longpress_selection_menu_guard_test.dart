// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

/// BUG-624 / TODO-1317：手机「长按没有选择了，变成长按选择文字查词了」回归守卫。
///
/// 根因：BUG-609（7edfec52c）为「触屏长按拖选」把松手 `endRangeSelection` 直接
/// `fireTextSelected` → onTextSelected → 立刻弹查词，于是拖选=选中即查词，丢了原有
/// 「拖选一段文本区间 → 复制/普通选择」的能力。修复：拖选松手改弹选区菜单（复制 / 查词）
/// 共存 —— 拖选走 `fireSelectionMenu`(onSelectionMenu)，Dart 端菜单同时给「复制」
/// (Clipboard.setData) 与「查词」(_handleTextSelected) 两条出口；原地未拖动仍退回单击
/// 查词；绝不复活 TODO-1279 掉的原生双选区。
///
/// 真机触屏 WebView 才能跑真手势 + 菜单（离屏 pointer:fine 不触发 coarse），故用生成 JS
/// + Dart 源码扫描钉死契约。
String _between(String src, String startMarker, String endMarker) {
  final int start = src.indexOf(startMarker);
  final int end = src.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  expect(end, greaterThan(start), reason: '找不到 $endMarker（在 $startMarker 之后）');
  return src.substring(start, end);
}

void main() {
  group('拖选松手弹选区菜单（复制/查词共存，不再强制查词）', () {
    final String js = ReaderSelectionScripts.source();

    test('endRangeSelection 真拖动路由到 fireSelectionMenu，不再直接 fireTextSelected',
        () {
      final String body = _between(
          js, 'endRangeSelection: function', 'getSelectionRect: function');
      expect(body, contains('this.fireSelectionMenu(x, y)'),
          reason: '真拖动松手必须弹选区菜单（fireSelectionMenu），而不是立刻查词');
      expect(body, isNot(contains('this.fireTextSelected(')),
          reason: '拖选松手不得再直接 fireTextSelected（那就是 BUG-609 的强制查词回归）');
    });

    test(
        'fireSelectionMenu 发 onSelectionMenu，fireTextSelected 发 onTextSelected',
        () {
      expect(js, contains('fireSelectionMenu: function'),
          reason: '缺拖选菜单派发 API');
      final String menuBody = _between(
          js, 'fireSelectionMenu: function', 'collectRangeBetween: function');
      expect(menuBody, contains("callHandler('onSelectionMenu'"),
          reason: 'fireSelectionMenu 必须派发 onSelectionMenu 给 Dart 弹菜单');

      final String tapBody = _between(
          js, 'fireTextSelected: function', 'fireSelectionMenu: function');
      expect(tapBody, contains("callHandler('onTextSelected'"),
          reason: 'tap 查词路径仍走 onTextSelected');
    });

    test('查词与选区菜单共用单一 buildSelectionPayload（同构 payload 契约）', () {
      expect(js, contains('buildSelectionPayload: function'),
          reason: '缺 payload 单一真相源');
      // 两条出口都从同一 buildSelectionPayload 取 payload，避免 payload 分叉。
      final String tapBody = _between(
          js, 'fireTextSelected: function', 'fireSelectionMenu: function');
      final String menuBody = _between(
          js, 'fireSelectionMenu: function', 'collectRangeBetween: function');
      expect(tapBody, contains('this.buildSelectionPayload(x, y)'));
      expect(menuBody, contains('this.buildSelectionPayload(x, y)'));
    });
  });

  group('不破坏 BUG-609（无原生双选区 + 原地未拖动退回单击查词）', () {
    final String js = ReaderSelectionScripts.source();
    final String gestureJs =
        ReaderSelectionScripts.longPressDragGestureScript();

    test('原地长按（未拖动）仍退回 selectText 单击查词', () {
      expect(gestureJs, contains('endRangeSelection'));
      expect(gestureJs, contains('selectText'), reason: '缺「长按未拖动 -> 退回单击查词」兜底');
    });

    test('拖选 helper 段绝不触碰原生选区（不复活双选区）', () {
      final String dragHelpers = _between(
          js, 'collectRangeBetween: function', 'getSelectionRect: function');
      expect(dragHelpers, isNot(contains('window.getSelection')),
          reason: '拖选绝不读/建原生选区（会造双选区）');
      expect(dragHelpers, isNot(contains('.addRange(')), reason: '拖选绝不写原生选区');
      expect(dragHelpers, isNot(contains('removeAllRanges')),
          reason: '拖选绝不动原生选区');
    });
  });

  group('Dart 端：选区菜单同时给「复制」与「查词」两条出口（共存）', () {
    test('webview.part.dart 注册 onSelectionMenu -> _handleSelectionMenu', () {
      final String src =
          File('lib/src/pages/implementations/reader_hibiki/webview.part.dart')
              .readAsStringSync();
      expect(src, contains("handlerName: 'onSelectionMenu'"),
          reason: '缺 onSelectionMenu handler 注册');
      expect(src, contains('_handleSelectionMenu(ReaderSelectionData'),
          reason: 'onSelectionMenu 必须路由到 _handleSelectionMenu');
    });

    test('chrome.part.dart _handleSelectionMenu 同时提供复制 + 查词', () {
      final String src =
          File('lib/src/pages/implementations/reader_hibiki/chrome.part.dart')
              .readAsStringSync();
      final String body = _between(src, 'Future<void> _handleSelectionMenu(',
          'Future<void> _clearReaderAppSelection(');
      // 「查词」出口：复用 tap 查词管道（弹窗内含制卡）。
      expect(body, contains('_handleTextSelected(data)'),
          reason: '选区菜单「查词」必须复用 _handleTextSelected（含制卡）');
      // 「复制」出口：整段选区文本进剪贴板。
      expect(
          body, contains('Clipboard.setData(ClipboardData(text: data.text))'),
          reason: '选区菜单「复制」必须把选区文本进剪贴板');
      // 复用现成 i18n key，两项都在菜单里（共存）。
      expect(body, contains('t.search'));
      expect(body, contains('t.copy'));
    });
  });
}
