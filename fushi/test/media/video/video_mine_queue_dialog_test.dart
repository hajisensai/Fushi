import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mine_queue_dialog.dart';
import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult;
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  test('MinePopupResult.queued 回包带 queued，popup.js 据此画「已加入」', () {
    expect(const MinePopupResult.queued().toJson(), <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
      'queued': true,
    });
    // 其它结果不带这个字段（popup.js 对缺字段与 false 同解）。
    expect(
      const MinePopupResult(ankiConnect: true, noteId: 3).toJson(),
      isNot(contains('queued')),
    );
  });

  testWidgets('待制卡列表：列出暂存卡、可删除、全部写入后关窗并交回汇总', (WidgetTester tester) async {
    late FushiDatabase db;
    late Directory tmp;
    late _RealZoneDiscardQueue queue;
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      tmp = await Directory.systemTemp.createTemp('mine_queue_dialog');
      queue = _RealZoneDiscardQueue(db: db, root: Directory('${tmp.path}/q'));
      for (final String word in <String>['走る', '跳ぶ']) {
        final File audio = File('${tmp.path}/a.aac')..writeAsStringSync(word);
        await queue.stage(
          bookUid: 'remote/1',
          videoKey: 'remote/1#0',
          fields: <String, String>{'expression': word},
          context: AnkiMiningContext(
            sentence: '$wordの文。',
            sentenceAudioPath: audio.path,
            source: AnkiMiningSource.video,
          ),
          meta: const VideoMineStagedMeta(),
        );
      }
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await db.close();
        if (tmp.existsSync()) await tmp.delete(recursive: true);
      });
    });

    VideoMineCommitSummary? returned;
    int commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              returned = await showDialog<VideoMineCommitSummary>(
                context: context,
                builder: (_) => VideoMineQueueDialog(
                  queue: queue,
                  bookUid: 'remote/1',
                  commit: (void Function(int, int) onProgress) async {
                    commits++;
                    onProgress(1, 1);
                    return const VideoMineCommitSummary(
                      succeeded: 1,
                      failed: 0,
                    );
                  },
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    // 首帧建出弹窗、initState 起 _reload（只读内存库，全在 fake zone 的微任务里）；
    // 第二帧画出读回来的行。这一段没有真实 IO，不需要等真实时间。
    await tester.pump();
    await tester.pump(Duration.zero);
    expect(find.text('走る'), findsOneWidget);
    expect(find.text('跳ぶ'), findsOneWidget);

    // 删掉点错的那张。discard 要删暂存目录（真实文件 IO）：等它真正完成，而不是
    // 赌一段真实时间够它跑完（旧写法 100 ms，负载高的宿主上不够，删掉的卡还在树上）。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    expect(queue.discards, hasLength(1));
    await tester.runAsync(() => queue.discards.single);
    // discard 回来后弹窗 _reload 的查询在 fake zone 里：elapse 冲刷完再出帧。
    await tester.pump(Duration.zero);
    expect(find.text('走る'), findsNothing);
    expect(find.text('跳ぶ'), findsOneWidget);

    // 写入走注入的 commit（无真实 IO），pumpAndSettle 即可走完进度、关窗与转场。
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(commits, 1);
    expect(returned?.succeeded, 1);
    expect(find.byType(VideoMineQueueDialog), findsNothing);
  });
}

/// 让 [discard] 在**真实事件循环**里跑，并把它的 Future 交给测试等。
///
/// 弹窗的删除按钮在 widget 测试的 fake-async zone 里触发 [VideoMineQueue.discard]，
/// 它要 `Directory.delete` 暂存目录：真实 IO 的回包只能在真实事件循环里到达，而 fake
/// zone 里起的 Future 又要等下一次 fake 冲刷才会完成——测试既不能在 `runAsync` 里等
/// 一个 fake zone 的 Future（等不到冲刷，死等），也不该赌一段真实时间。这里把 discard
/// 整段放进根 zone：它的完成只取决于真实 IO 本身，测试在 `runAsync` 里精确等到它；
/// 弹窗那头 `await` 它的续体仍落回 fake zone，由随后的 pump 冲刷。
class _RealZoneDiscardQueue extends VideoMineQueue {
  _RealZoneDiscardQueue({required super.db, required super.root});

  final List<Future<void>> discards = <Future<void>>[];

  @override
  Future<void> discard(int id) {
    final Future<void> done = Zone.root.run<Future<void>>(
      () => super.discard(id),
    );
    discards.add(done);
    return done;
  }
}
