import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
    late VideoMineQueue queue;
    await tester.runAsync(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      tmp = await Directory.systemTemp.createTemp('mine_queue_dialog');
      queue = VideoMineQueue(db: db, root: Directory('${tmp.path}/q'));
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
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('走る'), findsOneWidget);
    expect(find.text('跳ぶ'), findsOneWidget);

    // 删掉点错的那张。
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('走る'), findsNothing);
    expect(find.text('跳ぶ'), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(commits, 1);
    expect(returned?.succeeded, 1);
    expect(find.byType(VideoMineQueueDialog), findsNothing);
  });
}
