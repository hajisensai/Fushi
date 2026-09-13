import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1798 守卫：查词浮层与视频控制条自动显隐之间的四条不变量。
///
/// 背景（真实代码路径）：视频页的查词浮层挂在**根 Overlay**（`_syncPopupOverlay`），其
/// dismiss barrier 是全屏 **opaque** 命中层。浮层一开，① `_pokeControlsVisible` 若仍去唤起
/// 控制条，只会在 barrier 背后与浮层打架（barrier 盖在控制条之上，唤起纯无效），还会经
/// `_handleSubtitleHover` 形成自激环；② 控制条照常 2s 自动淡出，而查词浮层此前不在
/// `_hasVideoOverlay` 里，Hibiki 侧 `_buildCursorOverlay` 与 fork 侧
/// `hideMouseOnControlsRemoval` **两层独立的** `cursor: none` 同时生效，鼠标悬在弹窗上时
/// OS 光标消失。
///
/// 历史注记（BUG-2453 之后已不成立的部分）：BUG-1798 时代 `_pokeControlsVisible` 靠往视频区
/// 中心派**合成 hover** 唤起 media_kit，浮层开着时它落不进 media_kit 的 `MouseRegion`、改落进
/// barrier 的 `_onDismissBarrierHover` 污染指针记账与换词去重键，故两个记账点各按设备号过滤
/// 一次。BUG-2453 把整套合成设备删了（唤醒改走 fork 的 `wakeSignal` 显式信号），到记账点的
/// hover **只可能是真实鼠标**，过滤对象随之消失——本文件 ② 改为反向钉住「过滤不得回来」。
///
/// 这些不变量全部落在私有 `State` 成员与 media_kit fork 的 theme 上，widget 测试要真起
/// 播放器 + 平台视图才能触达，故取**源码扫描**这一最强可落地层。
///
/// ⚠️ 本文件的每条断言都在 [maskComments] 之后执行。修复的注释里大量出现
/// `_lookupOverlayActive` / `_restartHideTimerSignal` 字样，若直接对原始源码做子串匹配，
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
      reason: '守卫目标文件不存在：$relPath（文件被移动/改名时本守卫必须同步更新，'
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
    // 方法体用花括号配对切出（[methodBody] 找不到签名会直接 fail，不会静默锚到邻居）。
    // BUG-2453 之前这里用「合成事件构造点」当右边界，那个锚点随合成设备一起删了；
    // 不变量本身没变：门控必须在方法的唯一出口 `_restartHideTimerSignal.poke();` 之前。
    final String body = maskComments(
      methodBody(code(visibilityRelPath), 'void _pokeControlsVisible()'),
    );
    const String gate = 'if (_lookupOverlayActive.value) return;';
    const String exit = '_restartHideTimerSignal.poke();';
    expect(
      containsCodeLine(body, gate),
      isTrue,
      reason: '浮层开着时 barrier 盖在控制条之上，唤起控制条只会在背后打架；且 '
          '_handleSubtitleHover 收到字幕 hover 就调本方法，不早退会形成自激环。'
          '必须与其余四个门控同族地早退。',
    );
    expect(
      containsCodeLine(body, exit),
      isTrue,
      reason: '_pokeControlsVisible 的出口已不是 $exit，守卫需同步更新',
    );
    expect(
      body.indexOf(gate),
      lessThan(body.indexOf(exit)),
      reason: '门控必须排在发信号之前——信号本身分不出「续命」和「唤起」，'
          '排在后面等于没门',
    );
  });

  test('BUG-1798 ②：两个指针位置记账点不再需要（也不得再有）按设备号过滤', () {
    final String src = code(pageRelPath);
    // `_lastGlobalPointerPos` 是「用户光标在哪」的唯一真值，供 Shift 反查使用（BUG-880）。
    // 两个记账点（页面根 Listener / 浮层 barrier）互为接力，少一个 Shift 反查就有盲区。
    final Iterable<Match> writes = RegExp(
      r'_lastGlobalPointerPos\s*=\s*event\.position',
    ).allMatches(src);
    expect(
      writes.length,
      2,
      reason: '记账点数量变了（当前 ${writes.length} 处）。新增/删除记账点时必须同步'
          '本守卫——页面根 Listener 与浮层 barrier 两条 hover 路径缺一都会让 Shift 反查有盲区。',
    );

    // BUG-2453：页面不再合成任何指针事件（唤醒改走 fork 的 wakeSignal），到记账点的 hover
    // 只可能是真实鼠标。BUG-1798 时代按设备号的过滤（`_isSyntheticControlsHover`）随之删除。
    // 这里反向钉住：过滤回来 = 合成设备回来 = 幽灵指针回来（BUG-2453 的根因），不允许。
    expect(
      containsIdentifier(src, '_isSyntheticControlsHover'),
      isFalse,
      reason: '按设备号过滤 hover 的 helper 不得回来：它存在的唯一理由是页面自己在造'
          '合成指针事件，而那正是 BUG-2453 幽灵悬停的来源',
    );
    for (final Match m in writes) {
      // 记账点所在的同一作用域内不得再按 `event.device` 分流：真实鼠标只有一种。
      final int from = m.start - 400 < 0 ? 0 : m.start - 400;
      final String before = src.substring(from, m.start);
      expect(
        before.contains('event.device'),
        isFalse,
        reason: '偏移 ${m.start} 处的 _lastGlobalPointerPos 写入前又出现了按 event.device '
            '的分流：BUG-2453 起页面不合成指针事件，记账点无需也不得区分设备号。',
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
      reason: '查词浮层是本页最需要光标的覆盖层（点词/点发音/拖把手/滚正文），'
          '不在 _hasVideoOverlay 里就会在控制条自动淡出时被 _setCursorHidden(true) '
          '连同弹窗一起把 OS 光标吃掉。',
    );

    // 门控真值必须是可订阅的 notifier 且被真正订阅，否则值变了没人重跑派生。
    expect(
      src.contains(
        '_lookupOverlayActive.addListener(_applyControlsVisibilityFromMediaKit)',
      ),
      isTrue,
      reason: '_applyControlsVisibilityFromMediaKit 的输入必须全部被订阅，'
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
      reason: '_lookupOverlayActive 进了 theme 判据却没进 merge 列表 = 哑火：'
          '弹窗一开 theme 仍是上一轮的 true，光标照样被 fork 那层 cursor:none 吃掉。',
    );
  });
}
