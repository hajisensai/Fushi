// 反馈样本文件附件（拍板台 PLFh2VXDcN / ZbLcRNOvKU）的服务层：
// - 提交时原件复制进待传区（原件不动），按 f0..f2 流式 PUT，带编码后的原文件名；
// - 传失败留在待传区（连同原文件名旁注），详情页重试时照样带原文件名；永久拒收丢弃；
// - 本机先拦住服务端必然拒收的（扩展名 / 空文件 / 超限）；
// - 视频（主证据）先于样本文件传，重试同序；撞每 IP 日额度（429 upload_quota_daily）留待传并给重置时刻；
// - 待传区里本体在 = 原文件名旁注在（copyFile 本体最后落地）；缺旁注的槽位当损坏丢掉，不编假名上传。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_files.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
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
    prepareVideo:
        (
          File source,
          Directory work,
          void Function(double) onProgress,
          FeedbackVideoPrepareOptions _,
        ) async {
          final File out = await source.copy(p.join(work.path, 'out.mp4'));
          return PreparedFeedbackVideo(
            file: out,
            contentType: 'video/mp4',
            bytes: await out.length(),
            transcoded: true,
          );
        },
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

  test('视频与样本文件同交：录屏（主证据）先传，重试也是视频先', () async {
    final File clip = File(p.join(root.path, 'user', 'clip.mp4'))
      ..writeAsBytesSync(List<int>.filled(64, 7));
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'error': 'rate_limited'}, 429);
    };
    final List<FeedbackSubmitStage> stages = <FeedbackSubmitStage>[];
    final FeedbackService s = service();
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        files: <File>[md, srt],
        video: clip,
      ),
      onStage: stages.add,
    );
    expect(result.failedAttachments, 3);
    // 普通限流（rate_limited）不是日额度用完：不提醒「几点后重试」。
    expect(result.quotaResetAt, isNull);
    expect(s.uploadQuotaResetAt('abcdefghij'), isNull);
    expect(
      requests.map((http.Request r) => p.url.basename(r.url.path)).skip(1),
      <String>['v0', 'f0', 'f1'],
    );
    expect(
      stages.skipWhile(
        (FeedbackSubmitStage x) => x != FeedbackSubmitStage.video,
      ),
      <FeedbackSubmitStage>[
        FeedbackSubmitStage.video,
        FeedbackSubmitStage.files,
      ],
    );
    // 429 不是永久拒收：都留在待传区；重试仍是视频排第一。
    expect(s.pendingSlots('abcdefghij'), <String>{'v0', 'f0', 'f1'});
    requests.clear();
    handler = (http.Request r) async =>
        _json(<String, dynamic>{'slot': 'x'}, 201);
    final FeedbackRetryResult retry = await s.retryPending('abcdefghij');
    expect(retry.uploaded, 3);
    expect(
      requests.map((http.Request r) => p.url.basename(r.url.path)),
      <String>['v0', 'f0', 'f1'],
    );
  });

  test('样本文件撞上每 IP 日额度（429 upload_quota_daily）：留在待传区并给出额度重置时刻，'
      '重试传上去后提醒消失', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      if (r.url.path.endsWith('/f0')) {
        return _json(<String, dynamic>{'slot': 'f0'}, 201);
      }
      return _json(<String, dynamic>{
        'error': FeedbackLimits.dailyQuotaError,
      }, 429);
    };
    final FeedbackService s = service();
    final DateTime before = DateTime.now();
    final FeedbackSubmitResult result = await s.submit(draft());
    expect(result.failedAttachments, 1);
    final DateTime expected = FeedbackLimits.dailyQuotaResetAfter(before);
    expect(result.quotaResetAt, expected);
    expect(result.quotaResetAt!.isUtc, isTrue);
    expect(s.uploadQuotaResetAt('abcdefghij'), expected);
    expect(s.pendingSlots('abcdefghij'), <String>{'f1'});

    // 额度还没恢复：重试仍撞额度，结果带重置时刻，槽位继续留着。
    final FeedbackRetryResult still = await s.retryPending('abcdefghij');
    expect(still.remaining, 1);
    expect(still.quotaResetAt, expected);

    // 额度恢复后重试成功：待传清空，提醒消失。
    handler = (http.Request r) async =>
        _json(<String, dynamic>{'slot': 'f1'}, 201);
    final FeedbackRetryResult retry = await s.retryPending('abcdefghij');
    expect(retry.uploaded, 1);
    expect(retry.quotaResetAt, isNull);
    expect(s.uploadQuotaResetAt('abcdefghij'), isNull);
    expect(s.pendingSlots('abcdefghij'), isEmpty);
  });

  test('dailyQuotaResetAfter：下一个 UTC 零点（服务端按 UTC 日窗口计）', () {
    expect(
      FeedbackLimits.dailyQuotaResetAfter(DateTime.utc(2026, 11, 21, 23, 59)),
      DateTime.utc(2026, 11, 22),
    );
    expect(
      FeedbackLimits.dailyQuotaResetAfter(DateTime.utc(2026, 12, 31)),
      DateTime.utc(2027),
    );
    // 本地时间入参按同一时刻换算。
    final DateTime utc = DateTime.utc(2026, 11, 21, 3);
    expect(
      FeedbackLimits.dailyQuotaResetAfter(utc.toLocal()),
      DateTime.utc(2026, 11, 22),
    );
  });

  test('copyFile 中途失败（写原文件名旁注出错）不留下没有原文件名的待传槽位', () async {
    final FeedbackPendingStore store = FeedbackPendingStore(root);
    // 在 .name 旁注的位置放一个目录，写旁注必然失败——模拟复制本体之后、记下原文件名之前中断。
    Directory(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f0.name'),
    ).createSync(recursive: true);
    await expectLater(
      store.copyFile('abcdefghij', 'f0', md, name: '复现 步骤.md'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await store.scan(), isEmpty);
    expect(
      File(
        p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f0.part'),
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f0.type'),
      ).existsSync(),
      isFalse,
    );

    // 正常走完：本体在、旁注在，复制中的 .part 不算槽位也不残留。
    Directory(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f0.name'),
    ).deleteSync();
    await store.copyFile('abcdefghij', 'f0', md, name: '复现 步骤.md');
    expect(await store.scan(), <String, Set<String>>{
      'abcdefghij': <String>{'f0'},
    });
    expect(await store.nameOf('abcdefghij', 'f0'), '复现 步骤.md');
    File(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f1.part'),
    ).writeAsStringSync('half');
    expect(await store.scan(), <String, Set<String>>{
      'abcdefghij': <String>{'f0'},
    });
    // 上次进程在 f1 复制中途崩溃（.part 与旁注都留着、本体没落地）：load 时清掉，
    // 不让它一直占着磁盘；已落地的 f0 不受影响。
    File(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f1.name'),
    ).writeAsStringSync('b.log');
    await service().load();
    for (final String leftover in <String>['f1.part', 'f1.name']) {
      expect(
        File(
          p.join(root.path, 'feedback', 'pending', 'abcdefghij', leftover),
        ).existsSync(),
        isFalse,
        reason: leftover,
      );
    }
    expect(await store.nameOf('abcdefghij', 'f0'), '复现 步骤.md');
  });

  test('待传样本文件缺原文件名旁注：当损坏丢掉，不编假名上传', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'error': 'unavailable'}, 503);
    };
    final FeedbackService s = service();
    await s.submit(draft());
    expect(s.pendingSlots('abcdefghij'), <String>{'f0', 'f1'});
    File(
      p.join(root.path, 'feedback', 'pending', 'abcdefghij', 'f0.name'),
    ).deleteSync();

    requests.clear();
    handler = (http.Request r) async =>
        _json(<String, dynamic>{'slot': 'x'}, 201);
    final FeedbackRetryResult retry = await s.retryPending('abcdefghij');
    expect(
      requests.map((http.Request r) => p.url.basename(r.url.path)),
      <String>['f1'],
    );
    expect(retry.uploaded, 1);
    expect(retry.dropped, 1);
    expect(s.pendingSlots('abcdefghij'), isEmpty);
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
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
