// 反馈视频附件 + 跨设备「我的反馈」的服务层：
// - 视频先在本机准备（转码），太大 / 不是视频时反馈根本不提交；
// - 视频最后传、带 Content-Length 流式 PUT 到 v0；传失败留在待传区，重试成功后清掉；
// - 已登录账户时「我的反馈」= 本机回执 ∪ GET /v1/feedback/mine（签名），按 id 去重、本机优先；
//   账户条目没有 ticket，看详情走账户签名、不带 X-Fushi-Ticket；缓存按账户落盘。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi/src/feedback/feedback_video.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _summary(String id, {int createdAt = 1000}) =>
    <String, dynamic>{
      'id': id,
      'category': 'bug',
      'title': 'server-$id',
      'status': 'open',
      'createdAt': createdAt,
      'updatedAt': createdAt,
      'devReplyAt': null,
      'userReplyAt': null,
    };

Map<String, dynamic> _detail(String id) => <String, dynamic>{
  ..._summary(id),
  'body': 'body-$id',
  'attachments': <Object>[],
  'messages': <Object>[],
};

/// 假 mp4（ftyp 魔数开头）。
Uint8List _fakeMp4(int length) {
  final Uint8List b = Uint8List(length);
  b.setAll(0, <int>[
    0,
    0,
    0,
    0x18,
    0x66,
    0x74,
    0x79,
    0x70,
    0x69,
    0x73,
    0x6f,
    0x6d,
  ]);
  return b;
}

void main() {
  late Directory root;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request r) handler;
  LeaderboardIdentity? identity;

  LeaderboardClient client() => LeaderboardClient(
    baseUrl: Uri.parse('https://rank.example'),
    identity: identity,
    httpClientFactory: () async => MockClient((http.Request r) {
      requests.add(r);
      return handler(r);
    }),
  );

  FeedbackService service({FeedbackVideoPreparer? prepare}) => FeedbackService(
    supportRoot: () async => root,
    client: client,
    meta: () async => <String, Object?>{'platform': 'test'},
    logText: () => 'log',
    logEncoder: (String s) =>
        Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(s)]),
    prepareVideo:
        prepare ??
        (File source, Directory work, void Function(double) onProgress) async {
          onProgress(0.5);
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

  late File source;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_video_');
    requests = <http.Request>[];
    identity = null;
    source = File(p.join(root.path, 'clip.mp4'))
      ..writeAsBytesSync(_fakeMp4(4096));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('提交带视频：先准备再发正文，视频最后流式 PUT 到 v0（带长度与类型），原件不动', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final List<FeedbackSubmitStage> stages = <FeedbackSubmitStage>[];
    final List<double?> progress = <double?>[];
    final FeedbackSubmitResult result = await service().submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        video: source,
      ),
      onStage: stages.add,
      onVideoProgress: progress.add,
    );
    expect(result.failedAttachments, 0);
    expect(stages, <FeedbackSubmitStage>[
      FeedbackSubmitStage.videoPrepare,
      FeedbackSubmitStage.sending,
      FeedbackSubmitStage.video,
    ]);
    expect(requests.map((http.Request r) => r.url.path), <String>[
      '/v1/feedback',
      '/v1/feedback/abcdefghij/attachments/v0',
    ]);
    final http.Request put = requests.last;
    expect(put.method, 'PUT');
    expect(put.headers['X-Fushi-Ticket'], 'T' * 32);
    expect(put.headers['Content-Type'], 'video/mp4');
    expect(put.contentLength, 4096);
    expect(put.bodyBytes, _fakeMp4(4096));
    final Map<String, dynamic> body =
        jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect((body['meta'] as Map<String, dynamic>)['video'], isTrue);
    expect(progress, contains(0.5));
    expect(progress.last, 1.0);
    // 原件还在，工作目录与待传区都清干净了。
    expect(source.existsSync(), isTrue);
    expect(
      Directory(p.join(root.path, 'feedback', 'video_work')).listSync(),
      isEmpty,
    );
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
  });

  test('视频太大：准备阶段就抛，正文不提交', () async {
    handler = receipt;
    final FeedbackService s = service(
      prepare: (File _, Directory _, void Function(double) _) async =>
          throw const FeedbackVideoTooLargeException(60 * 1024 * 1024),
    );
    await expectLater(
      s.submit(
        FeedbackDraft(
          category: FeedbackCategory.bug,
          title: 't',
          body: 'b',
          video: source,
        ),
      ),
      throwsA(isA<FeedbackVideoTooLargeException>()),
    );
    expect(requests, isEmpty);
    expect(s.tickets, isEmpty);
  });

  test('视频传失败（网络）：计入失败、留在待传区；重试成功后清掉；服务端拒收则丢弃', () async {
    bool videoFails = true;
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      if (r.url.path.endsWith('/v0') && videoFails) {
        throw const SocketException('reset');
      }
      return _json(<String, dynamic>{'slot': 'v0'}, 201);
    };
    final FeedbackService s = service();
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        video: source,
      ),
    );
    expect(result.failedAttachments, 1);
    expect(s.pendingSlots('abcdefghij'), <String>{'v0'});
    // 重启后仍在（落盘）。
    final FeedbackService again = service();
    await again.load();
    expect(again.pendingSlots('abcdefghij'), <String>{'v0'});
    expect(again.canAttach(again.byId('abcdefghij')!), isTrue);

    videoFails = false;
    final FeedbackRetryResult r = await again.retryPending('abcdefghij');
    expect(r.uploaded, 1);
    expect(r.remaining, 0);
    expect(again.pendingSlots('abcdefghij'), isEmpty);
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
    expect(requests.last.contentLength, 4096);
  });

  test('补传窗口已过：服务端 403 拒收的视频直接丢弃，不留着反复重试', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'error': 'attach_window_closed'}, 403);
    };
    final FeedbackService s = service();
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        video: source,
      ),
    );
    expect(result.failedAttachments, 1);
    expect(s.pendingSlots('abcdefghij'), isEmpty);
  });

  test('追加视频：转码 → 上传，进度经 videoTransfer 暴露，完成后清空', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'slot': 'v0'}, 201);
    };
    final FeedbackService s = service();
    await s.submit(
      const FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
      ),
    );
    final List<FeedbackVideoStage> seen = <FeedbackVideoStage>[];
    s.addListener(() {
      final FeedbackVideoTransfer? tr = s.videoTransfer('abcdefghij');
      if (tr != null && (seen.isEmpty || seen.last != tr.stage)) {
        seen.add(tr.stage);
      }
    });
    final FeedbackRetryResult r = await s.addVideo('abcdefghij', source);
    expect(r.uploaded, 1);
    expect(seen, <FeedbackVideoStage>[
      FeedbackVideoStage.preparing,
      FeedbackVideoStage.uploading,
    ]);
    expect(s.videoTransfer('abcdefghij'), isNull);
    expect(requests.last.url.path, '/v1/feedback/abcdefghij/attachments/v0');
  });

  group('跨设备「我的反馈」', () {
    setUp(() => identity = LeaderboardIdentity.generate());

    test('已登录：合并本机回执与账户列表，按 id 去重（本机优先）；账户条目没有 ticket', () async {
      await FeedbackTicketStore(root).write(<FeedbackTicket>[
        const FeedbackTicket(
          id: 'localloc00',
          ticket: 'local-ticket',
          title: 'local',
          category: FeedbackCategory.bug,
          createdAt: 3000,
          status: FeedbackStatus.open,
          updatedAt: 3000,
        ),
      ]);
      handler = (http.Request r) async {
        if (r.url.path == '/v1/feedback/status') {
          return _json(<String, dynamic>{
            'items': <Object>[_summary('localloc00', createdAt: 3000)],
          });
        }
        if (r.url.path == '/v1/feedback/mine') {
          final String? cursor = r.url.queryParameters['cursor'];
          return _json(
            cursor == null
                ? <String, dynamic>{
                    'items': <Object>[
                      _summary('localloc00', createdAt: 3000),
                      _summary('otherdev01', createdAt: 2000),
                    ],
                    'next': '2000:otherdev01',
                  }
                : <String, dynamic>{
                    'items': <Object>[_summary('otherdev02', createdAt: 1000)],
                    'next': null,
                  },
          );
        }
        if (r.url.path == '/v1/feedback/otherdev01') {
          return _json(_detail('otherdev01'));
        }
        return _json(<String, dynamic>{}, 404);
      };
      final FeedbackService s = service();
      await s.refresh();
      expect(s.tickets.map((FeedbackTicket t) => t.id), <String>[
        'localloc00',
        'otherdev01',
        'otherdev02',
      ]);
      expect(s.byId('localloc00')!.viaAccount, isFalse);
      expect(s.byId('otherdev01')!.viaAccount, isTrue);
      // 账户条目不能补传附件（补传只认 ticket）。
      expect(s.canAttach(s.byId('otherdev01')!), isFalse);

      final http.Request mine = requests.firstWhere(
        (http.Request r) => r.url.path == '/v1/feedback/mine',
      );
      expect(mine.headers['X-Fushi-Account'], identity!.accountId);
      expect(mine.headers['X-Fushi-Sig'], isNotNull);
      expect(mine.url.queryParameters['limit'], '${FeedbackLimits.minePage}');

      // 看别的设备提交的那条：账户签名、不带 ticket。
      final FeedbackDetail d = await s.detail('otherdev01');
      expect(d.body, 'body-otherdev01');
      final http.Request get = requests.last;
      expect(get.url.path, '/v1/feedback/otherdev01');
      expect(get.headers.containsKey('X-Fushi-Ticket'), isFalse);
      expect(get.headers['X-Fushi-Sig'], isNotNull);
      // 本机回执那条照旧凭 ticket、不签名。
      handler = (http.Request r) async => _json(_detail('localloc00'));
      await s.detail('localloc00');
      expect(requests.last.headers['X-Fushi-Ticket'], 'local-ticket');
      expect(requests.last.headers.containsKey('X-Fushi-Sig'), isFalse);

      // 账户列表按账户落盘：新开服务（还没联网）就能列出来。
      final FeedbackService again = service();
      await again.load();
      expect(
        again.tickets.map((FeedbackTicket t) => t.id),
        containsAll(<String>['otherdev01', 'otherdev02']),
      );
    });

    test('退出登录 / 换账户：丢掉旧账户的列表，未登录不请求 mine', () async {
      handler = (http.Request r) async => _json(<String, dynamic>{
        'items': <Object>[_summary('otherdev01')],
        'next': null,
      });
      final FeedbackService s = service();
      await s.refresh();
      expect(s.byId('otherdev01'), isNotNull);

      identity = null;
      requests.clear();
      await s.refresh();
      expect(s.byId('otherdev01'), isNull);
      expect(
        requests.where((http.Request r) => r.url.path == '/v1/feedback/mine'),
        isEmpty,
      );
    });
  });
}
