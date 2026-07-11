import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫（按用户「照抄 Niratan 词典方框排列」决策）：查词弹窗里多本词典的方框
/// (`.glossary-group`) 按 Niratan Features/Popup/popup.js 的 masonry「最短列打包」排列
/// ——每张卡片放进当前最矮的那一列，紧密堆叠不留空隙（对照 develop 原本的 CSS grid 行对齐：
/// 同行卡片被最高者顶到同一水平线、矮卡片下方留空白）。
///
/// 实现取舍（见 popup.js 注释）：CSS grid 规则原样保留作「无 JS 兜底」，masonry 是叠在
/// grid 之上的运行时 inline-style 覆盖层——`--dict-columns > 1` 且多卡时接管绝对定位，
/// `<=1` 或单卡时清 inline 回落 grid/block。因此这里锁 popup.js 的 masonry 不变量，而
/// popup.css 的 grid 守卫（popup_dict_card_guard / popup_dictionary_columns）不受影响。
///
/// 纯源码不变量（CI 只跑 .dart，node 守卫 CI 不跑），故在 Dart 层断言以进 CI 真跑；
/// 真实排列观感另由桌面离屏真机复测（reader/popup 布局问题的验证纪律）。
void main() {
  late String js;

  setUpAll(() {
    js = File('assets/popup/popup.js').readAsStringSync();
  });

  test('存在 masonry 布局函数，且列数从 --dict-columns 读取（一般化 Niratan 的写死 2 列）', () {
    expect(js.contains('function layoutMasonry('), isTrue,
        reason: 'masonry 主函数 layoutMasonry 必须存在');
    expect(js.contains('function dictColumns('), isTrue,
        reason: '列数来源 dictColumns() 必须存在');
    expect(
        RegExp(r"getPropertyValue\(\s*'--dict-columns'\s*\)").hasMatch(js) ||
            RegExp(r'getPropertyValue\(\s*"--dict-columns"\s*\)').hasMatch(js),
        isTrue,
        reason: '列数必须从宿主注入的 --dict-columns 读取，保留已发布的列数设置');
  });

  test('核心是「最短列打包」：每张卡片放进当前最矮列（无空隙紧密堆）', () {
    // 选列逻辑：遍历列高数组，取更矮的一列。锁住这条 heights[i] < heights[c] 的最短列判据，
    // 防止退回按顺序填列（那会重现行对齐的空隙）。
    expect(RegExp(r'heights\[i\]\s*<\s*heights\[c\]').hasMatch(js), isTrue,
        reason: '必须按「当前最矮列」选列，才是 masonry 紧密堆，而非顺序/行对齐');
    expect(js.contains('offsetHeight'), isTrue,
        reason: '按卡片实测高度累加列高，才能把下一张压到最矮列底部');
  });

  test('masonry 用绝对定位 + translate 摆放，容器撑到最高列高度', () {
    expect(RegExp(r"position\s*=\s*'absolute'").hasMatch(js), isTrue,
        reason: '卡片绝对定位脱离行对齐流');
    expect(RegExp(r'transform\s*=\s*`translate\(').hasMatch(js), isTrue,
        reason: '用 transform: translate(x, y) 摆到目标列/行位置');
    expect(RegExp(r'Math\.max\(\.\.\.heights\)').hasMatch(js), isTrue,
        reason: '容器高度取最高列，避免绝对定位后容器塌陷');
  });

  test('粘着列分配：开关方框只上下动，列固定不左右跳 (用户反馈)', () {
    // 列号记录在卡片 dataset.masonryCol、列数记录在容器 dataset.masonryCols。
    expect(js.contains('dataset.masonryCol'), isTrue,
        reason: '每张卡片必须记录粘着列号 dataset.masonryCol');
    expect(js.contains('dataset.masonryCols'), isTrue,
        reason: '容器必须记录当时列数 dataset.masonryCols 以判断能否复用');
    // 复用条件：列数没变(prevCols === cols) 且每张卡片都有合法列号 → 复用既有列，只重算纵向。
    expect(RegExp(r'prevCols\s*===\s*cols').hasMatch(js), isTrue,
        reason: '只有列数不变才复用粘着列（列数变才允许重排）');
    expect(RegExp(r'canReuse').hasMatch(js), isTrue,
        reason: 'canReuse 分支：复用列号时不得再跑最短列重新分列');
    // 回落时清记录，回到 masonry 会重新打包。
    expect(js.contains('delete item.dataset.masonryCol'), isTrue,
        reason: 'resetMasonryBody 必须清粘着列记录，避免陈旧列号跨单列/多列切换复用');
  });

  test('单列 / 单卡回落 CSS 兜底：cols<=1 或 items<=1 时清 inline', () {
    expect(
        RegExp(r'cols\s*<=\s*1\s*\|\|\s*items\.length\s*<=\s*1').hasMatch(js),
        isTrue,
        reason: '单列或单卡不做 masonry，清 inline 回落 CSS grid/block（不破坏单卡满宽 / 单列纵堆）');
    expect(js.contains('function resetMasonryBody('), isTrue,
        reason: '回落时必须清掉 position/width/transform/height 等 inline，让 CSS 接管');
  });

  test('高度变化用 ResizeObserver 兜底（<details> 折叠 / 图片异步 / ruby / 字体）', () {
    expect(js.contains('new ResizeObserver('), isTrue,
        reason: '卡片高度变化必须由 ResizeObserver 捕捉重排，不能只靠一次性布局');
    // 只观察卡片、不观察容器：容器随 masonry 改 height 会自触发死循环。
    expect(RegExp(r'function observeMasonryTargets\(').hasMatch(js), isTrue,
        reason: '观察目标集中在 observeMasonryTargets，只挂卡片避免容器 height 自触发死循环');
  });

  test('只对词典容器排版，不误抓 frequency / pitch 的 category-body', () {
    expect(js.contains('.glossary-section > .category-body'), isTrue,
        reason: 'masonry 容器必须限定 .glossary-section > .category-body，'
            'frequency-section / pitch-section 也用 .category-body、不能被 masonry 抓走');
  });

  test('渲染 + 增量都触发重排，且宿主可外部触发（改列数时）', () {
    expect(js.contains('window.hoshiRelayoutDictionaries'), isTrue,
        reason: '暴露 hoshiRelayoutDictionaries 供宿主改列数后重排 / 外部触发');
    // _firePopupRendered 是首条 + 其余条两次都会调的收尾钩子。
    final int fireAt = js.indexOf('function _firePopupRendered(');
    expect(fireAt, isNonNegative);
    final int fireEnd = js.indexOf('\n}', fireAt);
    expect(fireEnd, greaterThan(fireAt));
    expect(js.substring(fireAt, fireEnd).contains('hoshiRelayoutDictionaries'),
        isTrue,
        reason: '渲染收尾 _firePopupRendered 必须重排 masonry（覆盖首条 + 其余条）');
  });
}
