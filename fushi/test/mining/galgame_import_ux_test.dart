import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
void main() {
  group('① 游戏「导入」页要自己接 drop', () {
    late String source;

    setUpAll(() {
      source = maskComments(
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

    test('onDrop 必须把 future 交回去，不得 unawaited —— 那是唯一的错误咽喉', () {
      final String body = methodBody(source, 'Widget _buildImport(');
      final int dropAt = body.indexOf('onDrop:');
      expect(dropAt, isNonNegative);
      // `FushiFileDropTarget.runDrop` 特意 await 这个回调：各页的路由函数挂在
      // desktop_drop 的 void 回调上，抛出时异常直接漂进 zone，用户看到的只有
      // 「拖了没反应」。包成 unawaited(...) 等于让回调立刻返回 void，await 什么
      // 也接不到 —— 而「拖了没反应」正是本页要修的那个症状。
      final int bodyEnd = body.indexOf('child:', dropAt);
      expect(bodyEnd, greaterThan(dropAt));
      expect(
        body.substring(dropAt, bodyEnd),
        isNot(contains('unawaited(')),
        reason: 'onDrop 的 future 必须交回 runDrop，否则落库失败会被静默吞掉',
      );
    });

    test('_showSection 自带 mounted 门（两个新调用点都在 await 之后）', () {
      final String body = methodBody(source, 'void _showSection(GameSection section)');
      // drop 落库后、文件选择器返回后才回调，用户完全可以在文件对话框开着的时候
      // 切走 tab / 关窗口。那时 dispose() 已把 notifier 复位成 dashboard，这里
      // 再写一次就是把一次过期的导航请求泄漏给下一次挂载。
      // 门必须在 _showSection 里，不能逐调用点补 —— 下一个新调用点还会漏。
      expect(body, contains('if (!mounted) return;'),
          reason: 'dispose() 复位 notifier 之后不得再被 await 回来的回调写脏');
      final int gateAt = body.indexOf('if (!mounted) return;');
      final int writeAt = body.indexOf('gameSectionNotifier.value = section;');
      expect(writeAt, isNonNegative);
      expect(gateAt, lessThan(writeAt),
          reason: 'mounted 门必须排在写 notifier 之前才有意义');
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
      flow = maskComments(
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
      final String page = maskComments(
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
      final String library = maskComments(
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
      source = maskComments(
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
      final String crop = maskComments(
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
