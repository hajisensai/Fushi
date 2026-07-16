import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-854：阅读器选区菜单补「收藏」守卫。
///
/// 用户实机反馈手机选区菜单只有「查词 / 复制」，缺「收藏」——app 早有收藏句子能力
/// （`_toggleFavoriteSentence`，桌面底栏 / 查词弹窗顶栏用），但选区菜单从没接进去。
/// 触屏拖选是 **app 自绘选区**（`_handleSelectionMenu`），桌面是 **原生选区右键**
/// （`_showReaderTextContextMenu`），两条选区入口此前都无收藏项。本守卫钉死两处都补上
/// 「收藏」，且各自按选区类型正确填「查词状态」（`currentSentence` / 句级区间非空契约）
/// 后复用同一后端 `_toggleFavoriteSentence`：
///   ① 手机拖选菜单：`value: 'favorite'` + `t.action_favorite`，switch 分支经
///      `_fillLookupStateFromSelectionData(..., extractNativeImages: false)`（无原生选区）
///      填状态后 `_toggleFavoriteSentence()`；
///   ② 桌面右键菜单：同项，switch 分支经 `_fillLookupStateFromNativeSelection()`
///      （原生选区）填状态后 `_toggleFavoriteSentence()`；
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
  final String chrome =
      File('lib/src/pages/implementations/reader_hibiki/chrome.part.dart')
          .readAsStringSync();

  String selectionMenuBody() => _between(
      chrome,
      'Future<void> _handleSelectionMenu(',
      'Future<void> _clearReaderAppSelection(');
  String desktopMenuBody() => _between(
      chrome,
      'Future<void> _showReaderTextContextMenu(',
      'Future<void> _handleSelectionMenu(');

  group('① 手机拖选菜单补「收藏」（自绘选区，无原生选区）', () {
    test('菜单项含 favorite + 复用 action_favorite i18n key', () {
      final String body = selectionMenuBody();
      expect(body, contains("value: 'favorite'"), reason: '缺「收藏」菜单项');
      expect(body, contains('t.action_favorite'),
          reason: '收藏项必须复用既有 action_favorite i18n key（勿新增重复 key）');
      // 查词 / 复制两条老出口仍在（共存，不回退）。
      expect(body, contains('t.search'));
      expect(body, contains('t.copy'));
    });

    test('switch favorite 分支从自绘选区 payload 填状态后走收藏后端', () {
      // 折叠空白，容忍 dart format 把长调用换行折行（断言不依赖具体换行）。
      final String body = selectionMenuBody().replaceAll(RegExp(r'\s+'), ' ');
      expect(body, contains("case 'favorite':"));
      expect(
          body,
          contains(
              '_fillLookupStateFromSelectionData(data, extractNativeImages: false)'),
          reason: '触屏自绘选区无原生选区，须从 payload 填 currentSentence / 句级区间');
      expect(body, contains('_toggleFavoriteSentence()'),
          reason: '收藏必须复用桌面同一后端 _toggleFavoriteSentence');
      expect(body, contains('_clearReaderAppSelection()'),
          reason: '收藏完清掉 app 选区高亮');
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

    test('switch favorite 分支从原生选区填状态后走收藏后端', () {
      final String body = desktopMenuBody();
      expect(body, contains("case 'favorite':"));
      expect(body, contains('_fillLookupStateFromNativeSelection()'),
          reason: '桌面走原生选区路径填 currentSentence（与 search 同源）');
      expect(body, contains('_toggleFavoriteSentence()'),
          reason: '收藏必须复用桌面同一后端 _toggleFavoriteSentence');
    });
  });
}
