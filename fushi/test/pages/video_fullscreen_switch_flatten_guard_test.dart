import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-839 / BUG-2043 守卫：全屏下连播/换集不得漏栈旧集页，也不得先退原生全屏再进。
///
/// 根因（BUG-839）：全屏播放时 app 全屏路由被推到 **root navigator**（`fullscreen.part.dart`
/// 的 `_pushNeutralizedVideoFullscreen`，`rootNavigator: true`），压在剧集页之上。本地换集
/// 走 `navigator.pushReplacement`——它替换的是该 navigator 的**栈顶路由**。若换集前不处理
/// 全屏路由，`pushReplacement` 会替换掉栈顶的全屏路由、把本集页漏在栈里，每连播一集残留
/// 一层 → 按 ESC 一层层回退而非退出。
///
/// BUG-839 第一版修法「先 `_exitVideoFullscreen` pop 全屏路由，再 pushReplacement」引出
/// BUG-2043：pop 经 media_kit `PopScope` 触发一次**原生退全屏**（Windows 还原窗口 + 标题栏
/// 闪现），新页就绪后再进一次——一次换集窗口尺寸来回抖两轮，偶发卡死 / 布局错位，字幕
/// 列表也随旧页丢。
///
/// 现行不变量（BUG-2043）：
/// ① `_switchEpisode` 本地分支**不再调 `_exitVideoFullscreen`**；全屏时用 `navigator.push`
///    把新页压在全屏路由之上，再用 `removeRoute` 静默摘掉旧全屏路由与本页（不经 pop →
///    不触发原生退全屏；栈仍恒平）；窗口模式仍走 `pushReplacement`。
/// ② 新页收到 `initialFullscreen: wasFullscreen` 与 `initialSubtitleListVisible`（字幕列表
///    随集常驻）。
/// ③ 新页 initState 经 `_claimHandedOverNativeFullscreen` 认领原生全屏（Windows 持有标题栏
///    owner）；就绪后压自己的全屏路由（快/慢两条就绪路径都触发）；就绪失败 / 超时 /
///    dispose 时经 `_releaseHandedOverNativeFullscreen` 亲自退原生全屏。
///
/// 撤掉任一环即转红。行为级复现需 media_kit + 全屏路由 + 真 navigator 栈，故守在最强可
/// 落地的源码层；端到端由 `integration_test/video_fullscreen_sublist_next_episode_test.dart`
/// 在 Windows 离屏 runner 兜底。
void main() {
  final File episodePart = File(
    'lib/src/pages/implementations/video_fushi/episode.part.dart',
  );
  final File fullscreenPart = File(
    'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
  );
  final File pageFile = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  );

  late String switchBody;
  late String fullscreenSrc;
  late String pageSrc;

  /// 剥掉 `//` 行注释，避免注释里提到的符号被 indexOf 先命中。
  String stripLineComments(String src) => src
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  setUpAll(() {
    for (final File f in <File>[episodePart, fullscreenPart, pageFile]) {
      expect(f.existsSync(), isTrue, reason: '缺文件 ${f.path}');
    }
    final String episodeSrc = episodePart.readAsStringSync().replaceAll(
      '\r\n',
      '\n',
    );
    final int start = episodeSrc.indexOf('Future<void> _switchEpisode(');
    expect(start, isNonNegative, reason: '找不到 _switchEpisode 方法');
    // 方法体终点锚：下一个 `\n  /// ` 文档注释（_showEpisodeList 前）。
    final int end = episodeSrc.indexOf('\n  /// ', start);
    expect(end, greaterThan(start), reason: '找不到 _switchEpisode 方法体终点');
    switchBody = stripLineComments(episodeSrc.substring(start, end));

    fullscreenSrc = stripLineComments(
      fullscreenPart.readAsStringSync().replaceAll('\r\n', '\n'),
    );
    pageSrc = stripLineComments(
      pageFile.readAsStringSync().replaceAll('\r\n', '\n'),
    );
  });

  test('换集本地分支：不退全屏路由，改为 push 新页 + removeRoute 摘旧路由', () {
    expect(
      switchBody.contains('_exitVideoFullscreen('),
      isFalse,
      reason: '换集不得再 pop 全屏路由（会触发原生退全屏抖动，BUG-2043）',
    );
    final int pushIdx = switchBody.indexOf('navigator.push<void>(nextRoute)');
    expect(
      pushIdx,
      isNonNegative,
      reason: '全屏换集应把新页 push 到全屏路由之上（不 pushReplacement）',
    );
    final int removeFsIdx = switchBody.indexOf(
      'rootNavigator.removeRoute<void>(oldFullscreenRoute)',
    );
    final int removeSelfIdx = switchBody.indexOf(
      'navigator.removeRoute<Object?>(currentRoute!)',
    );
    expect(
      removeFsIdx,
      greaterThan(pushIdx),
      reason: 'push 新页后必须 removeRoute 旧全屏路由（不经 pop，栈恒平 BUG-839）',
    );
    expect(
      removeSelfIdx,
      greaterThan(removeFsIdx),
      reason: '摘完旧全屏路由再摘本页，避免旧页先 dispose 而全屏路由仍引用其 State',
    );
    expect(
      switchBody.contains('navigator.pushReplacement<void, void>(nextRoute)'),
      isTrue,
      reason: '窗口模式换集仍走 pushReplacement（栈平、行为不变）',
    );
  });

  test('退全屏改动只作用于本地分支（在远端早退之后）', () {
    final int remoteReturnIdx = switchBody.indexOf(
      '_loadRemoteEpisode(index, startIntent: intent)',
    );
    final int pushIdx = switchBody.indexOf('navigator.push<void>(nextRoute)');
    expect(remoteReturnIdx, isNonNegative, reason: '远端分支应走 _loadRemoteEpisode');
    expect(
      pushIdx,
      greaterThan(remoteReturnIdx),
      reason: '路由接管必须在远端早退之后，只作用于本地换集分支（远端原地换流不压栈）',
    );
  });

  test('换集把全屏态与字幕列表可见性透传给新页', () {
    // 决策收敛进纯函数 [resolveEpisodeSwitchPlan]（真值表见
    // test/media/video/video_episode_start_policy_test.dart）。这里只守「生产路径
    // 确实消费了它、两个输入都接在真字段上、分支条件没被额外析取项撑成恒真」——
    // 语义正确性由真值表负责，可达性由「条件必须逐字等于 plan 查询」负责。
    expect(
      switchBody
          .contains('final EpisodeSwitchPlan plan = resolveEpisodeSwitchPlan('),
      isTrue,
      reason: '换集的路由决策必须走纯函数 resolveEpisodeSwitchPlan，不得手写布尔表达式',
    );
    expect(
      switchBody.contains(
        'fullscreenRouteActive: oldFullscreenRoute?.isActive ?? false,',
      ),
      isTrue,
      reason: 'fullscreenRouteActive 必须接旧全屏路由的真实 isActive（不得写死）',
    );
    expect(
      switchBody.contains(
        'ownsHandedOverNativeFullscreen: _ownsHandedOverNativeFullscreen,',
      ),
      isTrue,
      reason: '接管来的原生全屏所有权必须参与判定，只看路由会漏掉就绪窗口内连按下一集',
    );
    expect(
      switchBody.contains('hasCurrentRoute: currentRoute != null,'),
      isTrue,
      reason: 'hasCurrentRoute 必须接真实 ModalRoute（摘不掉本页就不能走接管）',
    );
    // 逐字断言分支条件：插入 `true || ` / `false && ` 让接管块变死代码即转红
    // （纯函数真值表看不到调用点的条件被撑成恒真）。
    expect(
      switchBody.contains('if (plan.mode == EpisodeSwitchMode.replace) {'),
      isTrue,
      reason: '顶替分支条件必须逐字等于 plan 查询，不得掺入任何额外析取/合取项',
    );
    expect(
      switchBody.contains('initialFullscreen: plan.handOverNativeFullscreen,'),
      isTrue,
      reason: '新页 neutralized 必须收到 plan.handOverNativeFullscreen，才能重进全屏',
    );
    expect(
      switchBody.contains(
        'initialSubtitleListVisible: _subtitleListVisible.value',
      ),
      isTrue,
      reason: '字幕列表随集常驻：换集必须把可见性透传给新页（BUG-2043）',
    );
    expect(
      switchBody.contains('_ownsHandedOverNativeFullscreen = false'),
      isTrue,
      reason: '交接后本页不得在 dispose 里再释放原生全屏（所有权已传给新页）',
    );
    expect(
      switchBody.contains('_didInitialFullscreen = true'),
      isTrue,
      reason: '交接后本页挂着的一次性重进全屏回调不得再压路由',
    );
  });

  test('VideoFushiPage / neutralized 承载 initialFullscreen 字段并透传', () {
    expect(
      pageSrc.contains('final bool initialFullscreen;'),
      isTrue,
      reason: 'VideoFushiPage 应有 initialFullscreen 字段',
    );
    expect(
      pageSrc.contains('this.initialFullscreen = false'),
      isTrue,
      reason: '默认构造器应默认 initialFullscreen=false（首开不自动全屏）',
    );
    // neutralized 工厂必须把入参透传给构造器，否则换集标志到不了新页 State。
    expect(
      pageSrc.contains('bool initialFullscreen = false'),
      isTrue,
      reason: 'neutralized 工厂应有 initialFullscreen 形参',
    );
    expect(
      pageSrc.contains('initialFullscreen: initialFullscreen'),
      isTrue,
      reason: 'neutralized 必须把 initialFullscreen 透传给 VideoFushiPage',
    );
  });

  test('新页首帧就绪的两条路径都触发重进全屏', () {
    // 慢路径 [_promoteVideoReady] 与快路径（isInitialVideoOpen 直接翻真）都必须调
    // _scheduleInitialFullscreenIfNeeded，否则本地文件（快路径）换集不会重进全屏。
    final int scheduleCalls = '_scheduleInitialFullscreenIfNeeded()'
        .allMatches(pageSrc)
        .length;
    expect(
      scheduleCalls,
      greaterThanOrEqualTo(2),
      reason: '快/慢两条就绪路径都要触发重进全屏（至少 2 处调用）',
    );
  });

  test('重进全屏方法存在且一次性、带上限防死循环', () {
    expect(
      fullscreenSrc.contains('void _scheduleInitialFullscreenIfNeeded()'),
      isTrue,
      reason: '应在 fullscreen 域定义 _scheduleInitialFullscreenIfNeeded',
    );
    expect(
      fullscreenSrc.contains('_didInitialFullscreen'),
      isTrue,
      reason: '重进全屏必须一次性（_didInitialFullscreen 闸门）',
    );
    expect(
      fullscreenSrc.contains('_initialFullscreenRetries'),
      isTrue,
      reason: 'controls 未就绪时的重试必须有上限（_initialFullscreenRetries），杜绝死循环',
    );
    expect(
      fullscreenSrc.contains('_pushNeutralizedVideoFullscreen('),
      isTrue,
      reason: '就绪后应经 _pushNeutralizedVideoFullscreen 重进全屏路由',
    );
  });

  test('新页认领 / 释放接管来的原生全屏（BUG-2043）', () {
    expect(
      pageSrc.contains('_claimHandedOverNativeFullscreen();'),
      isTrue,
      reason: 'initState 必须认领接管来的原生全屏（持有标题栏 owner）',
    );
    expect(
      fullscreenSrc.contains('void _claimHandedOverNativeFullscreen()'),
      isTrue,
    );
    expect(
      fullscreenSrc.contains(
        'FushiWindowsTitleBar.setContentFullscreen(owner: this, enabled: true)',
      ),
      isTrue,
      reason: '认领时 Windows 必须立刻持有标题栏 owner，否则旧页 dispose 后标题栏闪出',
    );
    // dispose 兜底：加载中被退出 → 亲自退原生全屏。
    final int disposeIdx = pageSrc.indexOf('  void dispose() {');
    expect(disposeIdx, isNonNegative);
    final int releaseIdx = pageSrc.indexOf(
      '_releaseHandedOverNativeFullscreen();',
      disposeIdx,
    );
    expect(releaseIdx, isNonNegative, reason: 'dispose 必须释放接管来的原生全屏');
    expect(
      releaseIdx - disposeIdx,
      lessThan(600),
      reason: '释放应在 dispose 开头（先于标题栏 owner 释放与 controller dispose）',
    );
    // 放弃重进全屏（失败 / 缺失 / 超时）同样释放。
    final int giveUpIdx = fullscreenSrc.indexOf(
      '_initialFullscreenRetries > 30',
    );
    expect(giveUpIdx, isNonNegative);
    final int giveUpReleaseIdx = fullscreenSrc.indexOf(
      '_releaseHandedOverNativeFullscreen();',
      giveUpIdx,
    );
    expect(giveUpReleaseIdx, isNonNegative);
    expect(
      giveUpReleaseIdx - giveUpIdx,
      lessThan(200),
      reason: '放弃分支必须紧接着释放原生全屏',
    );
    // BUG-2043 P2：所有权只能在**全屏路由真的建出来之后**才翻假。
    // `_pushNeutralizedVideoFullscreen` 开头有 `_videoFullscreenTransitioning` /
    // 已全屏两道提前 return；在调用点提前翻假 → 提前 return 时窗口停在「原生全屏
    // 但栈上无全屏路由」的悬空态，且 dispose 的 release 已成 no-op、退不回去。
    final int pushDefIdx = fullscreenSrc.indexOf(
      'Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {',
    );
    expect(pushDefIdx, isNonNegative,
        reason: '找不到 _pushNeutralizedVideoFullscreen');
    final int routeAssignIdx = fullscreenSrc.indexOf(
      '_videoFullscreenRoute = fullscreenRoute;',
      pushDefIdx,
    );
    expect(routeAssignIdx, isNonNegative, reason: '找不到全屏路由的赋值点');
    final int handIdx = fullscreenSrc.indexOf(
      '_ownsHandedOverNativeFullscreen = false;',
      pushDefIdx,
    );
    expect(
      handIdx,
      isNonNegative,
      reason: '建出全屏路由时必须把接管来的所有权移交路由',
    );
    expect(
      handIdx,
      lessThan(routeAssignIdx),
      reason: '所有权翻假必须与 _videoFullscreenRoute 赋值同段（紧挨其前），不得散在别处',
    );
    expect(
      routeAssignIdx - handIdx,
      lessThan(60),
      reason: '翻假与路由赋值之间不得插入任何可提前 return 的语句',
    );
    // 调用点（_scheduleInitialFullscreenIfNeeded）只在「栈上已有全屏路由」时放手，
    // 其余一律交给 push 内部——把翻假搬回调用点即转红。
    final int scheduleIdx = fullscreenSrc.indexOf(
      'void _scheduleInitialFullscreenIfNeeded()',
    );
    expect(scheduleIdx, isNonNegative);
    final String scheduleBody =
        fullscreenSrc.substring(scheduleIdx, pushDefIdx);
    expect(
      'unawaited(_pushNeutralizedVideoFullscreen(ctx))'
          .allMatches(scheduleBody)
          .length,
      1,
      reason: '就绪后应经 _pushNeutralizedVideoFullscreen 重进全屏路由（恰一处）',
    );
    final int schedHandIdx = scheduleBody.indexOf(
      '_ownsHandedOverNativeFullscreen = false;',
    );
    expect(schedHandIdx, isNonNegative, reason: '已全屏分支仍要把所有权还给路由');
    final int schedGateIdx = scheduleBody.indexOf('if (isFullscreen(ctx)) {');
    expect(
      schedGateIdx,
      isNonNegative,
      reason: '调用点放手必须被「栈上已有全屏路由」这道门框住',
    );
    expect(
      schedHandIdx,
      greaterThan(schedGateIdx),
      reason: '调用点不得在门外无条件翻假（提前 return 会留下悬空的原生全屏）',
    );
    expect(
      scheduleBody.indexOf('unawaited(_pushNeutralizedVideoFullscreen(ctx))'),
      greaterThan(schedHandIdx),
      reason: '已全屏分支应 return，push 只在门外发生',
    );
    // 释放方法幂等且真的退原生全屏。
    final int releaseDefIdx = fullscreenSrc.indexOf(
      'void _releaseHandedOverNativeFullscreen()',
    );
    expect(releaseDefIdx, isNonNegative);
    final String releaseBody = fullscreenSrc.substring(
      releaseDefIdx,
      fullscreenSrc.indexOf('\n  }', releaseDefIdx),
    );
    expect(
      releaseBody.contains('if (!_ownsHandedOverNativeFullscreen) return;'),
      isTrue,
    );
    expect(
      releaseBody.contains('unawaited(_exitVideoNativeFullscreen())'),
      isTrue,
    );
  });
}
