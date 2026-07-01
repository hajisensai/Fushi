import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import '../widgets/widget_test_helpers.dart';

// TODO-1055 / BUG-488 regression. 手机端阅读器目录（TOC）里长章节名被截断：
// 章节名走 AdaptiveSettingsRow.title → _SettingsLabel 的标题 Text，而该 Text 原先
// 硬编码 maxLines: kSettingsRowTitleMaxLines（=2）。窄屏 label 被 Expanded 压窄，长
// 章节名 2 行放不下就 ellipsis 截断。修复给 AdaptiveSettingsRow 增加可选
// titleMaxLines，透传到该 Text 的 maxLines；TOC 行传 4 让长章节名多行显示。
//
// 该测试直接 pump AdaptiveSettingsRow，取出标题 Text 断言其 maxLines：
//  ① 传 titleMaxLines: 4 时 maxLines 必须 > 2（不再是 2 行截断）——修复前红。
//  ② 不传时回退到默认 2，证明所有既有调用零行为变化。
const String _longChapterTitle = '第十二章 とても長い章のタイトルがここに続いていて、二行では到底収まらない '
    'ような非常に長い見出しのサンプルテキストです これは折り返しの検証用';

/// 从一棵 AdaptiveSettingsRow 里定位标题 Text（其内容即 title）。
Text _findTitleText(WidgetTester tester) {
  final Iterable<Text> matches = tester
      .widgetList<Text>(find.byType(Text))
      .where((Text w) => w.data == _longChapterTitle);
  expect(
    matches.length,
    1,
    reason: 'expected exactly one title Text carrying the chapter label',
  );
  return matches.first;
}

void main() {
  testWidgets(
    'AdaptiveSettingsRow with titleMaxLines: 4 lets the title wrap beyond 2 '
    'lines on a narrow phone (TODO-1055, BUG-488)',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(360, 720)),
            child: SizedBox(
              width: 360,
              child: AdaptiveSettingsRow(
                title: _longChapterTitle,
                icon: Icons.menu_book_outlined,
                showIcon: true,
                titleMaxLines: 4,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Text title = _findTitleText(tester);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(
        title.maxLines,
        greaterThan(2),
        reason: 'a TOC chapter row must allow more than the default 2 lines so '
            'long chapter names wrap instead of being clipped',
      );
      expect(title.maxLines, 4);
    },
  );

  testWidgets(
    'AdaptiveSettingsRow without titleMaxLines keeps the default 2-line clamp '
    '(no behavior change for existing rows)',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestApp(
          const MediaQuery(
            data: MediaQueryData(size: Size(360, 720)),
            child: SizedBox(
              width: 360,
              child: AdaptiveSettingsRow(
                title: _longChapterTitle,
                icon: Icons.menu_book_outlined,
                showIcon: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Text title = _findTitleText(tester);
      expect(
        title.maxLines,
        kSettingsRowTitleMaxLines,
        reason: 'default rows must remain clamped to the shared constant',
      );
    },
  );
}
