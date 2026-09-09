import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-854：阅读器选区菜单补「收藏」守卫。
///
/// 用户实机反馈手机选区菜单只有「查词 / 复制」，缺「收藏」——app 早有收藏句子能力
/// （`_toggleFavoriteSentence`，桌面底栏 / 查词弹窗顶栏用），但选区菜单从没接进去。
/// 触屏拖选是 **app 自绘选区**（`_handleSelectionMenu`），桌面是 **原生选区右键**
/// （`_showReaderTextContextMenu`），两条选区入口此前都无收藏项。本守卫钉死两处都补上
/// 「收藏」，且各自将实际拖选快照传入同一后端 `_toggleFavoriteSentence`：
///   ① 手机拖选菜单：非模态条的 `'favorite'` + `t.action_favorite`，switch 分支经
///      直接传递自绘选区 data，不把查词整句范围当作收藏范围；
///   ② 桌面右键菜单：菜单抢焦点前快照原生选区，选择收藏后传递该快照；
///   ③ 查词 / 复制两条老出口零回归。
///
/// 真机触屏 WebView 才能跑真手势 + 菜单，故用 Dart 源码扫描钉死契约（与既有
/// reader_mobile_selection_export_menu_guard 同法）。
String _between(String src, String startMarker, String endMarker) {
  final int start = src.indexOf(startMarker);
  final int end = src.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $startMarker');
  expect(end, greaterThan(start), reason: '找不到 $endMarker（在 $startMarker 之后）');
  return src.substring(start, end);
}

void main() {
  final String chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();

  String selectionMenuBody() => _between(
        chrome,
        'Future<void> _handleSelectionMenu(',
        'Future<void> _clearReaderAppSelection(',
      );
  String desktopMenuBody() => _between(
        chrome,
        'Future<void> _showReaderTextContextMenu(',
        'Future<void> _handleSelectionMenu(',
      );

  group('① 手机拖选菜单补「收藏」（自绘选区，无原生选区）', () {
    test('菜单项含 favorite + 复用 action_favorite i18n key', () {
      final String body = selectionMenuBody();
      expect(body, contains("'favorite'"), reason: '缺「收藏」操作项');
      expect(
        body,
        contains('t.action_favorite'),
        reason: '收藏项必须复用既有 action_favorite i18n key（勿新增重复 key）',
      );
      // 查词 / 复制两条老出口仍在（共存，不回退）。
      expect(body, contains('t.search'));
      expect(body, contains('t.copy'));
    });

    test('switch favorite 分支直接消费自绘选区 payload', () {
      // 折叠空白，容忍 dart format 把长调用换行折行（断言不依赖具体换行）。
      final String body = _between(
        selectionMenuBody(),
        "case 'favorite':",
        "case 'export':",
      ).replaceAll(RegExp(r'\s+'), ' ');
      expect(body, contains("case 'favorite':"));
      expect(
        body,
        contains('selection: data'),
        reason: '触屏收藏须直接使用实际拖选 payload，不能被扩展后的查词整句替换',
      );
      expect(body, isNot(contains('_fillLookupStateFromSelectionData')));
      expect(
        body,
        contains('_toggleFavoriteSentence('),
        reason: '收藏必须复用桌面同一后端 _toggleFavoriteSentence',
      );
      expect(
        body,
        contains('_clearReaderAppSelection()'),
        reason: '收藏完清掉 app 选区高亮',
      );
    });
  });

  group('② 桌面右键菜单补「收藏」（原生选区）', () {
    test('菜单项含 favorite + 复用 action_favorite i18n key', () {
      final String body = desktopMenuBody();
      expect(body, contains("value: 'favorite'"), reason: '桌面右键缺「收藏」菜单项');
      expect(body, contains('t.action_favorite'));
      // 门控与老三项一致：桌面右键仅 Windows。
      expect(body, contains('isWindowsPlatform'), reason: '桌面右键菜单门控不得回退');
    });

    test('菜单获取焦点前捕获原生选区，收藏消费快照', () {
      final String body = desktopMenuBody();
      expect(body, contains("case 'favorite':"));
      final int capture = body.indexOf(
        'await _fillLookupStateFromNativeSelection()',
      );
      expect(capture, greaterThanOrEqualTo(0));
      expect(
        capture,
        lessThan(body.indexOf('await showMenu<String>(')),
        reason: '菜单抢焦点前必须快照原生拖选范围',
      );
      final String favorite = _between(
        body,
        "case 'favorite':",
        "case 'export':",
      );
      expect(favorite, contains('selection: favoriteSelection'));
      expect(
        favorite,
        isNot(contains('_fillLookupStateFromNativeSelection()')),
        reason: '菜单关闭后不得重读可能已经丢失的原生选区',
      );
      expect(
        favorite,
        contains('_toggleFavoriteSentence('),
        reason: '收藏必须复用桌面同一后端 _toggleFavoriteSentence',
      );
    });
  });
}
