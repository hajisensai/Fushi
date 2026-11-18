// BUG-4785 补全：FeedbackService.load 清上次崩溃留下的 `.part` 半成品失败时，不能连累
// 扫描待传附件——否则这一整次运行里所有待传附件都看不到、没法重试。
//
// 让删除必然失败的手段分平台：Windows 上开着句柄的文件删不掉，POSIX（macOS / Linux）上
// 删文件要父目录的写权限。单独成文件：两个平台分支都要在各自的 dist worker 上跑，
// 又不把 feedback_files_service_test 整份钉到某个平台。

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
    root = Directory.systemTemp.createTempSync('fushi_feedback_discard_');
  });
  tearDown(() => root.deleteSync(recursive: true));

  FeedbackService service() => FeedbackService(
    supportRoot: () async => root,
    client: () => LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async =>
          MockClient((http.Request r) async => http.Response('', 500)),
    ),
    meta: () async => <String, Object?>{'platform': 'test'},
    logText: ({required bool includeDebugLog}) => 'log',
    logEncoder: (String s) => Uint8List(0),
  );

  test('清半成品失败（.part 删不掉）不连累 load 扫出待传附件', () async {
    final File source = File(p.join(root.path, 'repro.md'))
      ..writeAsStringSync('# 步骤\n');
    final FeedbackPendingStore store = FeedbackPendingStore(root);
    await store.copyFile('abcdefghij', 'f0', source, name: 'repro.md');
    final Directory dir = Directory(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij'),
    );
    final File part = File(p.join(dir.path, 'f1.part'))
      ..writeAsStringSync('half');

    final bool posix = Platform.isMacOS || Platform.isLinux;
    RandomAccessFile? held;
    if (Platform.isWindows) {
      held = part.openSync(mode: FileMode.append);
    } else if (posix) {
      expect(Process.runSync('chmod', <String>['555', dir.path]).exitCode, 0);
    } else {
      markTestSkipped('只在 Windows / macOS / Linux 上能让删除必然失败');
      return;
    }
    try {
      final FeedbackService s = service();
      await s.load();
      // 前提成立：清理确实失败了（否则本用例什么也没测到）。
      expect(part.existsSync(), isTrue);
      expect(s.pendingSlots('abcdefghij'), <String>{'f0'});
    } finally {
      held?.closeSync();
      if (posix) Process.runSync('chmod', <String>['755', dir.path]);
    }
  });
}
