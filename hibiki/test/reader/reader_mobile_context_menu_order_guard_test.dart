import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-544 源码守卫：移动端阅读器选区右键菜单顺序不得回退。
///
/// 菜单是原生 `InAppWebView` 的 `ContextMenu`（Android ActionMode），widget 测试
/// 照不到原生项渲染顺序，故用源码扫描钉死三件事：
/// ① 移动端隐藏系统默认项（`hideDefaultSystemContextMenuItems: true`）——不再保留
///    系统复制/全选/粘贴，避免自定义项被追加到系统项之后而垫底；
/// ② 因隐藏系统项去掉了系统「复制」，必须补一条自定义复制项（`t.copy` +
///    `Clipboard.setData`），复制功能不丢；
/// ③ 「导出片段」（`t.audiobook_export_clip`，id:2）排在「复制」（id:3）之前，
///    即导出不再垫底。
void main() {
  final File webview =
      File('lib/src/pages/implementations/reader_hibiki/webview.part.dart');

  test('webview.part.dart：移动端菜单隐藏系统项 + 补复制 + 导出前置', () {
    expect(webview.existsSync(), isTrue,
        reason: 'webview.part.dart 不存在，路径变了须更新守卫');
    final String src = webview.readAsStringSync();

    // ① 移动端隐藏系统默认项：全文不得再出现保留系统项的 false 值。
    expect(src.contains('hideDefaultSystemContextMenuItems: false'), isFalse,
        reason: '移动端保留系统项会把自定义「导出片段」追加到系统项之后垫底，'
            '必须 hideDefaultSystemContextMenuItems: true 只留自定义项');

    // ② 补自定义复制项：文案复用 t.copy，动作写系统剪贴板。
    expect(src, contains('title: t.copy'),
        reason: '隐藏系统项后必须补一条自定义复制项（t.copy），否则复制功能丢失');
    expect(src, contains('Clipboard.setData'),
        reason: '自定义复制项必须写系统剪贴板 Clipboard.setData');
    expect(src, contains('copied_to_clipboard'),
        reason: '复制成功应提示 copied_to_clipboard（与桌面右键菜单同源）');

    // ③ 导出片段（id:2）排在复制（id:3）之前 → 导出不垫底。
    final int exportIdx = src.indexOf('title: t.audiobook_export_clip');
    final int copyIdx = src.indexOf('title: t.copy');
    expect(exportIdx, greaterThanOrEqualTo(0), reason: '缺「导出片段」菜单项');
    expect(copyIdx, greaterThanOrEqualTo(0), reason: '缺「复制」菜单项');
    expect(exportIdx, lessThan(copyIdx),
        reason: '「导出片段」必须排在「复制」之前（BUG-544：不再垫底）');

    // 导出项本身仍不是 menuItems 列表的最后一项：其后应还有复制项（id: 3）。
    final int id3Idx = src.indexOf('id: 3');
    expect(id3Idx, greaterThan(exportIdx),
        reason: '导出项后应有 id:3 复制项，证明导出不在菜单末位');
  });
}
