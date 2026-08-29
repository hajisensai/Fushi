import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户报的三件事：
///   ①「导入游戏 exe 时拖动功能没反应」
///   ②「选文件导入后要不再给个成功提示或者给跳转到游戏库页面，导成功没反应我还
///     以为失败了重试了好几次」
///   ③「自定义图标添加的做一个截取图片的步骤」
///
/// 这三处都是 UI 接线，行为落在 widget 树与文件对话框之外（drop 事件来自
/// desktop_drop 的进程级广播、file picker 是平台通道），widget harness 里探不到；
/// 这里用源码扫描守卫钉住接线本身。每条守卫都做过变异实测。
///
/// 注意：所有「顺序 / 不存在」类断言都必须先剥注释——注释里出现同一个标识符会先被
/// indexOf 命中，把守卫变成恒真或恒假。
String stripComments(String source) {
  final StringBuffer out = StringBuffer();
  for (final String line in source.split('\n')) {
    final String trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
    final int inline = line.indexOf('//');
    // 只剥「不在字符串里」的行尾注释：本仓源码里带 // 的字符串常量都是 URL，
    // 一律含 :// ，据此排除。
    if (inline >= 0 && !line.contains('://')) {
      out.writeln(line.substring(0, inline));
      continue;
    }
    out.writeln(line);
  }
  return out.toString();
}

/// 精确截取一个函数体：参数表按括号配平跳过，函数体按花括号配平闭合。
///
/// **不要**改回「从签名往后取固定长度窗口」：`addGameViaFilePicker` 紧挨着
/// `addGamesFromPaths`，固定窗口会溢出到下一个函数里——两者都有 success toast，
/// 于是「本函数有没有 toast」这条断言恒真。变异实测抓到过这一次空转。
///
/// 前提：传进来的 source 已经剥过注释（注释里的花括号会把配平算歪）。
String methodBody(String source, String signature) {
  final int at = source.indexOf(signature);
  expect(at, isNonNegative, reason: '找不到 $signature');
  // signature 自带一个未闭合的 '('，从它之后开始配平参数表。
  int i = at + signature.length;
  int paren = 1;
  while (i < source.length && paren > 0) {
    if (source[i] == '(') paren++;
    if (source[i] == ')') paren--;
    i++;
  }
  final int braceAt = source.indexOf('{', i);
  expect(braceAt, isNonNegative, reason: '$signature 后面找不到函数体');
  int depth = 0;
  for (int j = braceAt; j < source.length; j++) {
    if (source[j] == '{') depth++;
    if (source[j] == '}') {
      depth--;
      if (depth == 0) return source.substring(at, j + 1);
    }
  }
  fail('找不到 $signature 的函数体结尾');
}

void main() {
  group('① 游戏「导入」页要自己接 drop', () {
    late String source;

    setUpAll(() {
      source = stripComments(
        File('lib/src/pages/implementations/home_game_page.dart')
            .readAsStringSync(),
      );
    });

    test('导入视图挂了 FushiFileDropTarget', () {
      final String body = methodBody(source, 'Widget _buildImport(');
      expect(body, contains('FushiFileDropTarget('),
          reason: '此前整个游戏域只有**库**页挂了 drop target，而 DropSurfaceScope '
              '按当前 section 过滤 —— 站在「导入」页拖 exe 进来完全没反应。');
      expect(body, contains("debugLabel: 'game-import'"));
    });

    test('drop 走共享动作而不是自己再拼一套落库逻辑', () {
      final String body = methodBody(source, 'Widget _buildImport(');
      expect(body, contains('addGamesFromPaths('));
    });

    test('drop target 必须包在 _buildImport 的最外层（内层会被布局裁掉命中区）', () {
      final String body = methodBody(source, 'Widget _buildImport(');
      final int dropAt = body.indexOf('FushiFileDropTarget(');
      final int layoutAt = body.indexOf('DesktopContentLayout(');
      expect(dropAt, isNonNegative);
      expect(layoutAt, isNonNegative);
      expect(dropAt, lessThan(layoutAt),
          reason: 'desktop_drop 按 RenderBox.paintBounds 过滤，drop target 只覆盖'
              '它自己的子树 —— 包在内层等于只有那一小块能接。');
    });
  });

  group('② 导入成功要有反馈', () {
    late String flow;

    setUpAll(() {
      flow = stripComments(
        File('lib/src/mining/galgame_add_flow.dart').readAsStringSync(),
      );
    });

    test('文件选择器导入成功后出 success toast', () {
      final String body =
          methodBody(flow, 'Future<void> addGameViaFilePicker(');
      final int addAt = body.indexOf('repo.addAll(');
      final int toastAt = body.indexOf('ToastSeverity.success');
      expect(addAt, isNonNegative);
      expect(toastAt, isNonNegative,
          reason: '成功路径此前 0 反馈：只有「已在库中」才出 toast，导成功与导失败'
              '在观感上完全一样。');
      expect(toastAt, greaterThan(addAt), reason: '落库之后才算成功。');
    });

    test('导入成功后回调调用方（「导入」页据此跳到游戏库）', () {
      final String body =
          methodBody(flow, 'Future<void> addGameViaFilePicker(');
      expect(body, contains('onImported?.call()'));
    });

    test('「导入」页把跳转接上了游戏库', () {
      final String page = stripComments(
        File('lib/src/pages/implementations/home_game_page.dart')
            .readAsStringSync(),
      );
      expect(page, contains('onImported: _showLibrary'),
          reason: '新游戏落在**另一个** section 里，停在导入页的话屏幕上什么都不变。');
    });

    test('批量拖放路径同样出 toast 并回调', () {
      final String body = methodBody(flow, 'Future<void> addGamesFromPaths(');
      expect(body, contains('ToastSeverity.success'));
      expect(body, contains('onImported?.call()'));
      expect(body, contains('filterOutDuplicateGameExes('),
          reason: '拖进来的可能是已在库的 exe / 压根不是 exe。');
    });

    test('游戏库页的拖放收敛到同一条共享路径（两处各写一份必然走岔）', () {
      final String library = stripComments(
        File('lib/src/pages/implementations/games_library_page.dart')
            .readAsStringSync(),
      );
      final String body =
          methodBody(library, 'Future<void> _handleDrop(List<String> paths');
      expect(body, contains('addGamesFromPaths('));
      expect(body.contains('newGalgameEntryFromExe('), isFalse,
          reason: '落库细节应当只有共享动作里一份；这里再拼一遍，只要有一处忘了 '
              'toast 或忘了补封面，两个入口的行为就会不一样。');
    });
  });

  group('③ 自定义图标要有裁剪步骤', () {
    late String source;

    setUpAll(() {
      source = stripComments(
        File('lib/src/pages/implementations/miscellaneous_settings_page.dart')
            .readAsStringSync(),
      );
    });

    test('选图之后、落盘之前插入裁剪对话框，并锁定 1:1', () {
      final String body = methodBody(source, 'Future<void> _pickCustomIcon(');
      final int pickAt = body.indexOf('FilePicker.platform.pickFiles(');
      final int cropAt = body.indexOf('showCropImageDialog(');
      final int persistAt = body.indexOf('persistCustomIconFile(');
      expect(pickAt, isNonNegative);
      expect(cropAt, isNonNegative, reason: '用户要求「做一个截取图片的步骤」。');
      expect(persistAt, isNonNegative);
      expect(cropAt, greaterThan(pickAt));
      expect(persistAt, greaterThan(cropAt), reason: '落盘的必须是裁剪结果。');
      expect(body.substring(cropAt, cropAt + 160), contains('aspectRatio: 1'),
          reason: '图标最终按正方形渲染，自由裁出来的长条会被拉伸变形。');
    });

    test('落盘与读字节都用裁剪结果，不再碰原图路径', () {
      final String body = methodBody(source, 'Future<void> _pickCustomIcon(');
      expect(body.contains('persistCustomIconFile(pickedPath)'), isFalse,
          reason: '用原图落盘 = 裁剪白做，而且是**静默**的：UI 上裁完了，图标还是原样。');
      expect(body.contains('File(pickedPath).readAsBytes()'), isFalse,
          reason: 'Android 分支同理。');
    });

    test('取消裁剪 = 取消整个流程（不落一个没裁的图标）', () {
      final String body = methodBody(source, 'Future<void> _pickCustomIcon(');
      final int cropAt = body.indexOf('showCropImageDialog(');
      expect(body.substring(cropAt, cropAt + 260), contains('== null) return'));
    });

    test('裁剪对话框支持锁定宽高比，且真的传给了 CropController', () {
      final String crop = stripComments(
        File('lib/src/pages/implementations/crop_image_dialog_page.dart')
            .readAsStringSync(),
      );
      expect(crop, contains('final double? aspectRatio;'));
      expect(crop, contains('CropController(aspectRatio: widget.aspectRatio)'),
          reason: '只加字段不接到 controller 上，锁比例就是个摆设。');
      expect(crop, contains('Future<File?> showCropImageDialog('),
          reason: '回调式 API 让每个调用点自己接住结果，取消分支很容易漏。');
    });
  });
}
