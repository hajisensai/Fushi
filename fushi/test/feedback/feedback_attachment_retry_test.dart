// 反馈附件补传（#AcHo3yVAca / #uyoDqalpZe）与联系方式记忆（#oiJANmS4lJ）：
// 提交时传失败的截图 / 日志字节落盘留着，之后能手动重试；服务端明确拒收的丢弃；
// 已提交的反馈能往空闲截图槽位追加截图；上次提交的联系方式单独存、清草稿不带走。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

Uint8List _bytes(int b) => Uint8List.fromList(<int>[b]);

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
    meta: () async => <String, Object?>{},
    logText: () => 'E/boom',
    logEncoder: (String log) => Uint8List.fromList(utf8.encode(log)),
  );

  http.Response created() => _json(<String, dynamic>{
    'id': 'abcdefghij',
    'ticket': 'T' * 32,
    'status': 'open',
    'createdAt': DateTime.now().millisecondsSinceEpoch,
    'updatedAt': 1000,
  }, 201);

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_feedback_retry_');
    requests = <http.Request>[];
  });
  tearDown(() => root.deleteSync(recursive: true));

  const FeedbackDraft draft = FeedbackDraft(
    category: FeedbackCategory.bug,
    title: 't',
    body: 'b',
    contact: ' me@example.com ',
  );

  test('提交时网络中断：截图与日志字节留在本机，重启后还在，重试后传上去并清掉', () async {
    bool offline = true;
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return created();
      if (offline) throw const SocketException('down');
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final FeedbackService s = service();
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        screenshots: <Uint8List>[_bytes(1), _bytes(2)],
      ),
    );
    expect(result.failedAttachments, 3);
    expect(s.pendingSlots('abcdefghij'), <String>{'s0', 's1', 'log'});

    // 新开一个服务（相当于重启 app）：待传清单从磁盘恢复。
    final FeedbackService reopened = service();
    await reopened.load();
    expect(reopened.pendingSlots('abcdefghij'), <String>{'s0', 's1', 'log'});

    offline = false;
    requests.clear();
    final FeedbackRetryResult r = await reopened.retryPending('abcdefghij');
    expect(r.uploaded, 3);
    expect(r.remaining, 0);
    expect(reopened.pendingSlots('abcdefghij'), isEmpty);
    expect(
      requests.map((http.Request q) => q.url.path).toList()..sort(),
      <String>[
        '/v1/feedback/abcdefghij/attachments/log',
        '/v1/feedback/abcdefghij/attachments/s0',
        '/v1/feedback/abcdefghij/attachments/s1',
      ],
    );
    final Map<String, http.Request> bySlot = <String, http.Request>{
      for (final http.Request q in requests) q.url.pathSegments.last: q,
    };
    expect(bySlot['s0']!.bodyBytes, _bytes(1));
    expect(bySlot['s1']!.bodyBytes, _bytes(2));
    expect(bySlot['log']!.bodyBytes, utf8.encode('E/boom'));
    expect(
      Directory('${root.path}/feedback/pending').existsSync()
          ? Directory('${root.path}/feedback/pending').listSync()
          : <FileSystemEntity>[],
      isEmpty,
    );
  });

  test('重试仍然失败：留着待传；槽位已被占用（409）按成功处理', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return created();
      return _json(<String, dynamic>{'error': 'x'}, 503);
    };
    final FeedbackService s = service();
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        includeLogs: false,
        screenshots: <Uint8List>[_bytes(1), _bytes(2)],
      ),
    );
    expect(s.pendingSlots('abcdefghij'), <String>{'s0', 's1'});

    handler = (http.Request r) async {
      if (r.url.path.endsWith('/s0')) {
        return _json(<String, dynamic>{'error': 'slot_taken'}, 409);
      }
      return _json(<String, dynamic>{'error': 'x'}, 503);
    };
    final FeedbackRetryResult r = await s.retryPending('abcdefghij');
    expect(r.uploaded, 1, reason: 's0 已在服务端 = 已传成功');
    expect(r.remaining, 1);
    expect(s.pendingSlots('abcdefghij'), <String>{'s1'});
  });

  test('超过补传窗口 / 被拒收（403）：丢弃字节并计入 dropped，不再无限重试', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return created();
      return _json(<String, dynamic>{'error': 'x'}, 503);
    };
    final FeedbackService s = service();
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        includeLogs: false,
        screenshots: <Uint8List>[_bytes(1)],
      ),
    );
    handler = (http.Request r) async =>
        _json(<String, dynamic>{'error': 'attach_window_closed'}, 403);
    final FeedbackRetryResult r = await s.retryPending('abcdefghij');
    expect(r.dropped, 1);
    expect(r.remaining, 0);
    expect(s.pendingSlots('abcdefghij'), isEmpty);
  });

  test('追加截图：只用服务端和本机都没占用的空闲槽位，超出空位的丢弃', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return created();
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final FeedbackService s = service();
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        includeLogs: false,
      ),
    );
    requests.clear();
    // 服务端已有 s0：两张新图只能进 s1、s2。
    final FeedbackRetryResult r = await s.addScreenshots(
      'abcdefghij',
      <Uint8List>[_bytes(7), _bytes(8), _bytes(9)],
      usedSlots: <String>{'s0'},
    );
    expect(r.uploaded, 2);
    expect(
      requests.map((http.Request q) => q.url.pathSegments.last).toList(),
      <String>['s1', 's2'],
    );
    expect(requests.first.bodyBytes, _bytes(7));
    expect(requests.last.bodyBytes, _bytes(8));
  });

  test('补传窗口：刚提交的可追加，24 小时前的不行', () async {
    handler = (http.Request r) async => created();
    final FeedbackService s = service();
    final FeedbackSubmitResult fresh = await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        includeLogs: false,
      ),
    );
    expect(s.canAttach(fresh.ticket), isTrue);
    final FeedbackTicket old = fresh.ticket.copyWith();
    final FeedbackTicket aged = FeedbackTicket(
      id: old.id,
      ticket: old.ticket,
      title: old.title,
      category: old.category,
      createdAt:
          DateTime.now().millisecondsSinceEpoch -
          FeedbackLimits.attachWindow.inMilliseconds -
          60000,
      status: old.status,
      updatedAt: old.updatedAt,
    );
    expect(s.canAttach(aged), isFalse);
  });

  test('联系方式：提交后记住（去空白），草稿清掉后仍在；没填联系方式不覆盖旧值', () async {
    handler = (http.Request r) async => created();
    final FeedbackService s = service();
    expect(await s.lastContact(), '');
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        contact: draft.contact,
        includeLogs: false,
      ),
    );
    expect(await s.lastContact(), 'me@example.com');
    await (await s.draftStore()).clear();
    expect(await service().lastContact(), 'me@example.com');
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't2',
        body: 'b',
        includeLogs: false,
      ),
    );
    expect(await s.lastContact(), 'me@example.com');
  });

  test('从本机移除一条反馈：它的待传附件一并清掉', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return created();
      return _json(<String, dynamic>{'error': 'x'}, 503);
    };
    final FeedbackService s = service();
    await s.submit(
      FeedbackDraft(
        category: draft.category,
        title: 't',
        body: 'b',
        includeLogs: false,
        screenshots: <Uint8List>[_bytes(1)],
      ),
    );
    expect(s.pendingSlots('abcdefghij'), isNotEmpty);
    await s.forget('abcdefghij');
    expect(s.pendingSlots('abcdefghij'), isEmpty);
    expect(await FeedbackPendingStore(root).scan(), isEmpty);
  });
}
