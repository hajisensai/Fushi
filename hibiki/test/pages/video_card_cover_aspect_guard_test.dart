import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-928 守卫：视频卡封面区必须被固定 AspectRatio 锁定。
///
/// 根因：封面此前用 `Expanded` 吃掉「cell 高 − 下方文字块实际高度」的剩余，而文字块
/// 高度随标题行数 / 有无观看进度浮动，文字不足时多出的空间灌进封面区、使其比例
/// 浮动，contain 封面上下留空隙（标题短或无进度时才现，「时有时无」）。
/// 修复：封面 Stack 改由固定 `AspectRatio` 包裹，与文字长短彻底解耦；文字块下移进
/// `Expanded`（占封面下方剩余固定高度，ellipsis 内收）。
///
/// 2026-07-24 用户拍板曾统一 2:3 竖版；TODO-2486（hayase 式改版）再拍板升级为
/// **朝向自适应**：封面朝向由 CoverOrientationBuilder 探测，竖版封面 2:3、横版
/// 封面 16:9（卡高统一、宽随朝向），朝向未知默认竖卡。守卫锚点同步到新契约，
/// 「固定 AspectRatio、禁 Expanded 浮动比例」的 BUG-928 意图不变。
///
/// 这是源码扫描守卫——封面是 UI 渲染难做像素断言，故锚定到两张视频卡（本地
/// `_buildCard` + 远端 `_buildRemoteVideoCard`）的函数体，断言封面被朝向条件的
/// AspectRatio（2:3 / 16:9）锁定、且不得回退到 `Expanded(child: Stack(...))` 的
/// 浮动比例写法。
void main() {
  const String path = 'lib/src/pages/implementations/home_video_page.dart';

  test(
      'video card covers are pinned to an orientation-adaptive AspectRatio '
      '(portrait 2:3 / landscape 16:9, no gap) — BUG-928 / TODO-2486', () {
    final String source = File(path).readAsStringSync();

    // 注释剥离后再断言：把锚点字面量塞进注释、实际代码回退定值的假绿被堵死
    // （变异实测确认）。
    final Map<String, String> bodies = <String, String>{
      '_buildCard':
          _stripLineComments(_functionSource(source, 'Widget _buildCard(')),
      '_buildRemoteVideoCard': _stripLineComments(
          _functionSource(source, 'Widget _buildRemoteVideoCard(')),
    };

    // 封面 Stack 直接被 Expanded 包裹 = 比例随剩余空间浮动的回归写法（BUG-928 根因）。
    final RegExp expandedCover =
        RegExp(r'Expanded\(\s*child: Stack\(\s*fit: StackFit\.expand');

    for (final MapEntry<String, String> entry in bodies.entries) {
      final String name = entry.key;
      final String body = entry.value;

      expect(
        body,
        contains(
            'orientation == VideoCardOrientation.landscape ? 16 / 9 : 2 / 3'),
        reason: '$name 的封面比例必须按朝向分流（TODO-2486 朝向自适应：竖版 '
            '2:3 / 横版 16:9），不得回到单一定值或随文字块浮动',
      );
      expect(
        body,
        isNot(contains(expandedCover)),
        reason: '$name 封面不得用 Expanded(child: Stack(...)) 包裹——比例会随下方'
            '文字块高度浮动、把空隙灌回封面区（BUG-928 回归）',
      );

      // BUG-1184 起标题改为两行（原 BUG-943 要求单行，见下方 text block 用例里
      // 记录的权衡）：窄屏卡宽只有约 154px，单行 ellipsis 放不下一个日文剧名。
      expect(
        body,
        contains('maxLines: 2'),
        reason: '$name 标题必须 maxLines: 2——窄屏卡宽约 154px，单行放不下常见的'
            '日文剧名（BUG-1184）',
      );
    }
  });

  // BUG-943 与 BUG-1184 的权衡，明确记录在此，便于日后一句话回退：
  //
  // - BUG-943（用户实报「底部多显示了一块」）的根因是文字块**死钳 83px**——那是
  //   「2 行标题 + 进度行」的最坏情况预留，而绝大多数卡是单行标题、无进度，于是
  //   底部常驻约 50px 空白。当时的修法是把常量收敛到 52 并把标题钳成单行。
  // - BUG-1184（用户实报窄屏「书/视频的名字显示不全」）暴露了那次修法的代价：
  //   360dp 手机上卡宽只有约 154px，单行 ellipsis 只显示得到日文剧名的开头几个字。
  //
  // 现在文字块高度**按真实行高算出**（_videoCardTextBlock），不再是任何一个猜出来
  // 的常量：默认字号下**实测约 74px**（bodyMedium 行高 1.43、labelMedium 1.33），
  // 仍小于当年的最坏预留 83，比收敛后的 52 多约 22px。也就是说 BUG-943 抱怨的那块
  // 约 50px 空白并没有回归，短标题卡多出的约 22px 是让长标题能显示第二行必须付的
  // 代价。下面两个用例守住的是「不得回到最坏预留、也不得算漏一行」这条区间。
  test(
      'video card text block is computed from real line heights, not a '
      'worst-case constant — BUG-943 / BUG-1184', () {
    final String source = File(path).readAsStringSync();

    expect(
      source,
      isNot(contains('_kVideoCardTextBlock =')),
      reason: '文字块高度不得再退回硬编码常量——它必须随字号/文字缩放算出，否则'
          '大字号下要么裁字（BUG-1184）要么留空白（BUG-943）',
    );
    expect(
      source,
      contains('static double _videoCardTextBlock(BuildContext context)'),
      reason: '文字块高度必须由 _videoCardTextBlock(context) 按真实行高算出',
    );
  });

  // 上面两条锁的是「必须算出来、不许再是常量」。这条锁的是**算出来的值本身**：
  // 默认字号下必须仍明显小于 BUG-943 当年的最坏预留 83px，否则卡底空白就是回归。
  //
  // 这里刻意用真实主题 / 真实 design token 现算，而不是在测试里再抄一遍系数——
  // 「各自猜行高系数」正是 BUG-1184 的根因之一（MD3 里 bodyMedium 行高是 1.43、
  // labelMedium 是 1.33，硬编码 1.3 会算低约 8px）。日后 MD3 排版或 metadata
  // token 变化把文字块推过 83，这条会红。
  testWidgets(
      'computed video card text block stays well under the old worst-case '
      '83px reservation — BUG-943 / BUG-1184', (WidgetTester tester) async {
    double? measured;
    await tester.pumpWidget(
      buildTestApp(
        Builder(builder: (BuildContext context) {
          // 与 _videoCardTextBlock 同构：两行标题 + 一行进度 + 内边距 8/6 + slack。
          final double titleLine = textLineHeight(
            context,
            Theme.of(context).textTheme.bodyMedium ??
                const TextStyle(fontSize: 14),
          );
          final double metaLine = textLineHeight(
            context,
            HibikiDesignTokens.of(context).type.metadata,
          );
          measured = titleLine * 2 + 8 + metaLine + 6 + kTextBlockSlack;
          return const SizedBox.shrink();
        }),
      ),
    );

    expect(measured, isNotNull, reason: 'builder 没跑到，测试无效');
    expect(
      measured!,
      lessThan(83),
      reason: '文字块高度必须明显小于 BUG-943 当年的最坏预留 83px，否则视频卡底部'
          '再次出现常驻空白块',
    );
    expect(
      measured!,
      greaterThan(60),
      reason: '两行标题 + 进度行装不下 60px——低于这个值说明公式又漏了一行或行高，'
          '大字号下会重新裁字（BUG-1184）',
    );
  });
}

/// 去掉行注释（`//` 到行尾），断言只看真代码。
String _stripLineComments(String source) => source.replaceAll(
      RegExp(r'//[^\n]*'),
      '',
    );

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
