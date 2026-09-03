import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';

import 'package:fushi/src/pages/implementations/managed_video_source_prompt.dart';

/// 视频发现 / 详情页「搜索资源」「订阅」在**后端已就绪、只是没有受管视频来源**时
/// 的出口：此前是一条「暂无来源」snackbar（既不说缺什么，也没处点）；现在弹
/// 引导说清缺的是落地用的本地视频文件夹，并就地开来源管理对话框补上。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  Future<bool?> pump(
    WidgetTester tester, {
    required Future<void> Function(BuildContext context) openSourcesDialog,
  }) async {
    bool? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await promptManagedVideoSourceSetup(
                    context: context,
                    openSourcesDialog: openSourcesDialog,
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('说清缺的是落地用的视频文件夹；「添加视频来源」开来源对话框并返回 true',
      (WidgetTester tester) async {
    int opened = 0;
    await pump(tester, openSourcesDialog: (BuildContext _) async => opened++);

    expect(find.text(t.download_no_managed_video_source), findsOneWidget);
    // 标题说状态、主按钮说动作：同一句话在同一个对话框里出现两遍是撞词。
    // （旧断言 `find.text('暂无来源')` 是恒真的——本对话框任何分支都不渲染那个
    // 硬编码中文串，改回旧 snackbar 写法它照样绿。）
    expect(find.text(t.download_video_source_required), findsOneWidget);
    expect(
      t.download_video_source_required,
      isNot(t.download_add_video_source),
      reason: '对话框标题不能与主按钮同文案',
    );
    expect(find.text(t.download_add_video_source), findsOneWidget,
        reason: '「添加视频来源」只出现在主按钮上，不再兼任标题');

    await tester.tap(
      find.byKey(const ValueKey<String>('managed_video_source_prompt_add')),
    );
    await tester.pumpAndSettle();

    expect(opened, 1, reason: '确认后就地开来源管理对话框，不把用户支去别处');
    expect(find.text(t.download_no_managed_video_source), findsNothing);
  });

  testWidgets('取消 = 明确放弃：不开来源对话框、返回 false', (WidgetTester tester) async {
    int opened = 0;
    await pump(tester, openSourcesDialog: (BuildContext _) async => opened++);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(find.text(t.download_no_managed_video_source), findsNothing);
  });
}
