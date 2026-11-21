import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_mine_queue_dialog.dart';
import 'package:fushi/src/mining/web_mine_queue_store.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板 design-nmv-webvideo-failed-retry（方案 a）：网页视频页点队列角标打开列表，
/// 失败行看得见原因、能单行重试 / 移除；「全部重试」跳过重复卡；「开始制卡」交回页面开跑。
void main() {
  late FushiDatabase db;
  late WebMineQueueStore store;

  Future<int> enqueue(WebMineQueueStore s, String word, int start) => s.enqueue(
    bookUid: 'video/stream/1',
    videoKey: 'www.youtube.com/watch?v=1',
    href: 'https://www.youtube.com/watch?v=1',
    cueStartMs: start,
    cueEndMs: start + 1500,
    sentence: '$wordの文。',
    fields: <String, String>{'expression': word},
  );

  Future<void> open(WidgetTester tester, {List<int>? changes}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => WebMineQueueDialog(
                store: store,
                bookUid: 'video/stream/1',
                startLabel: (int pending) => 'start $pending',
                onChanged: () => changes?.add(1),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(Duration.zero);
    await tester.pumpAndSettle();
  }

  late int dup;
  late int unreachable;
  late int pending;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    store = WebMineQueueStore(db);
  });

  tearDown(() => db.close());

  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      dup = await enqueue(store, '重複', 1000);
      unreachable = await enqueue(store, '届かない', 2000);
      pending = await enqueue(store, '待つ', 3000);
      await store.markFailed(dup, WebMineQueueStore.duplicateError);
      await store.markFailed(unreachable, 'navigate_timeout');
    });
  }

  testWidgets('失败行红字带本地化原因，待办行照常列出；「开始制卡」按待办张数给文字', (
    WidgetTester tester,
  ) async {
    await seed(tester);
    await open(tester);
    expect(find.text('重複'), findsOneWidget);
    expect(find.text('届かない'), findsOneWidget);
    expect(find.text('待つ'), findsOneWidget);
    expect(
      find.text(
        t.video_mine_queue_failed(reason: t.video_mine_queue_reason_duplicate),
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        t.video_mine_queue_failed(
          reason: t.web_video_mine_queue_reason_unreachable,
        ),
      ),
      findsOneWidget,
    );
    // 只有失败行有单行重试；每行都能移除。
    expect(find.byKey(ValueKey<String>('web-mine-queue-retry-$dup')), findsOne);
    expect(
      find.byKey(ValueKey<String>('web-mine-queue-retry-$pending')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey<String>('web-mine-queue-remove-$pending')),
      findsOne,
    );
    expect(find.text('start 1'), findsOneWidget);
  });

  testWidgets('「全部重试」排回非重复的失败行、跳过重复卡；单行重试把重复卡也排回', (WidgetTester tester) async {
    await seed(tester);
    final List<int> changes = <int>[];
    await open(tester, changes: changes);

    await tester.tap(
      find.byKey(const ValueKey<String>('web-mine-queue-retry-all')),
    );
    await tester.pumpAndSettle();
    expect(changes, hasLength(1));
    expect(find.text('start 2'), findsOneWidget);
    final List<WebMineQueueRow> failed = (await tester.runAsync(
      () => store.failed('video/stream/1'),
    ))!;
    expect(failed.single.id, dup);
    // 只剩重复卡失败：「全部重试」灰掉（无事可做）。
    final FushiTextButton retryAll = tester.widget<FushiTextButton>(
      find.byKey(const ValueKey<String>('web-mine-queue-retry-all')),
    );
    expect(retryAll.onPressed, isNull);

    await tester.tap(find.byKey(ValueKey<String>('web-mine-queue-retry-$dup')));
    await tester.pumpAndSettle();
    expect(find.text('start 3'), findsOneWidget);
    expect(
      await tester.runAsync(() => store.failed('video/stream/1')),
      isEmpty,
    );
  });

  testWidgets('移除一行出表；「开始制卡」关列表并返回 true', (WidgetTester tester) async {
    await seed(tester);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              result = await showWebMineQueueDialogForTest(context, store);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(ValueKey<String>('web-mine-queue-remove-$unreachable')),
    );
    await tester.pumpAndSettle();
    expect(find.text('届かない'), findsNothing);
    expect(await tester.runAsync(() => store.openCount('video/stream/1')), 2);

    await tester.tap(
      find.byKey(const ValueKey<String>('web-mine-queue-start')),
    );
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(WebMineQueueDialog), findsNothing);
  });
}

Future<bool?> showWebMineQueueDialogForTest(
  BuildContext context,
  WebMineQueueStore store,
) => showDialog<bool>(
  context: context,
  builder: (_) => WebMineQueueDialog(
    store: store,
    bookUid: 'video/stream/1',
    startLabel: (int pending) => 'start $pending',
  ),
);
