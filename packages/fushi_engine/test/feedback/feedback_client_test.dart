// 反馈接口的客户端契约（服务端：services/leaderboard/src/feedback.js）：
// 反馈人接口不签名、凭 X-Fushi-Ticket；提交按 linkAccount 决定签不签；开发者接口签名；
// 附件 409 slot_taken 视为已传。

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final LeaderboardIdentity _id = LeaderboardIdentity.generate(random: Random(7));

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, dynamic> _summary(String id, {String status = 'open'}) =>
    <String, dynamic>{
      'id': id,
      'category': 'bug',
      'title': 't-$id',
      'status': status,
      'createdAt': 1,
      'updatedAt': 2,
      'devReplyAt': null,
      'userReplyAt': null,
    };

({LeaderboardClient client, List<http.Request> requests}) _harness(
  Future<http.Response> Function(http.Request r) handler, {
  LeaderboardIdentity? identity,
}) {
  final List<http.Request> requests = <http.Request>[];
  final LeaderboardClient client = LeaderboardClient(
    baseUrl: Uri.parse('https://rank.example'),
    httpClientFactory: () async => MockClient((http.Request r) {
      requests.add(r);
      return handler(r);
    }),
    identity: identity,
  );
  return (client: client, requests: requests);
}

void main() {
  test('提交：有账户且 linkAccount 时签名；关掉 linkAccount 匿名', () async {
    final h = _harness(
      (http.Request r) async => _json(<String, dynamic>{
        'id': 'abcdefghij',
        'ticket': 'T' * 32,
        'status': 'open',
        'createdAt': 5,
        'updatedAt': 5,
      }, 201),
      identity: _id,
    );
    final FeedbackReceipt r = await h.client.submitFeedback(
      category: FeedbackCategory.suggestion,
      title: 'hi',
      body: 'body',
      contact: 'tg',
      meta: <String, Object?>{'app_version': '1.0'},
    );
    expect(r.id, 'abcdefghij');
    expect(r.ticket, 'T' * 32);
    final http.Request signed = h.requests.single;
    expect(signed.method, 'POST');
    expect(signed.url.path, '/v1/feedback');
    expect(signed.headers['X-Fushi-Account'], _id.accountId);
    expect(jsonDecode(signed.body), <String, dynamic>{
      'category': 'suggestion',
      'title': 'hi',
      'body': 'body',
      'contact': 'tg',
      'meta': <String, dynamic>{'app_version': '1.0'},
    });

    await h.client.submitFeedback(
      category: FeedbackCategory.bug,
      title: 'x',
      body: 'y',
      linkAccount: false,
    );
    expect(h.requests.last.headers.containsKey('X-Fushi-Account'), isFalse);
    expect(h.requests.last.headers.containsKey('X-Fushi-Sig'), isFalse);
  });

  test('附件：带 ticket、不签名；409 slot_taken 当成功；其它错误抛出', () async {
    int calls = 0;
    final h = _harness((http.Request r) async {
      calls++;
      if (calls == 1) return _json(<String, dynamic>{'slot': 's0'}, 201);
      if (calls == 2) {
        return _json(<String, dynamic>{'error': 'slot_taken'}, 409);
      }
      return _json(<String, dynamic>{'error': 'not_an_image'}, 415);
    }, identity: _id);
    final Uint8List png = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47]);
    await h.client.uploadFeedbackAttachment('abcdefghij', 'tk', 's0', png);
    await h.client.uploadFeedbackAttachment('abcdefghij', 'tk', 's0', png);
    await expectLater(
      h.client.uploadFeedbackAttachment('abcdefghij', 'tk', 's1', png),
      throwsA(
        isA<LeaderboardApiException>().having(
          (LeaderboardApiException e) => e.code,
          'code',
          'not_an_image',
        ),
      ),
    );
    final http.Request first = h.requests.first;
    expect(first.method, 'PUT');
    expect(first.url.path, '/v1/feedback/abcdefghij/attachments/s0');
    expect(first.headers['X-Fushi-Ticket'], 'tk');
    expect(first.headers.containsKey('X-Fushi-Sig'), isFalse);
    expect(first.bodyBytes, png);
    expect(
      () => h.client.uploadFeedbackAttachment('abcdefghij', 'tk', 's9', png),
      throwsArgumentError,
    );
  });

  test('批量进度 / 详情 / 追加说明：不签名，ticket 在 body 或头里', () async {
    final h = _harness((http.Request r) async {
      if (r.url.path == '/v1/feedback/status') {
        return _json(<String, dynamic>{
          'items': <Object>[_summary('abcdefghij', status: 'in_progress')],
        });
      }
      return _json(<String, dynamic>{
        ..._summary('abcdefghij', status: 'resolved'),
        'devReplyAt': 9,
        'body': 'b',
        'attachments': <Object>[
          <String, dynamic>{
            'slot': 'log',
            'kind': 'log',
            'bytes': 10,
            'type': 'application/gzip',
          },
        ],
        'messages': <Object>[
          <String, dynamic>{
            'id': 1,
            'author': 'dev',
            'body': 'fixed',
            'status': 'resolved',
            'createdAt': 9,
            'nickname': 'dev',
          },
        ],
      }, r.method == 'POST' ? 201 : 200);
    }, identity: _id);
    final List<FeedbackSummary> s = await h.client.feedbackStatuses(
      <({String id, String ticket})>[(id: 'abcdefghij', ticket: 'tk')],
    );
    expect(s.single.status, FeedbackStatus.inProgress);
    expect(jsonDecode(h.requests.last.body), <String, dynamic>{
      'items': <Object>[
        <String, dynamic>{'id': 'abcdefghij', 'ticket': 'tk'},
      ],
    });
    expect(h.requests.last.headers.containsKey('X-Fushi-Sig'), isFalse);

    final FeedbackDetail d = await h.client.feedbackDetail('abcdefghij', 'tk');
    expect(h.requests.last.headers['X-Fushi-Ticket'], 'tk');
    expect(d.status, FeedbackStatus.resolved);
    expect(d.summary.devReplyAt, 9);
    expect(d.attachments.single.isLog, isTrue);
    expect(d.messages.single.fromDeveloper, isTrue);
    expect(d.messages.single.status, FeedbackStatus.resolved);

    await h.client.addFeedbackMessage('abcdefghij', 'tk', 'more');
    expect(h.requests.last.url.path, '/v1/feedback/abcdefghij/messages');
    expect(jsonDecode(h.requests.last.body), <String, dynamic>{'body': 'more'});

    expect(
      await h.client.feedbackStatuses(const <({String id, String ticket})>[]),
      isEmpty,
    );
  });

  test('开发者接口：签名；列表带筛选与游标；改状态 + 回复；附件按文本取', () async {
    final h = _harness((http.Request r) async {
      if (r.url.path == '/v1/dev/feedback') {
        return _json(<String, dynamic>{
          'items': <Object>[
            <String, dynamic>{
              ..._summary('abcdefghij'),
              'hasAccount': true,
              'attachments': 2,
              'awaitingDev': true,
              'flags': <Object>[
                'injection',
                'duplicate:zzzzzzzzzz',
                'future_flag',
              ],
            },
          ],
          'next': '2:abcdefghij',
        });
      }
      if (r.url.path.endsWith('/attachments/log')) {
        return http.Response('line', 200);
      }
      return _json(<String, dynamic>{
        ..._summary('abcdefghij', status: 'in_progress'),
        'body': 'b',
        'contact': 'c',
        'meta': <String, dynamic>{'platform': 'android'},
        'origin': <String, dynamic>{'country': 'JP', 'signed': true},
        'reporter': <String, dynamic>{
          'id': 'acc',
          'nickname': 'neko',
          'discriminator': 7,
        },
        'attachments': <Object>[],
        'messages': <Object>[],
      });
    }, identity: _id);
    final FeedbackInboxPage page = await h.client.devFeedbackList(
      status: 'active',
      cursor: '1:zz',
    );
    expect(page.items.single.awaitingDev, isTrue);
    expect(page.items.single.attachmentCount, 2);
    expect(page.next, '2:abcdefghij');
    // 风险标记：认识的解析，不认识的（新服务端加的）忽略。
    expect(page.items.single.flags, <String>[
      'injection',
      'duplicate:zzzzzzzzzz',
      'future_flag',
    ]);
    final List<FeedbackFlag?> parsed = page.items.single.flags
        .map(FeedbackFlag.parse)
        .toList();
    expect(parsed[0], isA<FeedbackInjectionFlag>());
    expect((parsed[1]! as FeedbackDuplicateFlag).ofId, 'zzzzzzzzzz');
    expect(parsed[2], isNull);
    expect(h.requests.last.url.queryParameters, <String, String>{
      'status': 'active',
      'cursor': '1:zz',
    });
    expect(h.requests.last.headers['X-Fushi-Account'], _id.accountId);

    final FeedbackDetail d = await h.client.devUpdateFeedback(
      'abcdefghij',
      status: FeedbackStatus.inProgress,
      reply: 'on it',
    );
    expect(jsonDecode(h.requests.last.body), <String, dynamic>{
      'status': 'in_progress',
      'reply': 'on it',
    });
    expect(d.reporter!.handle, 'neko#0007');
    expect(d.meta['platform'], 'android');
    expect(d.origin, <String, Object?>{'country': 'JP', 'signed': true});

    final Uint8List log = await h.client.devFeedbackAttachment(
      'abcdefghij',
      'log',
      asText: true,
    );
    expect(utf8.decode(log), 'line');
    expect(h.requests.last.url.queryParameters['view'], 'text');

    final LeaderboardClient anon = _harness(
      (http.Request r) async => _json(<String, dynamic>{}),
    ).client;
    expect(() => anon.devFeedbackList(), throwsStateError);
  });
}
