import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1798 守卫：查词浮层与视频控制条自动显隐之间的四条不变量。
///
/// 背景（真实代码路径）：视频页的查词浮层挂在**根 Overlay**（`_syncPopupOverlay`），其
/// dismiss barrier 是全屏 **opaque** 命中层。浮层一开，① `_pokeControlsVisible` 派发的
/// 合成 hover 再也到不了 media_kit 自己的 `MouseRegion`（续命哑火），却会落进 barrier 的
/// `_onDismissBarrierHover` 被当成真实鼠标消费，污染指针记账与换词去重键；② 控制条照常
/// 2s 自动淡出，而查词浮层此前不在 `_hasVideoOverlay` 里，Hibiki 侧 `_buildCursorOverlay`
/// 与 fork 侧 `hideMouseOnControlsRemoval` **两层独立的** `cursor: none` 同时生效，鼠标悬
/// 在弹窗上时 OS 光标消失。
///
/// 这些不变量全部落在私有 `State` 成员与 media_kit fork 的 theme 上，widget 测试要真起
/// 播放器 + 平台视图才能触达，故取**源码扫描**这一最强可落地层。
///
/// ⚠️ 本文件的每条断言都在 [maskComments] 之后执行。修复的注释里大量出现
/// `_lookupOverlayActive` / `_isSyntheticControlsHover` 字样，若直接对原始源码做子串匹配，
/// 删掉真实代码、只留注释也会绿 —— 那正是本仓反复踩过的假绿。
void main() {
  const String pageRelPath =
      'lib/src/pages/implementations/video_fushi_page.dart';
  const String visibilityRelPath =
      'lib/src/pages/implementations/video_fushi/controls_visibility.part.dart';
  const String themeRelPath =
      'lib/src/pages/implementations/video_fushi/controls_theme.part.dart';
  const String layoutRelPath =
      'lib/src/pages/implementations/video_fushi/layout.part.dart';

  /// 读源码并**剥掉注释/字符串**，返回只含真实代码的等长掩码串。
  String code(String relPath) {
    final File file = File(relPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '守卫目标文件不存在：$relPath（文件被移动/改名时本守卫必须同步更新，'
          '而不是被静默跳过）',
    );
    return maskComments(file.readAsStringSync());
  }

  test('剥注释前置自检：注释里的符号不算数，真实代码必须留下', () {
    // 这条是本守卫自身的反例保护：如果 maskComments 哪天把真实代码也吃掉，
    // 下面四条断言会集体假绿（永远匹配不到 = 永远不报警）。
    expect(
      maskComments('/// 见 [_lookupOverlayActive] 的文档\n'),
      isNot(contains('_lookupOverlayActive')),
      reason: '文档注释里的符号必须被剥掉，否则「只留注释」也能骗过守卫',
    );
    expect(
      maskComments('if (_lookupOverlayActive.value) return; // 早退'),
      contains('_lookupOverlayActive.value'),
      reason: '真实代码必须保留，否则守卫恒不命中 = 恒假绿',
    );
  });

  test('BUG-1798 ①：_pokeControlsVisible 在查词浮层开着时早退', () {
    final String src = code(visibilityRelPath);
    final int pokeStart = src.indexOf('void _pokeControlsVisible()');
    expect(
      pokeStart,
      greaterThanOrEqualTo(0),
      reason: '_pokeControlsVisible 已改名/删除，守卫需同步更新',
    );
    // 只截到方法体内合成事件构造之前那段（早退门控区），避免匹配到后文无关代码。
    final int dispatchAt = src.indexOf('_pendingPokeHover', pokeStart);
    expect(dispatchAt, greaterThan(pokeStart));
    final String gateRegion = src.substring(pokeStart, dispatchAt);

    expect(
      RegExp(
        r'if\s*\(\s*_lookupOverlayActive\.value\s*\)\s*return\s*;',
      ).hasMatch(gateRegion),
      isTrue,
      reason:
          '浮层开着时 barrier 已接管全屏命中，合成 hover 必然到不了 media_kit 的 '
          'MouseRegion（续命纯无效），却会落进 _onDismissBarrierHover 污染指针记账。'
          '必须与其余四个门控同族地早退。',
    );
  });

  test('BUG-1798 ②：两个指针位置记账点都滤掉合成 hover', () {
    final String src = code(pageRelPath);
    // `_lastGlobalPointerPos` 是「用户光标在哪」的唯一真值，供 Shift 反查使用。
    // 合成 hover 的位置恒为视频区几何中心，写进来就是把它记成画面正中。
    final Iterable<Match> writes = RegExp(
      r'_lastGlobalPointerPos\s*=\s*event\.position',
    ).allMatches(src);
    expect(
      writes.length,
      2,
      reason:
          '记账点数量变了（当前 ${writes.length} 处）。新增/删除记账点时必须同步'
          '本守卫——每一个写入点都要有合成事件过滤，只滤一个仍会从另一个漏进来。',
    );

    for (final Match m in writes) {
      // 往前回看一小段，要求同一作用域内先有合成设备早退。
      final int from = m.start - 400 < 0 ? 0 : m.start - 400;
      final String before = src.substring(from, m.start);
      expect(
        before.contains('_isSyntheticControlsHover(event)'),
        isTrue,
        reason:
            '偏移 ${m.start} 处的 _lastGlobalPointerPos 写入没有被 '
            '_isSyntheticControlsHover 保护：合成 hover 会把用户光标位置记成画面正中，'
            'Shift 反查随即查错位置。',
      );
    }
  });

  test('BUG-1798 ③：_hasVideoOverlay 把查词浮层算作 overlay', () {
    final String src = code(pageRelPath);
    final int start = src.indexOf('bool get _hasVideoOverlay');
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: '_hasVideoOverlay 已改名/删除，守卫需同步更新',
    );
    final int end = src.indexOf(';', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(
      body.contains('_lookupOverlayActive.value'),
      isTrue,
      reason:
          '查词浮层是本页最需要光标的覆盖层（点词/点发音/拖把手/滚正文），'
          '不在 _hasVideoOverlay 里就会在控制条自动淡出时被 _setCursorHidden(true) '
          '连同弹窗一起把 OS 光标吃掉。',
    );

    // 门控真值必须是可订阅的 notifier 且被真正订阅，否则值变了没人重跑派生。
    expect(
      src.contains(
        '_lookupOverlayActive.addListener(_applyControlsVisibilityFromMediaKit)',
      ),
      isTrue,
      reason:
          '_applyControlsVisibilityFromMediaKit 的输入必须全部被订阅，'
          '否则弹窗开/关时光标策略停在上一次的结论上（改了也白改）。',
    );
    expect(
      src.contains(
        '_lookupOverlayActive.removeListener(_applyControlsVisibilityFromMediaKit)',
      ),
      isTrue,
      reason: 'dispose 必须与 initState 对称摘监听，否则回调在已释放的 notifier 上触发。',
    );
    // 单一写入点：栈变化的唯一收口负责推真值。
    expect(
      RegExp(r'_lookupOverlayActive\.value\s*=').hasMatch(src),
      isTrue,
      reason: '必须有唯一写入点把 _popup 的真值推进门控 notifier，否则它恒为 false。',
    );
  });

  test('BUG-1798 ④：fork 侧 hideMouseOnControlsRemoval 也排除查词浮层，且不哑火', () {
    final String themeSrc = code(themeRelPath);
    final int start = themeSrc.indexOf('hideMouseOnControlsRemoval:');
    expect(
      start,
      greaterThanOrEqualTo(0),
      reason: 'hideMouseOnControlsRemoval 赋值已消失，守卫需同步更新',
    );
    final int end = themeSrc.indexOf(',', themeSrc.indexOf(')', start));
    final String expr = themeSrc.substring(start, end < start ? start : end);

    expect(
      expr.contains('_lookupOverlayActive.value'),
      isTrue,
      reason:
          'Hibiki 侧 _buildCursorOverlay 与 fork 侧 hideMouseOnControlsRemoval 是'
          '**两层独立的** cursor:none，只修一层，另一层照样把光标吃掉。',
    );

    // 防哑火：theme 由 layout 的 ListenableBuilder.merge 构造，判据里的 notifier
    // 必须全在 merge 列表内，否则翻转时 theme 不重建 = 改了值也白改（r5 教训）。
    final String layoutSrc = code(layoutRelPath);
    final int mergeAt = layoutSrc.indexOf('Listenable.merge');
    expect(mergeAt, greaterThanOrEqualTo(0));
    final int mergeEnd = layoutSrc.indexOf('],', mergeAt);
    expect(mergeEnd, greaterThan(mergeAt));
    expect(
      layoutSrc.substring(mergeAt, mergeEnd).contains('_lookupOverlayActive'),
      isTrue,
      reason:
          '_lookupOverlayActive 进了 theme 判据却没进 merge 列表 = 哑火：'
          '弹窗一开 theme 仍是上一轮的 true，光标照样被 fork 那层 cursor:none 吃掉。',
    );
  });
}
