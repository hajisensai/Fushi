import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_live_chat_panel.dart';
import 'package:fushi/src/media/video/video_live_chat_replay.dart';
import 'package:fushi_engine/media/video/youtube_live_chat_replay.dart';
import 'package:material_ui/material_ui.dart';

/// 拍板台 zTedU_pOQF 方案 b：跟随播放的聊天回放栏。

YoutubeChatMessage _msg(String id, int offsetMs, String text) =>
    YoutubeChatMessage(id: id, offsetMs: offsetMs, author: '@$id', text: text);

class _Harness {
  _Harness(this.pages);

  /// 依次回给每次取页请求的页（用完后再请求就挂起）。
  final List<YoutubeChatReplayPage> pages;
  final List<int> requestedOffsets = <int>[];
  final ValueNotifier<int?> position = ValueNotifier<int?>(0);
  bool failNext = false;

  late final VideoLiveChatReplay chat = VideoLiveChatReplay(
    videoId: 'vid',
    entryContinuation: 'ENTRY',
    position: position,
    fetch: (String continuation, int offsetMs) {
      requestedOffsets.add(offsetMs);
      if (failNext) {
        failNext = false;
        return Future<YoutubeChatReplayPage>.error(StateError('offline'));
      }
      if (pages.isEmpty) return Completer<YoutubeChatReplayPage>().future;
      return Future<YoutubeChatReplayPage>.value(pages.removeAt(0));
    },
  );
}

YoutubeChatReplayPage _page(List<YoutubeChatMessage> messages) =>
    YoutubeChatReplayPage(
      messages: messages,
      nextContinuation: null,
      seekContinuation: 'SEEK',
    );

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  bool showAuthor = true,
  void Function(YoutubeChatMessage, int, Rect)? onLookup,
  VideoLiveChatHitTester? hitTester,
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(400, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => VideoLiveChatPanel(
            chat: h.chat,
            onLookup: onLookup ?? (YoutubeChatMessage _, int _, Rect _) {},
            colorScheme: Theme.of(context).colorScheme,
            width: 360,
            showAuthor: showAuthor,
            hitTester: hitTester,
            onClose: onClose,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('videoLiveChatShownUntilMs：跟随 = 播放头；冻结 = 两者取早', () {
    expect(
      videoLiveChatShownUntilMs(
        positionMs: 5000,
        following: true,
        frozenAtMs: 1000,
      ),
      5000,
    );
    expect(
      videoLiveChatShownUntilMs(
        positionMs: 5000,
        following: false,
        frozenAtMs: 1000,
      ),
      1000,
    );
    expect(
      videoLiveChatShownUntilMs(
        positionMs: 500,
        following: false,
        frozenAtMs: 1000,
      ),
      500,
    );
  });

  testWidgets('挂载即按播放位置取页；只列出已发出的消息，当前时刻的高亮', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[
        _msg('a', 1000, 'マイクラ配信待ってた'),
        _msg('b', 9000, '草'),
        _msg('c', 30000, '未来のメッセージ'),
      ]),
    ]);
    h.position.value = 10000;
    await _pump(tester, h);
    expect(h.requestedOffsets.first, 10000);
    expect(find.text('マイクラ配信待ってた', findRichText: true), findsOneWidget);
    expect(find.text('草', findRichText: true), findsOneWidget);
    expect(find.text('未来のメッセージ', findRichText: true), findsNothing);
    expect(find.text('@a'), findsOneWidget);

    // 播放到 31s：第三条出现。
    h.position.value = 31000;
    await tester.pumpAndSettle();
    expect(find.text('未来のメッセージ', findRichText: true), findsOneWidget);
  });

  testWidgets('关掉「显示用户名」后不出发送者', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[_msg('a', 1000, 'こんにちは')]),
    ]);
    h.position.value = 5000;
    await _pump(tester, h, showAuthor: false);
    expect(find.text('こんにちは', findRichText: true), findsOneWidget);
    expect(find.text('@a'), findsNothing);
  });

  testWidgets('点消息里的字查词（不必暂停），barrier 句柄能反查到同一条', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[_msg('a', 1000, '草')]),
    ]);
    h.position.value = 2000;
    final List<(String, int)> lookups = <(String, int)>[];
    final VideoLiveChatHitTester hitTester = VideoLiveChatHitTester();
    await _pump(
      tester,
      h,
      hitTester: hitTester,
      onLookup: (YoutubeChatMessage m, int index, Rect _) =>
          lookups.add((m.id, index)),
    );
    final Finder text = find.text('草', findRichText: true);
    final Offset center = tester.getCenter(text);
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(lookups, <(String, int)>[('a', 0)]);
    final LiveChatHit? hit = hitTester.hitTest(center, exactOnly: true);
    expect(hit?.message.id, 'a');
    expect(hit?.graphemeIndex, 0);
  });

  testWidgets('往上翻就冻结列表并出「回到当前」；点它回到跟随', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[
        for (int i = 0; i < 60; i++) _msg('m$i', i * 1000, 'メッセージ$i'),
      ]),
    ]);
    h.position.value = 40000;
    await _pump(tester, h);
    final Finder jump = find.byKey(
      const ValueKey<String>('video-live-chat-jump-to-now'),
    );
    expect(find.text('メッセージ40', findRichText: true), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey<String>('video-live-chat-list')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<IgnorePointer>(
        find.ancestor(of: jump, matching: find.byType(IgnorePointer)).first,
      ),
      isA<IgnorePointer>().having(
        (IgnorePointer w) => w.ignoring,
        'ignoring',
        false,
      ),
    );
    // 冻结期间播放继续，新消息不往列表里插。
    h.position.value = 50000;
    await tester.pumpAndSettle();
    expect(find.text('メッセージ50', findRichText: true), findsNothing);

    await tester.tap(jump);
    await tester.pumpAndSettle();
    expect(find.text('メッセージ50', findRichText: true), findsOneWidget);
  });

  testWidgets('取页失败显示「重试」，点了重新取', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[_msg('a', 1000, 'やっと')]),
    ])..failNext = true;
    h.position.value = 2000;
    await _pump(tester, h);
    expect(find.text(t.video_live_chat_failed), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-live-chat-retry')),
    );
    await tester.pumpAndSettle();
    expect(h.requestedOffsets, hasLength(2));
    expect(find.text('やっと', findRichText: true), findsOneWidget);
  });

  testWidgets('面板卸载后不再按播放位置取页', (WidgetTester tester) async {
    final _Harness h = _Harness(<YoutubeChatReplayPage>[
      _page(<YoutubeChatMessage>[_msg('a', 1000, 'x')]),
    ]);
    h.position.value = 2000;
    bool closed = false;
    await _pump(tester, h, onClose: () => closed = true);
    await tester.tap(
      find.byKey(const ValueKey<String>('video-live-chat-close')),
    );
    expect(closed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    final int before = h.requestedOffsets.length;
    h.position.value = 9999999;
    await tester.pump();
    expect(h.requestedOffsets, hasLength(before));
    expect(h.chat.active, isFalse);
  });
}
