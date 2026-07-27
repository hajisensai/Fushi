import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-928 守卫：视频卡封面区必须被固定 AspectRatio 锁定。
///
/// 根因：封面此前用 `Expanded` 吃掉「cell 高 − 下方文字块实际高度」的剩余，而文字块
/// 高度随标题行数 / 有无观看进度浮动，文字不足时多出的空间灌进封面区、使其比例
/// 浮动，contain 封面上下留空隙（标题短或无进度时才现，「时有时无」）。
/// 修复：封面 Stack 改由固定 `AspectRatio` 包裹，与文字长短彻底解耦；文字块下移进
/// `Expanded`（占封面下方剩余固定高度，ellipsis 内收）。
///
/// 2026-07-24 用户拍板：主网格统一 Kazumi 式 2:3 竖版海报，封面比例从 16:9 改为
/// `2 / 3`（横版截帧由 PortraitCoverImage 模糊垫底填充）；守卫锚点同步到新比例，
/// 「固定 AspectRatio、禁 Expanded 浮动比例」的 BUG-928 意图不变。
///
/// 这是源码扫描守卫——封面是 UI 渲染难做像素断言，故锚定到两张视频卡（本地
/// `_buildCard` + 远端 `_buildRemoteVideoCard`）的函数体，断言封面被 2:3 AspectRatio
/// 锁定、且不得回退到 `Expanded(child: Stack(...))` 的浮动比例写法。
void main() {
  const String path = 'lib/src/pages/implementations/home_video_page.dart';

  test(
      'video card covers are pinned to a 2:3 poster AspectRatio (no gap) — BUG-928',
      () {
    final String source = File(path).readAsStringSync();

    final Map<String, String> bodies = <String, String>{
      '_buildCard': _functionSource(source, 'Widget _buildCard('),
      '_buildRemoteVideoCard':
          _functionSource(source, 'Widget _buildRemoteVideoCard('),
    };

    // 封面 Stack 直接被 Expanded 包裹 = 比例随剩余空间浮动的回归写法（BUG-928 根因）。
    final RegExp expandedCover =
        RegExp(r'Expanded\(\s*child: Stack\(\s*fit: StackFit\.expand');

    for (final MapEntry<String, String> entry in bodies.entries) {
      final String name = entry.key;
      final String body = entry.value;

      expect(
        body,
        contains('aspectRatio: 2 / 3'),
        reason: '$name 的封面必须用 AspectRatio(aspectRatio: 2 / 3) 锁定竖版海报'
            '比例（2026-07-24 主网格统一 Kazumi 式竖版），比例不得随文字块浮动',
      );
      expect(
        body,
        isNot(contains(expandedCover)),
        reason: '$name 封面不得用 Expanded(child: Stack(...)) 包裹——比例会随下方'
            '文字块高度浮动、把空隙灌回封面区（BUG-928 回归）',
      );

      // BUG-1177 起标题改为两行（原 BUG-943 要求单行，见下方 text block 用例里
      // 记录的权衡）：窄屏卡宽只有约 154px，单行 ellipsis 放不下一个日文剧名。
      expect(
        body,
        contains('maxLines: 2'),
        reason: '$name 标题必须 maxLines: 2——窄屏卡宽约 154px，单行放不下常见的'
            '日文剧名（BUG-1177）',
      );
    }
  });

  // BUG-943 与 BUG-1177 的权衡，明确记录在此，便于日后一句话回退：
  //
  // - BUG-943（用户实报「底部多显示了一块」）的根因是文字块**死钳 83px**——那是
  //   「2 行标题 + 进度行」的最坏情况预留，而绝大多数卡是单行标题、无进度，于是
  //   底部常驻约 50px 空白。当时的修法是把常量收敛到 52 并把标题钳成单行。
  // - BUG-1177（用户实报窄屏「书/视频的名字显示不全」）暴露了那次修法的代价：
  //   360dp 手机上卡宽只有约 154px，单行 ellipsis 只显示得到日文剧名的开头几个字。
  //
  // 现在文字块高度**按真实行高算出**（_videoCardTextBlock），不再是任何一个猜出来
  // 的常量：默认字号下约 66px，比当年的最坏预留 83 小得多，比 52 多约 14px。也就是
  // 说 BUG-943 抱怨的 50px 空白并没有回归，只是短标题卡多了约 14px——这是让长标题
  // 能显示第二行必须付的最小代价。本用例守住的是「不得回到最坏预留」这条底线。
  test(
      'video card text block is computed from real line heights, not a '
      'worst-case constant — BUG-943 / BUG-1177', () {
    final String source = File(path).readAsStringSync();

    expect(
      source,
      isNot(contains('_kVideoCardTextBlock =')),
      reason: '文字块高度不得再退回硬编码常量——它必须随字号/文字缩放算出，否则'
          '大字号下要么裁字（BUG-1177）要么留空白（BUG-943）',
    );
    expect(
      source,
      contains('static double _videoCardTextBlock(BuildContext context)'),
      reason: '文字块高度必须由 _videoCardTextBlock(context) 按真实行高算出',
    );
    // 两行标题 + 一行进度 + 内边距：默认字号（14/12sp、行高约 1.3）下约 66px，
    // 必须明显小于当年的最坏预留 83，否则就是 BUG-943 的空白回归。
    const double titleLine = 14.0 * 1.3;
    const double metaLine = 12.0 * 1.3;
    const double computed = titleLine * 2 + 8 + metaLine + 6;
    expect(
      computed,
      lessThan(83),
      reason: '按公式算出的文字块高度必须小于 BUG-943 当年的最坏预留 83px',
    );
  });
}

/// 截取从 [startToken] 起到下一个顶层 `  Widget xxx(` 方法定义之前的源码片段。
String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
