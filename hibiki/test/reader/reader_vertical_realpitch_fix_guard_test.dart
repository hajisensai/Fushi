import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-792 竖排「文字向下偏移越翻越大」根因修复守卫（源码结构 + 量纲安全）。
///
/// 根因（真机 [792-TURN]/[753-DIAG] 取证）：TODO-734 为防漏字把竖排 column-width 基准从
/// `--page-height`(V+O) 改成纯 V，但多列容器 body 仍是 `--page-height`(V+O)，单列拉伸填满容器 →
/// 浏览器真实渲染列周期 realPitch 比名义 pageStep(=contentBox+gap·纯 V) 大 → paginate 的
/// N×pageStep 绝对网格落在 realPitch 之前 → 第 N 页文字下移 N×(realPitch−pageStep) 线性累积。
///
/// 修复（自校正·量纲分离）：列宽 CSS 不动（防漏字不回退），getScrollContext 竖排把 pageStep
/// 对齐到 `_measureColumnPitch` 实测的真实列周期；仅当实测值合理（≥名义且差量 ≤2×gap）才采用，
/// 测不到/越界一律回退名义 pageStep（绝不变更、绝不反向 over-correct）。init/resize/字体重锚后
/// 在 layout settle 点重测并缓存到 `_realColumnPitch`。
///
/// headless 测不出（真实列拉伸只在真机 multicol 渲染下出现），故这里守源码结构 + 量纲安全闸：
/// 撤掉任一保护点（边界 clamp / 仅竖排 / 回退 null / 连续 shell typeof 守卫）→ 转红。
void main() {
  late String source;

  setUpAll(() {
    source = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();
  });

  test('getScrollContext 竖排用实测 _realColumnPitch 当 pageStep（带量纲安全边界）', () {
    // 仅竖排 + 实测值非空才进入覆盖分支。
    expect(source.contains('if (vertical && this._realColumnPitch != null) {'),
        isTrue,
        reason: '仅竖排且实测值非空才用 realPitch 覆盖 pageStep');
    // 边界闸：realPitch 必须 ≥ 名义 pageStep 且差量 ≤ 2×gap（防 garbage / 防列宽收缩反向）。
    expect(
        source.contains(
            'if (rp >= pageStep - 1 && rp <= pageStep + gap * 2 + 2) {'),
        isTrue,
        reason: '必须有「≥名义 且 差量≤2×gap」双向边界，越界回退名义 pageStep（绝不反向 over-correct）');
    // 覆盖必须发生在名义 pageStep 计算之后（先 contentBox+gap，再条件覆盖）。
    final int nominalIdx = source.indexOf('var pageStep = contentBox + gap;');
    final int overrideIdx =
        source.indexOf('if (vertical && this._realColumnPitch != null) {');
    expect(nominalIdx, greaterThan(0));
    expect(overrideIdx, greaterThan(nominalIdx),
        reason: '实测覆盖必须在名义 pageStep 之后（覆盖是可选优化，回退即名义值）');
  });

  test('_realColumnPitch 初始声明为 null（未测=回退名义 pageStep）', () {
    expect(source.contains('_realColumnPitch: null,'), isTrue,
        reason: '对象字面量须先声明 _realColumnPitch: null，首帧未测时 getScrollContext 回退');
  });

  test('_measureColumnPitch 在分页 shell 定义一次（getClientRects 按 left 跳变检测列周期）', () {
    expect(
      'window.hoshiReader._measureColumnPitch = function('
          .allMatches(source)
          .length,
      1,
      reason: '_measureColumnPitch 只能在分页 shell 定义一次（连续 shell 无之）',
    );
    // 实测核心：竖排门控 + getClientRects + left 跳变列边界 + 取相邻列顶 top 差。
    final int s =
        source.indexOf('window.hoshiReader._measureColumnPitch = function(');
    final int e = source.indexOf('window.hoshiReader._diag753 = function', s);
    expect(e, greaterThan(s), reason: '_measureColumnPitch 须在 _diag753 之前');
    final String fn = source.substring(s, e);
    expect(fn.contains('if (!this.isVertical()) return null;'), isTrue,
        reason: '横排/非竖排直接返回 null（不参与，回退名义）');
    expect(fn.contains('rng.getClientRects()'), isTrue,
        reason: '须用 getClientRects 实测真实渲染列 rect');
    expect(fn.contains('L > prevLeft + 40'), isTrue,
        reason: '竖排-rl 列边界=left 跳回右侧（大幅增大）');
    expect(fn.contains('return null;'), isTrue,
        reason: '测不到/列数不足/异常须返回 null（调用方回退名义 pageStep）');
    expect(fn.contains('} catch (e) {') && fn.contains('return null;'), isTrue,
        reason: '须 try/catch 兜底返回 null（绝不让测量异常破坏 getScrollContext）');
  });

  test('init / updatePageSize / 字体重锚 settle 后重测并缓存 realPitch', () {
    // init：首帧恢复完成后实测。
    expect(
        source.contains(
            'window.hoshiReader._realColumnPitch = window.hoshiReader._measureColumnPitch();'),
        isTrue,
        reason: 'init 末尾 layout settle 后须实测缓存 realPitch');
    // updatePageSize：失效 + 在 reanchor rAF 重测。
    expect(source.contains('this._realColumnPitch = null;'), isTrue,
        reason: 'updatePageSize/beginStyleReanchor 须先失效旧 realPitch');
    expect(
        source.contains('self._realColumnPitch = self._measureColumnPitch();'),
        isTrue,
        reason: 'updatePageSize reanchor rAF 须 settle 后重测');
  });

  test('连续 shell 共享 commitStyleReanchor 用 typeof 守卫（无 _measureColumnPitch 不崩）',
      () {
    // begin/commitStyleReanchor 是 _sharedJs 两 shell 共享：连续 shell 无 _measureColumnPitch，
    // 必须 typeof 守卫，否则连续模式字体重锚抛错。
    expect(
        source
            .contains("if (typeof this._measureColumnPitch === 'function') {"),
        isTrue,
        reason:
            '共享 commitStyleReanchor 调 _measureColumnPitch 前须 typeof 守卫（连续 shell 安全）');
  });
}
