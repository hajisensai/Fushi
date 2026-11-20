// FeedbackService.adoptSpool 并入另一处数据根的待传附件时必须整项搬运：样本文件的
// `.type` / `.name` 旁注、视频的 `.type` 旁注都要跟着本体过来。只搬本体字节时，样本文件
// 上传会因缺原文件名被当损坏丢掉，视频的 MIME 退成 application/octet-stream。
//
// 今天的唯一来源（启动即闪退的报告）草稿不带视频 / 样本文件，这里直接构造 spool 目录，
// 守住 adoptSpool「整项并入」的契约。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_adopt_');
  });
  tearDown(() => root.deleteSync(recursive: true));

  FeedbackService service(Directory dataRoot) => FeedbackService(
    supportRoot: () async => dataRoot,
    client: () => LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async =>
          MockClient((http.Request r) async => http.Response('', 500)),
    ),
    meta: () async => <String, Object?>{'platform': 'test'},
    logText: ({required bool includeDebugLog}) => 'log',
    logEncoder: (String s) => Uint8List(0),
  );

  test('并入 spool：样本文件与视频的旁注跟本体一起过来', () async {
    const String id = 'abcdefghij';
    final Directory spool = Directory(p.join(root.path, 'spool'))..createSync();
    final Directory data = Directory(p.join(root.path, 'data'))..createSync();

    final FeedbackPendingStore from = FeedbackPendingStore(spool);
    final File sample = File(p.join(root.path, 'repro.md'))
      ..writeAsStringSync('# 步骤\n');
    await from.copyFile(id, 'f0', sample, name: 'repro.md');
    final File video = File(p.join(root.path, 'clip.mp4'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await from.putFile(id, 'v0', video, contentType: 'video/mp4');
    await from.put(id, 's0', <int>[9, 9]);

    final FeedbackService s = service(data);
    await s.adoptSpool(spool);

    final FeedbackPendingStore to = FeedbackPendingStore(data);
    expect(spool.existsSync(), isFalse);
    expect(s.pendingSlots(id), <String>{'f0', 'v0', 's0'});
    expect(await to.scan(), <String, Set<String>>{
      id: <String>{'f0', 'v0', 's0'},
    });

    expect(await to.nameOf(id, 'f0'), 'repro.md');
    final ({File file, String contentType})? f0 = await to.fileOf(id, 'f0');
    expect(f0!.contentType, 'application/octet-stream');
    expect(f0.file.readAsStringSync(), '# 步骤\n');

    final ({File file, String contentType})? v0 = await to.fileOf(id, 'v0');
    expect(v0!.contentType, 'video/mp4');
    expect(v0.file.readAsBytesSync(), <int>[1, 2, 3]);

    expect(await to.read(id, 's0'), <int>[9, 9]);
    expect(await to.nameOf(id, 's0'), isNull);
    // 不留半成品。
    expect(
      Directory(
        p.join(data.path, 'feedback', 'pending', id),
      ).listSync().where((FileSystemEntity e) => e.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('并入时目标上残留的旧旁注被 spool 那份覆盖 / 删掉', () async {
    const String id = 'abcdefghij';
    final Directory spool = Directory(p.join(root.path, 'spool'))..createSync();
    final Directory data = Directory(p.join(root.path, 'data'))..createSync();
    final Directory targetDir = Directory(
      p.join(data.path, 'feedback', 'pending', id),
    )..createSync(recursive: true);
    File(p.join(targetDir.path, 's0.name')).writeAsStringSync('stale.txt');
    File(p.join(targetDir.path, 's0.type')).writeAsStringSync('text/plain');

    await FeedbackPendingStore(spool).put(id, 's0', <int>[7]);
    await service(data).adoptSpool(spool);

    final FeedbackPendingStore to = FeedbackPendingStore(data);
    expect(await to.read(id, 's0'), <int>[7]);
    expect(await to.nameOf(id, 's0'), isNull);
    expect(
      (await to.fileOf(id, 's0'))!.contentType,
      'application/octet-stream',
    );
  });
}
