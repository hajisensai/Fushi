import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// TODO-1310：「查看更新日志」页渲染守卫。通过 `initialReleases` 注入口绕开网络，
/// 验证：① 列表态渲染版本号/日期/预发布徽标/Markdown 正文；② 空态给出提示文案与
/// 「重试」「打开发布页」两个逃生口。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget wrap(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: home),
    );
  }

  testWidgets('列表态渲染版本号、日期、预发布徽标与正文', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      ChangelogPage(
        initialReleases: const <Map<String, dynamic>>[
          <String, dynamic>{
            'tag_name': 'v1.2.0',
            'published_at': '2026-07-10T08:00:00Z',
            'prerelease': false,
            'body': 'Stable release notes body',
          },
          <String, dynamic>{
            'tag_name': 'v1.3.0-beta.1',
            'published_at': '2026-07-15T09:30:00Z',
            'prerelease': true,
            'body': 'Beta notes',
          },
        ],
      ),
    ));
    await tester.pumpAndSettle();

    // 版本号
    expect(find.text('v1.2.0'), findsOneWidget);
    expect(find.text('v1.3.0-beta.1'), findsOneWidget);
    // 发布日期（取 ISO8601 的日期段）
    expect(find.text('2026-07-10'), findsOneWidget);
    expect(find.text('2026-07-15'), findsOneWidget);
    // 预发布徽标：仅 beta 那条有，stable 无 → 恰好一个
    expect(find.text(t.changelog_prerelease), findsOneWidget);
    // Markdown 正文（RichText）
    expect(
      find.textContaining('Stable release notes body', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('空列表渲染空态与两个逃生口', (WidgetTester tester) async {
    await tester.pumpWidget(wrap(
      const ChangelogPage(initialReleases: <Map<String, dynamic>>[]),
    ));
    await tester.pumpAndSettle();

    expect(find.text(t.changelog_empty), findsOneWidget);
    expect(find.text(t.retry), findsOneWidget);
    // 空态里的「打开发布页」按钮 + 顶栏图标 tooltip 同文案 → 至少一个
    expect(find.text(t.changelog_open_releases), findsWidgets);
    // 未注入网络时不应转圈（initialReleases 非 null 即跳过加载）
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
