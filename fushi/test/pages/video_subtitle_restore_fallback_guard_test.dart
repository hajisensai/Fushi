import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// `_loadSingle` 字幕恢复兜底链的静态守卫（BUG-1848）。
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
      // 已确定渲染图形轨（graphicStreamIndex != null）时不再试，BUG-3103。
      containsCodeLine(
        body,
        'if (!subtitleExplicitlyOff && cues.isEmpty && '
        'graphicStreamIndex == null) {',
      ),
      isTrue,
      reason: '兜底必须是独立判据（「还没拿到 cue 就继续试」），而不是挂在 else-if 链尾',
    );
    expect(
      containsCodeLine(body, '} else if (cues.isEmpty) {'),
      isFalse,
      reason:
          '一旦兜底重新变成 else-if 分支，前面任一支「试过但失败」就会直接空手收场'
          '——这正是用户报「下载的字幕退出再进就没了」的结构性根因',
    );
  });

  test('sidecar 探测的门只看「还没有 cue」，不再要求没有持久化源', () {
    expect(
      containsCodeLine(body, 'if (cues.isEmpty && externalSub == null) {'),
      isFalse,
      reason:
          '旧判据下「有持久化源但它恢复不出内容」时连 sidecar 都不试，'
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
      containsCodeLine(
        body,
        'if (cues.isEmpty && !SubtitleSource.isEmbeddedPersisted(externalSub)) {',
      ),
      isTrue,
      reason: '只在「确实没恢复出 cue」且源不是内嵌轨时才放掉；内嵌轨要保留给下游解析',
    );
  });

  test('本行没有选择时沿用兄弟集最近的选择：排在本行选择之后、自动探测之前（BUG-5464）', () {
    final String code = compactCode(body);
    // 只有本行自己没有选择（null / 空；`off:` 也是自己的选择）时才沿用。
    expect(
      code.contains(
        'finalInheritedSubtitleIntent?inheritedSubtitle='
        '(ownSubtitleChoice==null||ownSubtitleChoice.isEmpty)&&'
        'siblingChoice!=null?inheritedSubtitleIntent(siblingChoice):null;',
      ),
      isTrue,
      reason: '本行有选择（含显式关闭）时兄弟集的选择不得压过它',
    );
    // 独立的「还没拿到字幕」判据，不挂在 else-if 链上（BUG-1848 结构）。
    expect(
      code.contains(
        'if(inheritedSubtitle!=null&&cues.isEmpty&&graphicStreamIndex==null){',
      ),
      isTrue,
    );
    final String masked = maskComments(body);
    final int own = masked.indexOf('persisted: paths.subtitleSource');
    final int inherit = masked.indexOf('_restoreInheritedSubtitle(');
    final int sidecar = masked.indexOf('_detectSidecar(');
    final int folder = masked.indexOf('_detectSubtitleFolderMatch(');
    expect(own, greaterThanOrEqualTo(0));
    expect(inherit, greaterThan(own), reason: '本行自己的选择优先于兄弟集的');
    expect(sidecar, greaterThan(inherit), reason: '沿用的选择优先于 sidecar 探测');
    expect(folder, greaterThan(inherit));
    // 兄弟集关了字幕：本集同样关着起播，自动探测（sidecar / 文件夹 / 内封轨自动加载）短路。
    expect(
      code.contains(
        'if(inheritedSubtitleisInheritSubtitleOff){'
        'externalSub=SubtitleSource.offSentinel;',
      ),
      isTrue,
    );
    expect(
      code.contains(
        'if(!subtitleExplicitlyOff&&!SubtitleSource.isOff(externalSub)&&'
        'cues.isEmpty&&graphicStreamIndex==null){',
      ),
      isTrue,
      reason: '自动探测的门必须同时认本行关闭与沿用来的关闭',
    );
    expect(
      masked.indexOf('!SubtitleSource.isOff(externalSub)'),
      lessThan(sidecar),
    );
    // 沿用只管本次加载：不写回本行（用户在本集真正选了才写）。
    expect(containsIdentifierCall(body, 'updateSubtitleSource'), isFalse);
    expect(containsIdentifierCall(body, 'saveSubtitleSelection'), isFalse);
  });

  test('显式关闭字幕仍然短路整条兜底（TODO-818 不倒退）', () {
    // video-20 起 DB 缓存 cue 改惰性读取：不再有「if (subtitleExplicitlyOff) { cues = [] }」
    // 这一支，改由每个可能产出 cue 的入口各自带关闭判据。逐个钉住这些入口。
    expect(
      containsCodeLine(
        body,
        'final String? rehydratePath = subtitleExplicitlyOff',
      ),
      isTrue,
      reason: '关闭时外挂档案重解析路径必须恒为 null',
    );
    expect(
      containsCodeLine(
        body,
        'if (!subtitleExplicitlyOff && rehydratePath == null) {',
      ),
      isTrue,
      reason: '关闭时不得读 DB 缓存 cue（读了就会把关掉的字幕重新显示出来）',
    );
    final List<String> lines = maskComments(body).split('\n');
    final List<int> loadCuesLines = <int>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].contains('widget.repo.loadCues(')) i,
    ];
    expect(loadCuesLines, isNotEmpty, reason: 'DB cue 安全网必须还在');
    for (final int at in loadCuesLines) {
      String? gate;
      for (int i = at; i >= 0; i--) {
        if (lines[i].trimLeft().startsWith('if (')) {
          gate = lines[i];
          break;
        }
      }
      expect(
        gate != null &&
            (gate.contains('!subtitleExplicitlyOff') ||
                gate.contains('rehydratePath != null')),
        isTrue,
        reason:
            '每处 loadCues 都必须落在「未显式关闭」的门内'
            '（rehydratePath 非空蕴含未关闭）；第 ${at + 1} 行的门是：$gate',
      );
    }
    expect(
      RegExp(
        r'final bool rehydrateEmbedded =\s*!subtitleExplicitlyOff &&',
      ).hasMatch(maskComments(body)),
      isTrue,
      reason: '关闭时不得走内嵌轨重解析',
    );
    // 兜底链入口：用户显式关过字幕就不该被任何一层兜底重新打开。
    expect(
      // 已确定渲染图形轨（graphicStreamIndex != null）时不再试，BUG-3103。
      containsCodeLine(
        body,
        'if (!subtitleExplicitlyOff && cues.isEmpty && '
        'graphicStreamIndex == null) {',
      ),
      isTrue,
    );
  });
}
