/// P4 补扫结果卡片：动作按钮与「云端重试」显隐 gating（开关开 + key 非空才显示）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/manga/manga_rescan_result_sheet.dart';

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('showCloudRetry=false（开关关/无 key）：不显示云端重试',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const MangaRescanResultSheet(
      text: 'こんにちは',
      fromCloud: false,
      showCloudRetry: false,
    )));
    expect(find.text('こんにちは'), findsOneWidget);
    expect(find.text(t.manga_rescan_local_source), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manga_rescan_lookup')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manga_rescan_writeback')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('manga_rescan_cloud_retry')),
        findsNothing,
        reason: '云端未启用时不得出现「云端重试」（红线：默认关）');
  });

  testWidgets('showCloudRetry=true：显示云端重试并可返回动作', (WidgetTester tester) async {
    MangaRescanAction? popped;
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await showModalBottomSheet<MangaRescanAction>(
                    context: context,
                    builder: (BuildContext ctx) => const MangaRescanResultSheet(
                      text: 'こんにちは',
                      fromCloud: false,
                      showCloudRetry: true,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('manga_rescan_cloud_retry')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey<String>('manga_rescan_cloud_retry')));
    await tester.pumpAndSettle();
    expect(popped, MangaRescanAction.cloudRetry);
  });

  testWidgets('云端结果标注来源；空文本禁用查词/回写但云端重试仍可用', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(const MangaRescanResultSheet(
      text: '',
      fromCloud: true,
      showCloudRetry: true,
    )));
    expect(find.text(t.manga_rescan_cloud_source), findsOneWidget);
    expect(find.text(t.manga_rescan_empty), findsOneWidget);
    final FilledButton lookup = tester.widget<FilledButton>(find.ancestor(
      of: find.text(t.manga_rescan_lookup),
      matching: find.byType(FilledButton),
    ));
    expect(lookup.onPressed, isNull, reason: '空文本无词可查');
    final OutlinedButton writeback =
        tester.widget<OutlinedButton>(find.ancestor(
      of: find.text(t.manga_rescan_writeback),
      matching: find.byType(OutlinedButton),
    ));
    expect(writeback.onPressed, isNull, reason: '空文本不回写');
    final OutlinedButton cloud = tester.widget<OutlinedButton>(find.ancestor(
      of: find.text(t.manga_rescan_cloud_retry),
      matching: find.byType(OutlinedButton),
    ));
    expect(cloud.onPressed, isNotNull, reason: '本地认不出正是云端兜底主场景，空文本时云端重试必须可用');
  });
}
