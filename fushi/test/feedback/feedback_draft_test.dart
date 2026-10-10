// 提交页草稿：写到一半离开（返回 / 切走 / 进后台）就落盘，下次打开自动恢复并可丢弃；
// 输入防抖保存；表单清空时草稿也删掉。草稿在 `<数据根>/feedback/draft/`，截图各存一个文件。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_draft_store.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_page.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory root;
  late FeedbackService service;
  late LeaderboardService board;
  late ProviderContainer container;
  final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 4, height: 4)),
  );
  final Uint8List autoShot = Uint8List.fromList(
    img.encodePng(img.Image(width: 2, height: 2)),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_draft_');
    board = LeaderboardService(
      database: () => throw StateError('no database in UI tests'),
      supportRoot: () async => root,
      profileId: () async => 1,
      httpClientFactory: () async =>
          MockClient((http.Request _) async => http.Response('{}', 404)),
      defaultBaseUrl: Uri.parse('https://rank.example'),
      isbnBackfill: (FushiDatabase _) async => 0,
    );
    service = FeedbackService(
      supportRoot: () async => root,
      client: board.feedbackClient,
      meta: () async => <String, Object?>{},
      logText: () => '',
      logEncoder: (String s) => Uint8List.fromList(utf8.encode(s)),
    );
    // 一个容器跨多次 pumpWidget：页面关掉再打开时服务不随 ProviderScope 一起被 dispose。
    container = ProviderContainer(
      overrides: <Override>[
        leaderboardServiceProvider.overrideWith((Ref _) => board),
        feedbackServiceProvider.overrideWith((Ref _) => service),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          FushiChannels.clipboardImage,
          (MethodCall call) async => <String, Object?>{'bytes': png},
        );
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.clipboardImage, null);
    root.deleteSync(recursive: true);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
    container: container,
    child: TranslationProvider(child: MaterialApp(home: child)),
  );

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// 真实 IO（草稿读写、图片压缩 isolate）要在真实 zone 里走完。
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 300 && (i < 5 || !done()); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<FeedbackComposeDraft?> readDraft(WidgetTester tester) async => tester
      .runAsync<FeedbackComposeDraft?>(() => FeedbackDraftStore(root).read());

  bool draftOnDisk() =>
      File('${root.path}/feedback/draft/draft.json').existsSync();

  Finder key(String k) => find.byKey(ValueKey<String>(k));

  int shotCount() => <int>[
    0,
    1,
    2,
  ].where((int i) => key('feedback-shot-$i').evaluate().isNotEmpty).length;

  testWidgets('写到一半返回：草稿落盘（文字 / 分类 / 勾选 / 截图）；再打开自动恢复；丢弃回到空表单', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(
      wrap(FeedbackComposePage(initialScreenshot: autoShot)),
    );
    await settle(tester, () => true);
    await tester.tap(key('feedback-category-suggestion'));
    await tester.enterText(key('feedback-title'), '想要深色图标');
    await tester.enterText(key('feedback-body'), '写了一半');
    await tester.enterText(key('feedback-contact'), 'tg @me');
    await tester.tap(key('feedback-include-logs'));
    await tester.tap(key('feedback-paste-image'));
    await settle(tester, () => shotCount() == 2);
    expect(shotCount(), 2);

    // 离开页面（不等防抖）。
    await tester.pumpWidget(const SizedBox());
    await settle(tester, draftOnDisk);
    final FeedbackComposeDraft? saved = await readDraft(tester);
    expect(saved, isNotNull);
    expect(saved!.title, '想要深色图标');
    expect(saved.body, '写了一半');
    expect(saved.contact, 'tg @me');
    expect(saved.category, FeedbackCategory.suggestion);
    expect(saved.includeLogs, isFalse);
    expect(saved.includeDevice, isTrue);
    expect(saved.screenshots, hasLength(2));
    expect(saved.screenshots.first, autoShot);
    expect(
      Directory(
        '${root.path}/feedback/draft',
      ).listSync().whereType<File>().where((File f) => f.path.endsWith('.img')),
      hasLength(2),
      reason: '截图各存一个文件',
    );

    // 再打开（带一张新的自动截图）：恢复草稿，本次的自动截图接在草稿截图后面
    // （BUG-3240：以前被草稿整个替换掉，那一刻的现场就丢了）。
    final Uint8List newAuto = Uint8List.fromList(
      img.encodePng(img.Image(width: 3, height: 3)),
    );
    await tester.pumpWidget(
      wrap(FeedbackComposePage(key: UniqueKey(), initialScreenshot: newAuto)),
    );
    await settle(
      tester,
      () => key('feedback-draft-restored').evaluate().isNotEmpty,
    );
    expect(key('feedback-draft-restored'), findsOneWidget);
    expect(find.text('想要深色图标'), findsOneWidget);
    expect(find.text('写了一半'), findsOneWidget);
    expect(find.text('tg @me'), findsOneWidget);
    expect(shotCount(), 3);
    expect(
      tester
          .widget<Image>(
            find.descendant(
              of: key('feedback-shot-2'),
              matching: find.byType(Image),
            ),
          )
          .image,
      isA<MemoryImage>().having((MemoryImage m) => m.bytes, 'bytes', newAuto),
    );
    expect(
      tester.widget<FushiSwitchListTile>(key('feedback-include-logs')).value,
      isFalse,
    );

    await tester.tap(key('feedback-draft-discard'));
    await settle(tester, () => !draftOnDisk());
    expect(draftOnDisk(), isFalse);
    expect(key('feedback-draft-restored'), findsNothing);
    expect(find.text('想要深色图标'), findsNothing);
    expect(shotCount(), 1, reason: '回到刚打开的样子：只剩本次的自动截图');
  });

  testWidgets('BUG-3241 内容没变时失焦 / 进后台不重写草稿（桌面主窗每次失焦都会触发）', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    await tester.pumpWidget(
      wrap(FeedbackComposePage(initialScreenshot: autoShot)),
    );
    await settle(tester, () => true);
    await tester.enterText(key('feedback-body'), '写了一半');
    await settle(tester, draftOnDisk);
    expect((await readDraft(tester))!.body, '写了一半');

    // 草稿目录里放一个记号：整份重写（先写 draft.tmp/ 再整目录替换）会把它冲掉。
    final File marker = File('${root.path}/feedback/draft/marker');
    marker.writeAsStringSync('x');
    Future<void> blurAndBack() async {
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settle(tester, () => false);
    }

    await blurAndBack();
    await blurAndBack();
    expect(marker.existsSync(), isTrue, reason: '内容没变，不该重写草稿');

    // 内容变了：失焦照常立刻落盘。
    await tester.enterText(key('feedback-body'), '写了一半，又补一句');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await settle(tester, () => !marker.existsSync());
    expect(marker.existsSync(), isFalse);
    expect((await readDraft(tester))!.body, '写了一半，又补一句');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    // 空表单：草稿删掉后再失焦也不再碰磁盘（不反复 clear）。
    await tester.enterText(key('feedback-body'), '');
    await settle(tester, () => !draftOnDisk());
    expect(draftOnDisk(), isFalse);
  });

  testWidgets('输入防抖保存；进后台立刻保存；内容清空时草稿删掉', (WidgetTester tester) async {
    tallView(tester);
    await tester.pumpWidget(wrap(const FeedbackComposePage()));
    await settle(tester, () => true);
    await tester.enterText(key('feedback-body'), '第一句');
    // 防抖：不离开页面，过一会儿也会落盘。
    await settle(tester, draftOnDisk);
    expect((await readDraft(tester))!.body, '第一句');

    await tester.enterText(key('feedback-body'), '第一句，第二句');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // 不推进假时钟（防抖定时器不会触发），只让真实 IO 走完：落盘只能来自进后台。
    bool flushed() {
      try {
        return draftOnDisk() &&
            File(
              '${root.path}/feedback/draft/draft.json',
            ).readAsStringSync().contains('第二句');
      } on FileSystemException {
        // Windows 上正在替换目录时读会撞共享冲突：还没写完，下一轮再看。
        return false;
      }
    }

    for (int i = 0; i < 200 && !flushed(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect((await readDraft(tester))!.body, '第一句，第二句');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.enterText(key('feedback-body'), '');
    await settle(tester, () => !draftOnDisk());
    expect(draftOnDisk(), isFalse);
  });
}
