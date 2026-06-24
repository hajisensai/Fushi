import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-792 竖排「文字向下偏移越翻越大」根因修复守卫（确定性 pitch += bottomOverlap）。
///
/// 根因（真机 [792-TURN]/[753-DIAG]/[792-RPITCH] 取证）：TODO-734 为防漏字把竖排 column-width
/// 基准从 `--page-height`(V+O) 改成纯 V（reader_content_styles.dart verticalColumnWidthCss·793），
/// 但多列容器 body 仍是 `height:var(--page-height)`(V+O)。column-fill 下单列拉伸填满容器内容盒
/// (V+O)−padding，故浏览器真实渲染列周期 realPitch = ((V+O)−padding)+gap = 名义 pageStep + O
/// （O=bottomOverlap）。真机 [792-RPITCH] raw 坐标实测列顶 68→905、周期 837 = 815+22 坐实。
/// paginate 用 N×pageStep 绝对网格、pageStep < realPitch → 第 N 页文字下移 N×O 线性累积。
///
/// 修复（量纲分离·确定性）：列宽 CSS 不动（防漏字不回退），getScrollContext 竖排把翻页步进
/// pageStep 加回 O（= this.pageHeight − this.viewportHeight，init/updatePageSize 成对赋值），
/// 对齐浏览器真实列周期。横排不碰。O 未初始化为 0/NaN 时 isFinite/正数守卫回退名义 pageStep。
///
/// （早期版本曾用 getClientRects 实测列周期，但竖排 ruby 振假名碎块把 left-跳变检测骗出噪声值
/// 585，故改用确定性 O 算法——realPitch=pageStep+O 对 multicol column-fill 普适，不靠脆弱实测。）
void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
  });

  test('getScrollContext 竖排 pageStep 加回 bottomOverlap O（对齐真实列周期）', () {
    // 仅竖排进入加 O 分支。
    expect(source.contains('if (vertical) {'), isTrue,
        reason: '必须有仅竖排分支（横排不碰）');
    // O = pageHeight − viewportHeight（V+O 减纯 V）。
    expect(
        source
            .contains('var overlapO = this.pageHeight - this.viewportHeight;'),
        isTrue,
        reason: 'O 必须取运行时 pageHeight−viewportHeight（=bottomOverlap）');
    // 守卫：仅当 O 有限且为正才加（未初始化 0/NaN → 回退名义 pageStep）。
    expect(
        source.contains(
            'if (isFinite(overlapO) && overlapO > 0) pageStep += overlapO;'),
        isTrue,
        reason: 'isFinite + 正数守卫，未初始化时回退名义 pageStep（绝不变更）');
  });

  test('加 O 发生在名义 pageStep 之后、maxScroll 之前（同源）', () {
    final int nominalIdx = source.indexOf('var pageStep = contentBox + gap;');
    final int addOIdx =
        source.indexOf('var overlapO = this.pageHeight - this.viewportHeight;');
    final int maxScrollIdx =
        source.indexOf('var maxScroll = Math.max(0, totalSize - pageStep);');
    expect(nominalIdx, greaterThan(0));
    expect(addOIdx, greaterThan(nominalIdx), reason: '加 O 必须在名义 pageStep 计算之后');
    expect(maxScrollIdx, greaterThan(addOIdx),
        reason: 'maxScroll 必须用加 O 后的 pageStep（pitch 与对齐量同源，防末页错位）');
  });

  test('横排 pageStep 不加 O（只动竖排）', () {
    // 加 O 只在 `if (vertical)` 内；横排分支（columnWidth/clientWidth）不得出现 overlapO。
    final int addOIdx = source.indexOf('var overlapO =');
    final int ctxStart = source.indexOf('getScrollContext: function() {');
    final int ctxEnd = source.indexOf('getPagePosition: function', ctxStart);
    expect(addOIdx, greaterThan(ctxStart));
    expect(addOIdx, lessThan(ctxEnd),
        reason: 'overlapO 必须在 getScrollContext 内、仅竖排分支');
    // overlapO 在 source 中只出现在这一处（声明1 + isFinite/>0/+= 三处使用 = 4），不污染横排。
    expect('overlapO'.allMatches(source).length, 4,
        reason: 'overlapO 仅 getScrollContext 竖排分支用（声明1 + if 内 3 次），不外泄横排');
  });

  test('实测列周期机制已移除（不再依赖 _measureColumnPitch/_realColumnPitch）', () {
    expect(source.contains('_measureColumnPitch'), isFalse,
        reason: '脆弱的 getClientRects 实测已被确定性 O 算法取代，须删净');
    expect(source.contains('_realColumnPitch'), isFalse,
        reason: '实测缓存字段须删净（确定性算法不缓存）');
  });
}
