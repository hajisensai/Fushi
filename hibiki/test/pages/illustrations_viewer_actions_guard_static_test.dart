import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-093 / BUG-177：插画查看器（IllustrationsViewerPage 的全屏画廊）必须像
/// 阅读器内联图片（TODO-023）一样支持 Windows 右键复制 / 移动端长按分享。
///
/// 源码守卫（headless 无法真触发 PopupMenu / 系统分享面板，故守卫接线）：
/// 1) 全屏画廊持有源磁盘文件 File（复制/分享 channel 需要真实路径）。
/// 2) Windows 走原生剪贴板 channel `copyImageFile`，并提供右键菜单。
/// 3) 移动端走 Share.shareXFiles，并提供长按手势。
/// 4) 复用 TODO-023 已有 i18n key，不引入 Clipboard.setData 之类的伪复制。
void main() {
  final String source = File(
    'lib/src/pages/implementations/illustrations_viewer_page.dart',
  ).readAsStringSync();

  test('illustration gallery keeps the source File for copy/share', () {
    // 数据结构：插画保留字节 + 源文件，而非只剩 Uint8List。
    expect(source, contains('class _Illustration'));
    expect(source, contains('final File file;'));
    expect(source, contains('_Illustration(bytes: bytes, file: file)'));
    expect(source, contains('File _currentFile()'));
  });

  test('illustration gallery exposes desktop copy + mobile share handlers', () {
    expect(source, contains('Future<void> _copyCurrentImageToClipboard()'));
    expect(source, contains('Future<void> _shareCurrentImage()'));
    expect(source, contains('Future<void> _showImageContextMenu('));

    // Windows 原生剪贴板 channel（复用 TODO-023 能力）。
    expect(source, contains('HibikiChannels.clipboardImage'));
    expect(source, contains("'copyImageFile'"));
    // 移动端系统分享面板。
    expect(source, contains('Share.shareXFiles'));
    expect(source, contains('XFile(file.path'));

    // 不允许退化成纯文本伪复制。
    expect(source, isNot(contains('Clipboard.setData')));
  });

  test('illustration gallery wires right-click (win) and long-press (mobile)',
      () {
    expect(source, contains('isWindowsPlatform'));
    expect(source, contains('onSecondaryTapDown'));
    expect(source, contains('onLongPress'));
    // 顶栏也提供可发现入口（复制 / 分享按钮）。
    expect(source, contains('Icons.copy_outlined'));
    expect(source, contains('Icons.share_outlined'));
  });
  test('illustration gallery wires keyboard ESC + arrow paging (BUG-404)', () {
    // 查看器自己持有键盘处理，不依赖整页 PageRoute 下不稳定的全局
    // `_handleGlobalEscape`：ESC 走 Navigator.maybePop（本页永远可退），
    // 左右方向键复用现成 `_pageBy`（已 clamp + 同步 PageView/计数）。
    expect(source, contains('CallbackShortcuts'));
    expect(source, contains('LogicalKeyboardKey.escape'));
    expect(source, contains('LogicalKeyboardKey.arrowLeft'));
    expect(source, contains('LogicalKeyboardKey.arrowRight'));
    expect(source, contains('Navigator.maybePop(context)'));
    expect(source, contains('_pageBy(-1)'));
    expect(source, contains('_pageBy(1)'));
  });
}
