import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-792 竖排「文字整体往下 / 逐列斜置 + 翻页累积漂移」根因修复守卫（容器高度对齐纯 V）。
///
/// 渲染模型（真机截图 + [792-RPITCH] raw 坐标）：vertical-rl + multicol 下，列沿物理水平轴
/// 右→左堆成一「行列」，内容超一屏宽则沿 inline（竖直）轴溢出成下一行列往下堆，scrollTop 翻页
/// 推进行列。根因：多列容器 body `height:var(--page-height)`(=V+O) 比列宽基准
/// (verticalColumnWidthCss = 纯 V−margins−F−chrome ≈ 793) 大一个 bottomOverlap O →
/// 浏览器把单列 used 高从 793 拉伸到 ((V+O)−padding)≈815、相邻列顶差 = realPitch 837 > 名义
/// pageStep 815 → ① 页间 N×pageStep 网格累积漂移；② 页内 column-fill 在溢出列上逐列下移 = 整体
/// 往下 / 斜的平行四边形。
///
/// 根因修复（一处治两症·量纲对齐）：多列容器 body 高度改用纯 V（--reader-viewport-height），
/// 与 column-width 基准同量纲 → 列不再被拉伸、used 高回 793、realPitch 回 815 == 名义 pageStep。
/// 故 getScrollContext **不再** pageStep+=O 补偿（容器对齐后 contentBox+gap 已等于真实列周期，
/// 加 O 反过冲）。列宽 CSS 不动（防漏字不回退）；html 仍 V+O（滚动/图片虚高）；图片用独立
/// --hoshi-image-max-height 跟 body content-box 走，容器改纯 V 不切图。
///
/// headless 测不出真实 multicol 渲染，故守源码结构：撤掉容器高度对齐 / 复活 pageStep+=O → 转红。
void main() {
  late String css;
  late String js;

  setUpAll(() {
    css = File(
      'lib/src/reader/reader_content_styles.dart',
    ).readAsStringSync();
    js = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
  });

  test('多列容器 body 高度用纯 V（--reader-viewport-height），不用 V+O 的 --page-height', () {
    // 分页 body 块里必须显式把 body 高度对齐到纯视口高 V（覆盖 html,body 的 --page-height），
    // 否则容器 inline 高 (V+O)−padding 比列宽基准大 O → 列拉伸 → 累积 + 斜置复活。
    expect(
      css.contains('height: var(--reader-viewport-height, 100vh) !important;'),
      isTrue,
      reason: 'body(multicol 容器)高度必须用纯 V(--reader-viewport-height)，'
          '与 column-width 基准同量纲，列才不被 V+O 容器拉伸（治累积 + 斜置）',
    );
  });

  test('getScrollContext 竖排不再 pageStep+=O 补偿（容器对齐后名义 pageStep 已等于真实列周期）', () {
    expect(js.contains('pageStep += overlapO'), isFalse,
        reason: '容器高度对齐纯 V 后 realPitch 回 815 == 名义 pageStep，'
            '不得再加 O（会过冲反向漂移）');
    expect(js.contains('var overlapO = this.pageHeight - this.viewportHeight;'),
        isFalse,
        reason: 'overlapO 补偿逻辑必须已删（根因下沉到 CSS 容器高度）');
    // pageStep 仍是名义 contentBox + gap（不动）。
    expect(js.contains('var pageStep = contentBox + gap;'), isTrue,
        reason: '名义 pageStep = contentBox + gap 保持不变');
  });

  test('列宽 CSS 仍用纯 V 基准（TODO-734 防漏字不回退）', () {
    expect(
      css.contains(
          'max(\${fontSizePx}px, calc(var(--reader-viewport-height, 100vh)'),
      isTrue,
      reason: 'verticalColumnWidthCss 仍以纯 V 为基准，防漏字修复不回退',
    );
  });

  test('图片高度用独立 --hoshi-image-max-height（与 body 容器高度解耦，改容器不切图）', () {
    expect(css.contains('var(--hoshi-image-max-height'), isTrue,
        reason: '图片 max-height 走独立变量，跟 body content-box，容器改纯 V 不切图');
  });
}
