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
/// `2 / 3`（横版截帧由 PosterCoverImage 模糊垫底填充）；守卫锚点同步到新比例，
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

      // BUG-943（续 BUG-926）：标题必须单行——2 行预留在绝大多数单行标题卡下把底部撑出
      // 约 50px 空白块（用户实报「底部多显示了一块」）。
      expect(
        body,
        contains('maxLines: 1'),
        reason: '$name 标题必须 maxLines: 1，避免 2 行预留在单行标题卡下留底部空白',
      );
      expect(
        body,
        isNot(contains('maxLines: 2')),
        reason: '$name 不得回退到 maxLines: 2 的两行标题预留（BUG-943（续 BUG-926）空白回归）',
      );
    }
  });

  test(
      'video card text block stays compact (no worst-case reservation) '
      '— BUG-943（续 BUG-926）', () {
    final String source = File(path).readAsStringSync();
    final RegExpMatch? m = RegExp(r'_kVideoCardTextBlock\s*=\s*(\d+(?:\.\d+)?)')
        .firstMatch(source);
    expect(m, isNotNull, reason: '找不到 _kVideoCardTextBlock 常量');
    final double block = double.parse(m!.group(1)!);
    // 单行标题 + 单行进度 + 内边距约 52；旧值 83 是「2 行标题 + 进度行」最坏预留，
    // 单行标题无进度卡下底部常驻约 50px 空白（用户实报）。守住紧凑上限。
    expect(
      block,
      lessThanOrEqualTo(60),
      reason: '_kVideoCardTextBlock 不得回退到最坏预留（如 83），否则视频卡底部'
          '再次出现约 50px 常驻空白块（BUG-943（续 BUG-926））',
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
