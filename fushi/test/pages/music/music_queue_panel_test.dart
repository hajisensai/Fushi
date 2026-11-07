import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/pages/implementations/music/music_queue_panel.dart';
import 'package:material_ui/material_ui.dart';

/// 只记下一首的后端替身（面板测的是界面 → 引擎命令，后端同步由引擎测试覆盖）。
class _Backend implements MusicOutputBackend {
  final StreamController<MusicBackendEvent> controller =
      StreamController<MusicBackendEvent>.broadcast(sync: true);
  MusicPlayItem? next;

  @override
  Stream<MusicBackendEvent> get events => controller.stream;

  @override
  Future<void> applySettings(MusicOutputSettings s) async {}

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
    Duration startAt = Duration.zero,
  }) async => this.next = next;

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async => this.next = next;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => controller.close();

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}

MusicPlayItem _item(String uid) => MusicPlayItem(
  trackUid: uid,
  path: '/m/$uid.flac',
  title: 'Song $uid',
  artist: 'Singer',
  durationMs: 600000,
);

String _uids(MusicPlayerEngine e) =>
    e.queue.map((MusicPlayItem i) => i.trackUid).join();

Finder _row(String uid) =>
    find.byKey(ValueKey<String>('music_queue_row_$uid#0'));

void main() {
  late _Backend backend;
  late MusicPlayerEngine engine;

  setUp(() {
    backend = _Backend();
    engine = MusicPlayerEngine(
      backendFactory: () => backend,
      random: Random(1),
    );
  });

  tearDown(() => engine.dispose());

  Future<void> pumpPanel(WidgetTester tester, {bool sidebar = false}) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: MusicQueuePanel(engine: engine, sidebar: sidebar),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> start(String uids, {int startIndex = 0}) => engine.playQueue(
    <MusicPlayItem>[for (final String u in uids.split('')) _item(u)],
    startIndex: startIndex,
    source: const MusicPlaySource.album('al', title: 'Blue Letter'),
  );

  testWidgets('顶部：曲数 · 总时长 · 来源；当前曲高亮，后面是接下来的曲目', (WidgetTester tester) async {
    await start('abcd', startIndex: 1);
    await engine.playNext(<MusicPlayItem>[_item('x')]);
    await pumpPanel(tester);

    expect(
      find.text(
        t.music_queue_summary_source(
          count: 5,
          duration: t.music_queue_duration_minutes(minutes: 50),
          source: 'Blue Letter',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('music_queue_current')),
        matching: find.text('Song b'),
      ),
      findsOneWidget,
    );
    // 当前曲之前的（已播过的 a）不列出。
    expect(_row('a'), findsNothing);
    expect(_row('x'), findsOneWidget);
    expect(_row('c'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('x'),
        matching: find.byKey(
          const ValueKey<String>('music_queue_play_next_tag'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('music_queue_play_next_tag')),
      findsOneWidget,
      reason: '只有「下一首播放」插进来的那首带标签',
    );
  });

  testWidgets('触屏点一行跳到该曲', (WidgetTester tester) async {
    await start('abc');
    await pumpPanel(tester);
    await tester.tap(_row('c'));
    await tester.pumpAndSettle();
    expect(engine.current?.trackUid, 'c');
  });

  testWidgets('左滑移出，底部提示可撤销；撤销放回原位置', (WidgetTester tester) async {
    await start('abcd');
    await pumpPanel(tester);
    await tester.drag(_row('c'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(_uids(engine), 'abd');
    expect(backend.next?.trackUid, 'b');
    expect(find.text(t.music_queue_removed(title: 'Song c')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('music_queue_undo')));
    await tester.pumpAndSettle();
    expect(_uids(engine), 'abcd');
    expect(
      find.byKey(const ValueKey<String>('music_queue_undo_bar')),
      findsNothing,
    );
  });

  testWidgets('桌面：单击选中、Delete 移出；双击跳播；悬停出现移出按钮', (WidgetTester tester) async {
    await start('abcde');
    await pumpPanel(tester, sidebar: true);

    // 悬停出现行内移出按钮。
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(_row('e')));
    await tester.pumpAndSettle();
    final Finder remove = find.descendant(
      of: _row('e'),
      matching: find.byKey(const ValueKey<String>('music_queue_row_remove')),
    );
    expect(remove, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('music_queue_row_remove')),
      findsOneWidget,
      reason: '只有悬停的那一行出现',
    );
    await mouse.moveTo(tester.getCenter(remove));
    await tester.pump();
    await mouse.down(tester.getCenter(remove));
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.removePointer();
    expect(_uids(engine), 'abcd');

    // 单击只选中，Delete 移出选中行。
    await tester.tap(_row('b'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.current?.trackUid, 'a', reason: '鼠标单击只选中');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(_uids(engine), 'acd');

    // 双击跳播。
    await tester.tap(_row('d'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_row('d'), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(engine.current?.trackUid, 'd');
  });

  testWidgets('拖手柄排序：拖动中显示插入线，松手按落点挪动', (WidgetTester tester) async {
    await start('abcd');
    await pumpPanel(tester);
    final Offset from = tester.getCenter(
      find.descendant(of: _row('d'), matching: find.byType(Draggable<int>)),
    );
    final Offset rowB = tester.getTopLeft(_row('b'));
    final TestGesture g = await tester.startGesture(from);
    await g.moveBy(const Offset(0, -20));
    await tester.pump();
    // 拖到 b 的上半截：插到 b 之前。
    await g.moveTo(Offset(from.dx, rowB.dy + 4));
    await tester.pump();
    await g.moveTo(Offset(from.dx, rowB.dy + 2));
    await tester.pump();
    expect(engine.queue.length, 4);
    await g.up();
    await tester.pumpAndSettle();
    expect(_uids(engine), 'adbc');
    expect(backend.next?.trackUid, 'd');
  });

  testWidgets('清空：只留当前曲', (WidgetTester tester) async {
    await start('abc', startIndex: 1);
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey<String>('music_queue_clear')));
    await tester.pumpAndSettle();
    expect(_uids(engine), 'b');
    expect(find.text(t.music_queue_up_next_empty), findsOneWidget);
  });

  testWidgets('外部队列（Apple Music 电台）：编辑入口全部禁用', (WidgetTester tester) async {
    final MusicPlayerEngine old = engine;
    addTearDown(old.dispose);
    engine = MusicPlayerEngine(
      backendFactory: () => backend,
      capabilitiesOf: (MusicPlayItem i) => i.trackUid == 'a'
          ? const MusicBackendCapabilities(
              signalPath: false,
              abLoop: false,
              externalQueue: true,
            )
          : MusicBackendCapabilities.full,
    );
    await start('abc');
    await pumpPanel(tester);
    expect(find.text(t.music_queue_external_locked), findsOneWidget);
    expect(find.byType(Draggable<int>), findsNothing);
    expect(find.byType(Dismissible), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('music_queue_clear')));
    await tester.pumpAndSettle();
    expect(_uids(engine), 'abc');
  });
}
