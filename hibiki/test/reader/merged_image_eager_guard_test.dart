import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1339 回归守卫（源码扫描，CI 可跑）：图片合并（前导单图片 run 折进后随文本章，
/// TODO-1128/1174）注入的插图（`<div class="hoshi-merged-image"><img ...></div>`，
/// webview.part.dart `_injectMergedChapterImages`）必须在 `_sharedInitImages` 里保持
/// **eager**，不得被无条件挂 `loading="lazy"`。
///
/// 根因（本 bug）：`_sharedInitImages` 曾给所有非 gaiji 图无条件挂 lazy。合并注入的
/// 前导插图里，离首个文本落点较远的**第一张**离屏、永不进入懒加载视口 margin → 永不
/// load → 保持 0 尺寸 → 被 `buildPaginationMetrics` 的 `firstContentEdge` 排除（0 尺寸
/// 媒体被跳过）→ 章首落点（restoreProgress/restoreToCharOffset <=0 走 minScroll）锚到
/// 最近的已加载图（**最后一张**），跳过第一张 =「两张连续图只有最后一张合并进章节」。
///
/// 行为断言在 `integration_test/merged_image_eager_load_test.dart`（live WebView）；
/// 本守卫锁住修复接线不被静默回退。
void main() {
  final File paginationFile = File(
    'lib/src/reader/reader_pagination_scripts.dart',
  );

  group('TODO-1339 merge-injected leading illustrations stay eager', () {
    test('_sharedInitImages exempts .hoshi-merged-image from loading=lazy', () {
      final String src = paginationFile.readAsStringSync();
      expect(src.contains('_sharedInitImages'), isTrue,
          reason: '共享图片初始化 helper 必须存在');

      // 定位设置 loading="lazy" 的那一句，并向上取其所在的 img.forEach 块。
      final int lazyIdx = src.indexOf("setAttribute('loading', 'lazy')");
      expect(lazyIdx, greaterThan(0),
          reason: '_sharedInitImages 仍应存在懒加载分支（普通图仍 lazy）');

      // 取 lazy 语句前一段（同一 forEach 内的守卫），必须同时排除 gaiji 与合并前导图。
      final int windowStart = (lazyIdx - 600).clamp(0, src.length);
      final String guardWindow = src.substring(windowStart, lazyIdx);
      expect(guardWindow.contains('hoshi-merged-image'), isTrue,
          reason:
              '设置 loading=lazy 前必须判定并放行 .hoshi-merged-image 合并前导插图（保持 eager）');
      // 放行必须体现在 lazy 的门控条件上（存在一个基于 merged-lead 的否定判定）。
      expect(
        guardWindow.contains('isMergedLeadImg') ||
            guardWindow.contains("closest('.hoshi-merged-image')"),
        isTrue,
        reason:
            'lazy 门控必须引用合并前导图判定（isMergedLeadImg / closest(.hoshi-merged-image)）',
      );
    });

    test('the injection still marks merged images with .hoshi-merged-image',
        () {
      // 守卫两端接线一致：注入端类名与初始化端放行判定用同一个 marker。
      final File webviewFile = File(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      );
      final String src = webviewFile.readAsStringSync();
      expect(src.contains('class="hoshi-merged-image"'), isTrue,
          reason: '_injectMergedChapterImages 必须用 hoshi-merged-image 包裹每张前导插图');
    });
  });
}
