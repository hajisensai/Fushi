import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// `_loadSingle` 字幕恢复兜底链的静态守卫（BUG-1655）。
///
/// 用户实测：在合集里用 Jimaku 下载并应用了字幕，退出再进就没了，只能重新下。
/// 排查到的真实数据（用户库 `D:\APP\HIBIKI_date`）：那一集的 `subtitle_source` 写对了、
/// 文件在磁盘上、能解析出 406 条 cue，但该行 `audio_cues` 条数为 **0**——合集里的每一集
/// 只落字幕源指针、不落 cue（`_selectSubtitleSource` 的 `_episodes.isEmpty` 分支）。
///
/// 于是恢复链的 else-if 结构成了单点故障：`rehydratePath != null` 这一支「试过但没解析出
/// 东西」时，`cues` 保持 DB 缓存（恒空），而后续的「持久化源精确恢复 / sidecar 探测 /
/// 内封轨自动加载」三层兜底全挂在同一条链的后面，一个都轮不到 ⇒ 零字幕、零兜底、零提示。
/// 单视频有 `loadCues` 那层 DB cue 安全网，所以只在合集里必现。
///
/// 播放页要 media_kit 真跑起来才能 widget 测，故按本仓既有范式落静态守卫；判据一律剥注释
/// （[containsCodeLine]），避免「把实现删掉、字面量留在注释里」骗绿。
void main() {
  final String src = readVideoFushiSource();
  final String body = methodBody(src, 'Future<void> _loadSingle(');

  test('兜底链独立于 else-if 链：任何一支没成功都必须能落到兜底', () {
    expect(
      containsCodeLine(body, 'if (!subtitleExplicitlyOff && cues.isEmpty) {'),
      isTrue,
      reason: '兜底必须是独立判据（「还没拿到 cue 就继续试」），而不是挂在 else-if 链尾',
    );
    expect(
      containsCodeLine(body, '} else if (cues.isEmpty) {'),
      isFalse,
      reason: '一旦兜底重新变成 else-if 分支，前面任一支「试过但失败」就会直接空手收场'
          '——这正是用户报「下载的字幕退出再进就没了」的结构性根因',
    );
  });

  test('sidecar 探测的门只看「还没有 cue」，不再要求没有持久化源', () {
    expect(
      containsCodeLine(body, 'if (cues.isEmpty && externalSub == null) {'),
      isFalse,
      reason: '旧判据下「有持久化源但它恢复不出内容」时连 sidecar 都不试，'
          '等于把唯一还能救的一层也关掉了',
    );
    expect(
      containsIdentifierCall(body, '_detectSidecar'),
      isTrue,
      reason: 'sidecar 探测这层兜底必须还在',
    );
  });

  test('恢复不出内容的外挂源不得挡住内封轨自动加载', () {
    // VideoPlayerController.load 只在「无外挂路径 + 无 cue」时才后台抽内封文本轨；
    // 留着一个解析不出东西的路径 = 连最后这层兜底也被挡掉。
    expect(
      containsCodeLine(body, 'externalSub = null;'),
      isTrue,
      reason: '最终仍无 cue 时必须放掉这个外挂路径，否则内封轨兜底永远不触发',
    );
    expect(
      containsCodeLine(body,
          'if (cues.isEmpty && !SubtitleSource.isEmbeddedPersisted(externalSub)) {'),
      isTrue,
      reason: '只在「确实没恢复出 cue」且源不是内嵌轨时才放掉；内嵌轨要保留给下游解析',
    );
  });

  test('显式关闭字幕仍然短路整条兜底（TODO-818 不倒退）', () {
    expect(
      containsCodeLine(body, 'if (subtitleExplicitlyOff) {'),
      isTrue,
      reason: '用户显式关过字幕就不该被任何一层兜底重新打开',
    );
    // 兜底判据自身也带 !subtitleExplicitlyOff，双保险。
    expect(
      containsCodeLine(body, 'if (!subtitleExplicitlyOff && cues.isEmpty) {'),
      isTrue,
    );
  });
}
