import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-679 (TODO-1285) 源码守卫：分页多列(pageColumns>=2)时整页插图必须收进**子列**，
/// 不得按整 content-box 撑开越界盖住相邻列正文。根因是图片 max 约束过去恒用整
/// content-box（`cs.w`/`cs.h`）；修复引入共享 helper `fushiReader._imageMaxBox()`，turn 轴
/// 图片 max 改读浏览器 used 子列宽 `getComputedStyle(document.body).columnWidth`（与
/// getScrollContext 同一真值），并仅在真多列时夹取。真实渲染由本机 headless 守卫
/// `tool/reader_pitch_headless/image_multicol_fit_probe.mjs` 验（CI 跑不到真 WebView），
/// 这里锁 JS 布线不回退。
void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
  });

  test('_imageMaxBox helper exists (shared, single source of image max sizing)',
      () {
    expect(
      source.contains('_imageMaxBox: function()'),
      isTrue,
      reason: '图片 max 尺寸必须集中在共享 _imageMaxBox helper，避免多处漂移',
    );
  });

  test('_imageMaxBox derives the turn axis from used sub-column columnWidth',
      () {
    expect(
      source.contains('getComputedStyle(document.body).columnWidth'),
      isTrue,
      reason: 'turn 轴图片 max 必须读浏览器 used 子列宽（与 getScrollContext 同一真值），'
          '否则多列时插图按整 content-box 撑开越界',
    );
  });

  test(
      'sub-column clamp is gated on genuine multi-column (usedColW < turnFull - 1)',
      () {
    expect(
      source.contains('usedColW < turnFull - 1'),
      isTrue,
      reason: '仅当 used 子列明显窄于整 turn 轴（真 pageColumns>=2）才夹取；'
          '单列/连续/VN 必须回退整 content-box，保零回归',
    );
  });

  test('all image-max setProperty sites route through _imageMaxBox', () {
    // 每个 --hoshi-image-max-width / -height 赋值都必须取自 _imageMaxBox() 的返回
    // （__imgBox.w/.h 或 box.w/.h），不得留裸的整 content-box `cs.w * ratio` / `cs.h`。
    final RegExp widthSet =
        RegExp(r"setProperty\('--hoshi-image-max-width', ([^)]+)\)");
    final Iterable<RegExpMatch> widthMatches = widthSet.allMatches(source);
    expect(widthMatches.length, greaterThanOrEqualTo(4),
        reason: '分页/连续 initialize+updatePageSize 至少 4 处设置图片 max-width');
    for (final RegExpMatch m in widthMatches) {
      final String value = m.group(1)!;
      expect(
        value.contains('imgBox.w') || value.contains('box.w'),
        isTrue,
        reason: '图片 max-width 必须取自 _imageMaxBox()，实际=`$value`',
      );
    }

    final RegExp heightSet =
        RegExp(r"setProperty\('--hoshi-image-max-height', ([^)]+)\)");
    for (final RegExpMatch m in heightSet.allMatches(source)) {
      final String value = m.group(1)!;
      expect(
        value.contains('imgBox.h') || value.contains('box.h'),
        isTrue,
        reason: '图片 max-height 必须取自 _imageMaxBox()，实际=`$value`',
      );
    }
  });

  test(
      'legacy full-content-box image sizing is gone (no bare cs.w*ratio at var sites)',
      () {
    expect(
      source.contains(
          "setProperty('--hoshi-image-max-width', Math.max(1, Math.floor(cs.w"),
      isFalse,
      reason: '旧的整 content-box `cs.w * ratio` 直接喂图片 max-width 会在多列越界，必须移除',
    );
  });
}
