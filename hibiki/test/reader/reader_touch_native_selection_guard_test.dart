import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// TODO-1279：书籍长按拖选「双选区并存」根因守卫。
///
/// 症状：在阅读器（书籍）正文里长按拖选文字时，WebView 引擎把长按拖选翻译成
/// **原生文本选区**（蓝色 ::selection），与我们自绘的查词选区高亮
/// （::highlight(hoshi-selection) / .hoshi-dict-highlight）叠成双选区。
///
/// 根因修复：按指针类型消除这条特殊情况——粗指针（触屏，`@media (pointer: coarse)`）
/// 禁用原生 user-select，长按拖选只留我们的查词高亮；细指针（鼠标，桌面）不受影响，
/// 保住桌面 Ctrl+C 复制（caret.part.dart readerShouldHandleDesktopCopy）与右键导出
/// （chrome.part.dart _showReaderTextContextMenu）所依赖的 window.getSelection() 原生选区。
///
/// 复现只在真触屏 WebView 渲染时可见，widget 测试照不到 WebView 原生选区，故这里用
/// CSS 生成器输出扫描钉死契约：① 触屏门控存在且禁用 user-select；② 禁用不是无门控的
/// 全局 user-select:none（那会连桌面鼠标复制/导出一起杀掉）。
void main() {
  Future<ReaderSettings> defaultSettings(HibikiDatabase db) async {
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    return settings;
  }

  /// 取 css() 输出里 `@media (pointer: coarse)` 块体（`{ ... }` 直到配平的闭合括号）。
  /// 返回 null 表示没有该块。
  String? coarsePointerBlock(String css) {
    final int idx = css.indexOf('@media (pointer: coarse)');
    if (idx < 0) return null;
    final int open = css.indexOf('{', idx);
    if (open < 0) return null;
    int depth = 0;
    for (int i = open; i < css.length; i++) {
      final String c = css[i];
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return css.substring(open, i + 1);
      }
    }
    return null;
  }

  test('触屏（pointer: coarse）禁用原生 user-select，消除长按拖选的原生蓝选区', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    final String css = ReaderContentStyles.css(settings: settings);

    final String? block = coarsePointerBlock(css);
    expect(block, isNotNull,
        reason: '缺 @media (pointer: coarse) 触屏门控——长按拖选会复活原生蓝选区');
    expect(block, contains('user-select: none'),
        reason: '触屏块必须禁用 user-select，压掉原生长按拖选选区');
    expect(block, contains('-webkit-user-select: none'),
        reason: '需带 -webkit- 前缀覆盖 WebKit/Blink 系 WebView');
    expect(block, contains('-webkit-touch-callout: none'),
        reason: '触屏块必须禁用 iOS 长按 callout（原生选区/放大镜 UI 的一部分）');
  });

  test('禁用被触屏门控包住，不是无条件全局 user-select:none（保桌面复制/导出）', () async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = await defaultSettings(db);

    final String css = ReaderContentStyles.css(settings: settings);

    // 把触屏块整体挖掉后，正文的 user-select:none 只应剩振假名 rt/rp 那条（历史规则），
    // 不得出现覆盖 body / body * 的无门控 user-select:none —— 那会连桌面鼠标拖选一起
    // 杀掉，破坏 Ctrl+C 复制与右键导出所依赖的原生选区。
    final String? block = coarsePointerBlock(css);
    expect(block, isNotNull);
    final String withoutCoarse = css.replaceFirst(block!, '');
    expect(withoutCoarse, isNot(contains('body * {')),
        reason: '触屏门控外不得有 body * 无条件 user-select:none（会杀桌面复制）');
    // 剩下的 user-select:none 应只服务振假名列（rt/rp），细指针桌面正文可拖选。
    expect(withoutCoarse, contains('ruby > rt, ruby > rp {'),
        reason: '振假名 rt/rp 的 user-select:none 历史规则应保留');
  });
}
