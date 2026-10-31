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
import 'package:fushi_engine/leaderboard/install_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final InstallAttestation _install = InstallAttestation(
  InstallIdentity.fromMachineId('feedback-test-machine'),
  '1',
);

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
    installId: () async => _install,
    logText: ({required bool includeDebugLog}) => 'E/boom',
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
    // 勾选「附带设备信息」（默认）时一并带上安装统计的安装 id 与安装证明头。
    expect(body['installId'], _install.installId);
    expect(
      requests.first.headers[kInstallKeyHeader],
      _install.identity.pubkeyBase64Url,
    );
    expect(requests.first.headers[kInstallSigHeader], isNotEmpty);
    expect(requests.last.bodyBytes, _fakeGzip('E/boom'));
    // 落盘：新开一个服务也读得到回执。
    final List<FeedbackTicket> stored = await FeedbackTicketStore(root).read();
    expect(stored.single.ticket, 'T' * 32);
    expect(stored.single.hasUnseenReply, isFalse);
  });

  // BUG-3489 审查：正文交上去之后的步骤（回执落盘）出错不能报成提交失败——用户会再点一次、
  // 生成一条重复反馈。回执留在内存清单里，下一次落盘一起写下。
  test('正文已交上去后回执落盘失败：不抛、回执在清单里；下一次落盘把它写下', () async {
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
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final FeedbackService s = service();
    await s.load();
    // 回执清单的临时文件位置被一个目录占住：本次落盘必然失败。
    final Directory blocker = Directory(
      '${root.path}/feedback/tickets.json.tmp',
    )..createSync(recursive: true);
    final FeedbackSubmitResult result = await s.submit(
      const FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        includeDeviceInfo: false,
      ),
    );
    expect(result.ticket.id, 'abcdefghij');
    expect(s.byId('abcdefghij')?.ticket, 'T' * 32);
    expect(FeedbackTicketStore(root).file.existsSync(), isFalse);

    blocker.deleteSync();
    handler = (http.Request r) async => _json(<String, dynamic>{
      'id': 'klmnopqrst',
      'ticket': 'U' * 32,
      'status': 'open',
      'createdAt': 2000,
      'updatedAt': 2000,
    }, 201);
    await s.submit(
      const FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't2',
        body: 'b2',
        includeLogs: false,
        includeDeviceInfo: false,
      ),
    );
    final List<FeedbackTicket> stored = await FeedbackTicketStore(root).read();
    expect(
      stored.map((FeedbackTicket t) => t.id),
      unorderedEquals(<String>['abcdefghij', 'klmnopqrst']),
      reason: '上次没落下的回执随下一次落盘写下',
    );
    expect(
      stored.firstWhere((FeedbackTicket t) => t.id == 'abcdefghij').ticket,
      'T' * 32,
    );
  });

  test('幂等键随正文发出；服务端回同一条（重试）时清单里只有一条', () async {
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
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final FeedbackService s = service();
    final String key = newFeedbackSubmissionKey();
    expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{32}$')));
    expect(newFeedbackSubmissionKey(), isNot(key));
    final FeedbackDraft draft = FeedbackDraft(
      category: FeedbackCategory.bug,
      title: 't',
      body: 'b',
      includeLogs: false,
      includeDeviceInfo: false,
      submissionKey: key,
    );
    await s.submit(draft);
    await s.submit(draft);
    final List<http.Request> submits = requests
        .where((http.Request r) => r.url.path == '/v1/feedback')
        .toList();
    expect(submits, hasLength(2));
    for (final http.Request r in submits) {
      expect(
        (jsonDecode(r.body) as Map<String, dynamic>)['submissionKey'],
        key,
      );
    }
    expect(
      s.tickets.where((FeedbackTicket t) => t.id == 'abcdefghij'),
      hasLength(1),
    );
    expect(await FeedbackTicketStore(root).read(), hasLength(1));
  });

  test('关掉日志与设备信息：不传日志、meta 只剩计数、不带安装 id', () async {
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
    expect(
      (jsonDecode(requests.single.body) as Map<String, dynamic>).containsKey(
        'installId',
      ),
      isFalse,
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

  test('已结案的反馈照样刷新：修复的发布进度跟着更新并落盘；撤销标记后清掉', () async {
    // 契约：resolved 但带 app 修复、本平台正式版还没发布的反馈要继续刷新进度。
    // 刷新是「打开反馈中心时拉全部本机记录」，不能因为已结案就跳过。
    await FeedbackTicketStore(root).write(<FeedbackTicket>[
      const FeedbackTicket(
        id: 'aaaaaaaaaa',
        ticket: 'ta',
        title: 'a',
        category: FeedbackCategory.bug,
        createdAt: 1000,
        status: FeedbackStatus.resolved,
        updatedAt: 1000,
        seenAt: 1000,
      ),
    ]);
    Map<String, dynamic>? fix = <String, dynamic>{
      'sha': '0123456789abcdef0123456789abcdef01234567',
      'scope': 'app',
      'at': 1500,
      'releases': <String, dynamic>{
        'debug': <String, dynamic>{
          'android': <String, dynamic>{
            'version': '2.3.0-debug.150',
            'at': 1600,
          },
        },
      },
    };
    handler = (http.Request r) async => _json(<String, dynamic>{
      'items': <Object>[
        <String, dynamic>{
          ..._summary('aaaaaaaaaa', status: 'resolved', updatedAt: 1600),
          'fix': fix,
        },
      ],
    });
    final FeedbackService s = service();
    await s.refresh();
    expect(
      requests.single.body,
      contains('aaaaaaaaaa'),
      reason: '已结案的反馈也要带进批量查询',
    );
    final FeedbackFix got = s.byId('aaaaaaaaaa')!.fix!;
    expect(got.release('debug', 'android')!.version, '2.3.0-debug.150');
    // 落盘：重开服务也读得到（列表离线也能显示「已修复」）。
    final FeedbackTicket stored = (await FeedbackTicketStore(
      root,
    ).read()).single;
    expect(stored.fix!.sha, '0123456789abcdef0123456789abcdef01234567');
    expect(stored.fix!.release('debug', 'android')!.at, 1600);

    // 开发者撤销了修复标记：以服务端为准清掉。
    fix = null;
    await s.refresh();
    expect(s.byId('aaaaaaaaaa')!.fix, isNull);
    expect((await FeedbackTicketStore(root).read()).single.fix, isNull);
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

  test('同一清单并发写入：依次落盘不互相挪走临时文件，最后一次调用为准', () async {
    FeedbackTicket ticket(String id) => FeedbackTicket(
      id: id,
      ticket: 't-$id',
      title: id,
      category: FeedbackCategory.bug,
      createdAt: 1,
      status: FeedbackStatus.open,
      updatedAt: 1,
    );
    // 每次 new 一个实例：串行化必须按文件路径，而不是按实例。
    final List<Future<void>> writes = <Future<void>>[
      for (int i = 0; i < 20; i++)
        FeedbackTicketStore(
          root,
        ).write(<FeedbackTicket>[ticket('id${i.toString().padLeft(8, '0')}')]),
    ];
    await Future.wait(writes);
    final List<FeedbackTicket> read = await FeedbackTicketStore(root).read();
    expect(read.map((FeedbackTicket t) => t.id), <String>['id00000019']);
    expect(
      File('${FeedbackTicketStore(root).file.path}.tmp').existsSync(),
      isFalse,
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
