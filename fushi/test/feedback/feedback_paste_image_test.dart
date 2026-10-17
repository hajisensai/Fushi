// 提交页粘贴截图：显式按钮、桌面 Ctrl+V、描述框长按菜单都从剪贴板收图；复制的图片
// 文件按扩展名收、非图片跳过；剪贴板没图 / 满了给提示；沿用 3 张上限。
//
// 剪贴板经本仓自有通道 `clipboard_image` 的 `readImage`（五端原生实现），这里在通道
// 层打桩。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_page.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory root;
  late Object? clipboard;
  late int reads;

  final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 4, height: 4)),
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_paste_');
    clipboard = null;
    reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.clipboardImage, (
          MethodCall call,
        ) async {
          if (call.method != 'readImage') return null;
          reads++;
          return clipboard;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(FushiChannels.clipboardImage, null);
    root.deleteSync(recursive: true);
  });

  Widget wrap(Widget child) {
    final LeaderboardService board = LeaderboardService(
      database: () => throw StateError('no database in UI tests'),
      supportRoot: () async => root,
      profileId: () async => 1,
      httpClientFactory: () async =>
          MockClient((http.Request _) async => http.Response('{}', 404)),
      defaultBaseUrl: Uri.parse('https://rank.example'),
      isbnBackfill: (FushiDatabase _) async => 0,
    );
    final FeedbackService feedback = FeedbackService(
      supportRoot: () async => root,
      client: board.feedbackClient,
      meta: () async => <String, Object?>{},
      logText: () => '',
      logEncoder: (String s) => Uint8List.fromList(utf8.encode(s)),
    );
    return ProviderScope(
      overrides: <Override>[
        leaderboardServiceProvider.overrideWith((Ref _) => board),
        feedbackServiceProvider.overrideWith((Ref _) => feedback),
      ],
      child: TranslationProvider(child: MaterialApp(home: child)),
    );
  }

  void tallView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// 剪贴板读取后的解码 / 压缩跑在后台 isolate，要让真实 zone 走完。
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 300 && (i < 5 || !done()); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  int shotCount() => <int>[0, 1, 2, 3]
      .where(
        (int i) => find
            .byKey(ValueKey<String>('feedback-shot-$i'))
            .evaluate()
            .isNotEmpty,
      )
      .length;

  /// 桌面粘贴快捷键：macOS 是 Cmd+V，其余 Ctrl+V（跟随测试宿主平台）。
  Future<void> pressPaste(WidgetTester tester) async {
    final LogicalKeyboardKey modifier = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(modifier);
  }

  final Finder pasteButton = find.byKey(
    const ValueKey<String>('feedback-paste-image'),
  );

  testWidgets('粘贴提示按平台：桌面提快捷键（macOS ⌘V），手机提长按菜单', (WidgetTester tester) async {
    tallView(tester);
    final Finder hint = find.byKey(
      const ValueKey<String>('feedback-paste-hint'),
    );
    String hintText() => tester.widget<Text>(hint).data!;
    for (final (TargetPlatform platform, String expected)
        in <(TargetPlatform, String)>[
          (TargetPlatform.android, t.feedback_compose_paste_hint_mobile),
          (TargetPlatform.iOS, t.feedback_compose_paste_hint_mobile),
          (
            TargetPlatform.windows,
            t.feedback_compose_paste_hint_desktop(key: 'Ctrl+V'),
          ),
          (
            TargetPlatform.macOS,
            t.feedback_compose_paste_hint_desktop(key: '⌘V'),
          ),
        ]) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(wrap(FeedbackComposePage(key: UniqueKey())));
      expect(hintText(), expected, reason: '$platform');
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('「粘贴图片」按钮：剪贴板里的截图位图加进附件', (WidgetTester tester) async {
    tallView(tester);
    clipboard = <String, Object?>{'bytes': png};
    await tester.pumpWidget(wrap(const FeedbackComposePage()));
    expect(shotCount(), 0);
    expect(
      find.byKey(const ValueKey<String>('feedback-paste-hint')),
      findsOneWidget,
    );

    await tester.tap(pasteButton);
    await settle(tester, () => shotCount() == 1);
    expect(reads, 1);
    expect(shotCount(), 1);
  });

  testWidgets('桌面 Ctrl+V：复制的图片文件收进来，非图片文件跳过；不吃掉按键', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final File shot = File('${root.path}/截图.PNG')..writeAsBytesSync(png);
    final File note = File('${root.path}/notes.txt')..writeAsStringSync('hi');
    clipboard = <String, Object?>{
      'paths': <String>[note.path, shot.path],
    };
    await tester.pumpWidget(wrap(const FeedbackComposePage()));
    await tester.tap(find.byKey(const ValueKey<String>('feedback-body')));
    await tester.pump();

    await pressPaste(tester);
    await settle(tester, () => shotCount() == 1);
    expect(reads, 1);
    expect(shotCount(), 1);

    // 不带 Ctrl 的 V 是打字，不去读剪贴板。
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(reads, 1);
  });

  testWidgets('Ctrl+V 剪贴板里只有文字：不打扰；按钮点了才提示「没有图片」', (WidgetTester tester) async {
    tallView(tester);
    await tester.pumpWidget(wrap(const FeedbackComposePage()));
    await pressPaste(tester);
    await settle(tester, () => reads == 1);
    expect(find.text(t.feedback_compose_paste_none), findsNothing);

    await tester.tap(pasteButton);
    await settle(
      tester,
      () => find.text(t.feedback_compose_paste_none).evaluate().isNotEmpty,
    );
    expect(find.text(t.feedback_compose_paste_none), findsOneWidget);
    expect(shotCount(), 0);
  });

  testWidgets('描述框长按菜单有「粘贴图片」，点了把图加进来', (WidgetTester tester) async {
    tallView(tester);
    clipboard = <String, Object?>{'bytes': png};
    await tester.pumpWidget(wrap(const FeedbackComposePage()));
    final Finder body = find.byKey(const ValueKey<String>('feedback-body'));
    await tester.tap(body);
    await tester.pump();
    final EditableTextState editable = tester.state<EditableTextState>(
      find.descendant(of: body, matching: find.byType(EditableText)),
    );
    expect(editable.showToolbar(), isTrue);
    await tester.pumpAndSettle();

    // 一个在附件区方块上，一个在菜单里。
    final Finder labels = find.text(t.feedback_compose_paste_image);
    expect(labels, findsNWidgets(2));
    await tester.tap(
      find.descendant(
        of: find.byType(AdaptiveTextSelectionToolbar),
        matching: labels,
      ),
    );
    await settle(tester, () => shotCount() == 1);
    expect(shotCount(), 1);
  });

  testWidgets('沿用 3 张上限：粘到满为止，满了按钮隐藏、Ctrl+V 有图时提示已满', (
    WidgetTester tester,
  ) async {
    tallView(tester);
    final List<String> paths = <String>[
      for (int i = 0; i < 4; i++)
        (File('${root.path}/s$i.png')..writeAsBytesSync(png)).path,
    ];
    clipboard = <String, Object?>{'bytes': png, 'paths': paths};
    await tester.pumpWidget(wrap(FeedbackComposePage(initialScreenshot: png)));
    expect(shotCount(), 1);

    await tester.tap(pasteButton);
    await settle(tester, () => shotCount() == 3);
    expect(shotCount(), 3, reason: '剪贴板 5 张，只收到满 3 张');
    expect(pasteButton, findsNothing);
    expect(
      find.byKey(const ValueKey<String>('feedback-paste-hint')),
      findsNothing,
    );

    await pressPaste(tester);
    final String full = t.feedback_compose_paste_full(max: 3);
    await settle(tester, () => find.text(full).evaluate().isNotEmpty);
    expect(find.text(full), findsOneWidget);
    expect(shotCount(), 3);
  });
}
