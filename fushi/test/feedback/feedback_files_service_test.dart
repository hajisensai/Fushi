// 反馈样本文件附件（拍板台 PLFh2VXDcN / ZbLcRNOvKU）的服务层：
// - 提交时原件复制进待传区（原件不动），按 f0..f2 流式 PUT，带编码后的原文件名；
// - 传失败留在待传区（连同原文件名旁注），详情页重试时照样带原文件名；永久拒收丢弃；
// - 本机先拦住服务端必然拒收的（扩展名 / 空文件 / 超限）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_files.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

void main() {
  late Directory root;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request r) handler;

  FeedbackService service() => FeedbackService(
    supportRoot: () async => root,
    client: () => LeaderboardClient(
      baseUrl: Uri.parse('https://rank.example'),
      httpClientFactory: () async => MockClient((http.Request r) {
        requests.add(r);
        return handler(r);
      }),
    ),
    meta: () async => <String, Object?>{'platform': 'test'},
    logText: ({required bool includeDebugLog}) => 'log',
    logEncoder: (String s) =>
        Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(s)]),
  );

  Future<http.Response> receipt(http.Request r) async =>
      _json(<String, dynamic>{
        'id': 'abcdefghij',
        'ticket': 'T' * 32,
        'status': 'open',
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      }, 201);

  late File md;
  late File srt;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_files_');
    requests = <http.Request>[];
    final Directory user = Directory(p.join(root.path, 'user'))..createSync();
    md = File(p.join(user.path, '复现 步骤.md'))
      ..writeAsStringSync('# 步骤\n1. 导入\n');
    srt = File(p.join(user.path, 'ep01.srt'))
      ..writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  FeedbackDraft draft() => FeedbackDraft(
    category: FeedbackCategory.bug,
    title: 't',
    body: 'b',
    includeLogs: false,
    files: <File>[md, srt],
  );

  test('提交带样本文件：f0 / f1 流式 PUT、带原文件名与长度，原件不动，待传区清空', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final List<FeedbackSubmitStage> stages = <FeedbackSubmitStage>[];
    final FeedbackSubmitResult result = await service().submit(
      draft(),
      onStage: stages.add,
    );
    expect(result.failedAttachments, 0);
    expect(stages, <FeedbackSubmitStage>[
      FeedbackSubmitStage.sending,
      FeedbackSubmitStage.files,
    ]);
    expect(requests.map((http.Request r) => r.url.path), <String>[
      '/v1/feedback',
      '/v1/feedback/abcdefghij/attachments/f0',
      '/v1/feedback/abcdefghij/attachments/f1',
    ]);
    final http.Request f0 = requests[1];
    expect(f0.method, 'PUT');
    expect(f0.headers['X-Fushi-Ticket'], 'T' * 32);
    expect(Uri.decodeComponent(f0.headers['X-Fushi-File-Name']!), '复现 步骤.md');
    expect(f0.bodyBytes, md.readAsBytesSync());
    expect(f0.contentLength, md.lengthSync());
    expect(
      Uri.decodeComponent(requests[2].headers['X-Fushi-File-Name']!),
      'ep01.srt',
    );
    final Map<String, dynamic> body =
        jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect((body['meta'] as Map<String, dynamic>)['files'], 2);
    expect(md.existsSync(), isTrue);
    expect(srt.existsSync(), isTrue);
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
  });

  test('传失败留在待传区（带原文件名旁注），重试照样带原文件名；永久拒收丢弃', () async {
    int fileCalls = 0;
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      fileCalls++;
      return _json(<String, dynamic>{'error': 'unavailable'}, 503);
    };
    final FeedbackService s = service();
    final FeedbackSubmitResult result = await s.submit(draft());
    expect(result.failedAttachments, 2);
    expect(fileCalls, 2);
    expect(s.pendingSlots('abcdefghij'), <String>{'f0', 'f1'});
    // 旁注（.type / .name）不算槽位。
    expect(await FeedbackPendingStore(root).scan(), <String, Set<String>>{
      'abcdefghij': <String>{'f0', 'f1'},
    });
    expect(
      await FeedbackPendingStore(root).nameOf('abcdefghij', 'f0'),
      '复现 步骤.md',
    );

    requests.clear();
    handler = (http.Request r) async => r.url.path.endsWith('/f1')
        ? _json(<String, dynamic>{'error': 'not_a_text'}, 415)
        : _json(<String, dynamic>{'slot': 'f0'}, 201);
    final FeedbackRetryResult retry = await s.retryPending('abcdefghij');
    expect(retry.uploaded, 1);
    expect(retry.dropped, 1);
    expect(retry.remaining, 0);
    final http.Request again = requests.firstWhere(
      (http.Request r) => r.url.path.endsWith('/f0'),
    );
    expect(
      Uri.decodeComponent(again.headers['X-Fushi-File-Name']!),
      '复现 步骤.md',
    );
    expect(again.bodyBytes, md.readAsBytesSync());
    expect(s.pendingSlots('abcdefghij'), isEmpty);
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
    expect(
      Directory(
        p.join(root.path, 'feedback', 'pending', 'abcdefghij'),
      ).existsSync(),
      isFalse,
    );
  });

  test('超过名额的样本文件只传前 ${FeedbackLimits.files} 个', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    await service().submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        files: <File>[md, srt, md, srt],
      ),
    );
    expect(
      requests.map((http.Request r) => p.url.basename(r.url.path)).skip(1),
      <String>['f0', 'f1', 'f2'],
    );
  });

  test('feedbackFileProblem：白名单外 / 空 / 超限本机就拦', () {
    expect(feedbackFileProblem('a/notes.MD', 10), isNull);
    expect(feedbackFileProblem('dict.mdx', 10), isNull);
    expect(feedbackFileProblem('book.epub', 10), isNull);
    expect(
      feedbackFileProblem('page.html', 10),
      FeedbackFileProblem.unsupportedType,
    );
    expect(
      feedbackFileProblem('setup.exe', 10),
      FeedbackFileProblem.unsupportedType,
    );
    expect(
      feedbackFileProblem('noext', 10),
      FeedbackFileProblem.unsupportedType,
    );
    expect(feedbackFileProblem('a.srt', 0), FeedbackFileProblem.empty);
    expect(
      feedbackFileProblem('a.mkv', FeedbackLimits.fileMaxBytes + 1),
      FeedbackFileProblem.tooLarge,
    );
    expect(feedbackFileProblem('a.mkv', FeedbackLimits.fileMaxBytes), isNull);
  });
}
