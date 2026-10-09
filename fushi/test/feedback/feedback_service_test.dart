// 反馈服务：提交后回执立刻落盘、附件逐个补传（失败计数不影响反馈本身）、
// 批量刷新进度与「有新回复」、看详情记已读、查不到标 missing；日志 gzip 截断上限。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/feedback/feedback_diagnostics.dart';
import 'package:fushi/src/feedback/feedback_service.dart';
import 'package:fushi/src/feedback/feedback_store.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _summary(
  String id, {
  String status = 'open',
  int updatedAt = 1000,
  int? devReplyAt,
}) => <String, dynamic>{
  'id': id,
  'category': 'bug',
  'title': 'server-$id',
  'status': status,
  'createdAt': 1000,
  'updatedAt': updatedAt,
  'devReplyAt': devReplyAt,
  'userReplyAt': null,
};

Uint8List _fakeGzip(String log) =>
    Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(log)]);

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
    logText: () => 'E/boom',
    logEncoder: _fakeGzip,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_');
    requests = <http.Request>[];
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('提交：回执落盘；截图与日志逐个补传，失败只计数', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') {
        return _json(<String, dynamic>{
          'id': 'abcdefghij',
          'ticket': 'T' * 32,
          'status': 'open',
          'createdAt': 1000,
          'updatedAt': 1000,
        }, 201);
      }
      if (r.url.path.endsWith('/s1')) {
        return _json(<String, dynamic>{'error': 'not_an_image'}, 415);
      }
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final FeedbackService s = service();
    final List<FeedbackSubmitStage> stages = <FeedbackSubmitStage>[];
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: '  标题 ',
        body: '正文',
        screenshots: <Uint8List>[
          Uint8List.fromList(<int>[1]),
          Uint8List.fromList(<int>[2]),
        ],
      ),
      onStage: stages.add,
    );
    expect(result.failedAttachments, 1);
    expect(result.ticket.title, '标题');
    expect(stages, <FeedbackSubmitStage>[
      FeedbackSubmitStage.sending,
      FeedbackSubmitStage.screenshots,
      FeedbackSubmitStage.logs,
    ]);
    expect(requests.map((http.Request r) => r.url.path), <String>[
      '/v1/feedback',
      '/v1/feedback/abcdefghij/attachments/s0',
      '/v1/feedback/abcdefghij/attachments/s1',
      '/v1/feedback/abcdefghij/attachments/log',
    ]);
    final Map<String, dynamic> body =
        jsonDecode(requests.first.body) as Map<String, dynamic>;
    expect(body['meta'], <String, dynamic>{
      'platform': 'test',
      'logs_attached': true,
      'screenshots': 2,
    });
    expect(requests.last.bodyBytes, _fakeGzip('E/boom'));
    // 落盘：新开一个服务也读得到回执。
    final List<FeedbackTicket> stored = await FeedbackTicketStore(root).read();
    expect(stored.single.ticket, 'T' * 32);
    expect(stored.single.hasUnseenReply, isFalse);
  });

  test('关掉日志与设备信息：不传日志、meta 只剩计数', () async {
    handler = (http.Request r) async => _json(<String, dynamic>{
      'id': 'abcdefghij',
      'ticket': 'T' * 32,
      'status': 'open',
      'createdAt': 1000,
      'updatedAt': 1000,
    }, 201);
    await service().submit(
      const FeedbackDraft(
        category: FeedbackCategory.other,
        title: 't',
        body: 'b',
        includeLogs: false,
        includeDeviceInfo: false,
      ),
    );
    expect(requests, hasLength(1));
    expect(
      (jsonDecode(requests.single.body) as Map<String, dynamic>)['meta'],
      <String, dynamic>{'logs_attached': false, 'screenshots': 0},
    );
  });

  test('刷新进度：开发者新回复亮红点；看详情后记已读；查不到标 missing', () async {
    await FeedbackTicketStore(root).write(<FeedbackTicket>[
      const FeedbackTicket(
        id: 'aaaaaaaaaa',
        ticket: 'ta',
        title: 'a',
        category: FeedbackCategory.bug,
        createdAt: 1000,
        status: FeedbackStatus.open,
        updatedAt: 1000,
        seenAt: 1000,
      ),
      const FeedbackTicket(
        id: 'bbbbbbbbbb',
        ticket: 'tb',
        title: 'b',
        category: FeedbackCategory.bug,
        createdAt: 900,
        status: FeedbackStatus.open,
        updatedAt: 900,
        seenAt: 900,
      ),
    ]);
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback/status') {
        return _json(<String, dynamic>{
          'items': <Object>[
            _summary(
              'aaaaaaaaaa',
              status: 'in_progress',
              updatedAt: 2000,
              devReplyAt: 2000,
            ),
          ],
        });
      }
      return _json(<String, dynamic>{
        ..._summary(
          'aaaaaaaaaa',
          status: 'in_progress',
          updatedAt: 2000,
          devReplyAt: 2000,
        ),
        'body': 'b',
        'attachments': <Object>[],
        'messages': <Object>[],
      });
    };
    final FeedbackService s = service();
    await s.refresh();
    expect(s.unseenCount, 1);
    expect(s.byId('aaaaaaaaaa')!.status, FeedbackStatus.inProgress);
    expect(s.byId('aaaaaaaaaa')!.title, 'server-aaaaaaaaaa');
    expect(s.byId('bbbbbbbbbb')!.missing, isTrue);

    await s.detail('aaaaaaaaaa');
    expect(requests.last.headers['X-Fushi-Ticket'], 'ta');
    expect(s.unseenCount, 0);
    // 已读状态落盘。
    final List<FeedbackTicket> stored = await FeedbackTicketStore(root).read();
    expect(
      stored.firstWhere((FeedbackTicket t) => t.id == 'aaaaaaaaaa').seenAt,
      2000,
    );

    await s.forget('bbbbbbbbbb');
    expect(s.tickets.map((FeedbackTicket t) => t.id), <String>['aaaaaaaaaa']);
  });

  test('详情 404：标 missing 并把异常抛给页面', () async {
    await FeedbackTicketStore(root).write(<FeedbackTicket>[
      const FeedbackTicket(
        id: 'aaaaaaaaaa',
        ticket: 'ta',
        title: 'a',
        category: FeedbackCategory.bug,
        createdAt: 1000,
        status: FeedbackStatus.open,
        updatedAt: 1000,
      ),
    ]);
    handler = (http.Request r) async =>
        _json(<String, dynamic>{'error': 'not_found'}, 404);
    final FeedbackService s = service();
    await s.load();
    await expectLater(
      s.detail('aaaaaaaaaa'),
      throwsA(isA<LeaderboardApiException>()),
    );
    expect(s.byId('aaaaaaaaaa')!.missing, isTrue);
  });

  test('损坏的清单文件：改名留档，读成空清单', () async {
    final FeedbackTicketStore store = FeedbackTicketStore(root);
    store.file.parent.createSync(recursive: true);
    store.file.writeAsStringSync('{not json');
    expect(await store.read(), isEmpty);
    expect(
      store.file.parent.listSync().whereType<File>().any(
        (File f) => f.path.contains('.corrupt-'),
      ),
      isTrue,
    );
  });

  group('日志压缩', () {
    test('小日志原样压缩，可解回原文', () {
      final Uint8List gz = buildFeedbackLogGzip('第一行\nline 2\n');
      expect(gz.sublist(0, 2), <int>[0x1f, 0x8b]);
      expect(utf8.decode(gzip.decode(gz)), '第一行\nline 2\n');
    });

    test('超过上限只留末尾、注明截断，且不切坏多字节字符', () {
      // 不可压缩的随机文本，逼出截断。
      final StringBuffer buf = StringBuffer();
      int seed = 1;
      for (int i = 0; i < 60000; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        buf.writeCharCode(0x4e00 + seed % 0x5000);
      }
      buf.write('END');
      final Uint8List gz = buildFeedbackLogGzip(
        buf.toString(),
        maxBytes: 32 * 1024,
      );
      expect(gz.length, lessThanOrEqualTo(32 * 1024));
      final String text = utf8.decode(gzip.decode(gz));
      expect(text, startsWith('[truncated: kept last '));
      expect(text, endsWith('END'));
      expect(text, isNot(contains('�')));
    });
  });
}
