// 反馈视频附件 + 跨设备「我的反馈」的服务层：
// - 视频先在本机准备（转码），太大 / 不是视频时反馈根本不提交；
// - 视频最后传、带 Content-Length 流式 PUT 到 v0；传失败留在待传区，重试成功后清掉；
// - 已登录账户时「我的反馈」= 本机回执 ∪ GET /v1/feedback/mine（签名），按 id 去重、本机优先；
//   账户条目没有 ticket，看详情走账户签名、不带 X-Fushi-Ticket；缓存按账户落盘。

import 'dart:async';
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
    logText: ({required bool includeDebugLog}) => 'log',
    logEncoder: (String s) =>
        Uint8List.fromList(<int>[0x1f, 0x8b, ...utf8.encode(s)]),
    prepareVideo:
        prepare ??
        (
          File source,
          Directory work,
          void Function(double) onProgress,
          FeedbackVideoPrepareOptions _,
        ) async {
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

  test('BUG-3489 提交页先 stageVideo 再 submit：档位透传、不重复转码、工作目录清干净', () async {
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') return receipt(r);
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    final List<FeedbackVideoMode> modes = <FeedbackVideoMode>[];
    final FeedbackService s = service(
      prepare:
          (
            File src,
            Directory work,
            void Function(double) onProgress,
            FeedbackVideoPrepareOptions options,
          ) async {
            modes.add(options.mode);
            final File out = await src.copy(p.join(work.path, 'out.mp4'));
            return PreparedFeedbackVideo(
              file: out,
              contentType: 'video/mp4',
              bytes: await out.length(),
              transcoded: true,
            );
          },
    );
    final FeedbackStagedVideo staged = await s.stageVideo(
      source,
      options: const FeedbackVideoPrepareOptions(mode: FeedbackVideoMode.p1080),
    );
    final List<FeedbackSubmitStage> stages = <FeedbackSubmitStage>[];
    final FeedbackSubmitResult result = await s.submit(
      FeedbackDraft(
        category: FeedbackCategory.bug,
        title: 't',
        body: 'b',
        includeLogs: false,
        video: source,
      ),
      stagedVideo: staged,
      onStage: stages.add,
    );
    expect(result.failedAttachments, 0);
    expect(modes, <FeedbackVideoMode>[FeedbackVideoMode.p1080]);
    expect(stages, <FeedbackSubmitStage>[
      FeedbackSubmitStage.sending,
      FeedbackSubmitStage.video,
    ]);
    expect(
      requests.map((http.Request r) => r.url.path),
      contains('/v1/feedback/abcdefghij/attachments/v0'),
    );
    // 压缩产物已挪进待传区并传完；工作目录归调用方，discard 后清干净。
    expect(staged.video.file.existsSync(), isFalse);
    await staged.discard();
    expect(
      Directory(p.join(root.path, 'feedback', 'video_work')).listSync(),
      isEmpty,
    );
  });

  test('BUG-3489 正文没发出去：压好的视频留着，原样再提交不用重压', () async {
    int posts = 0;
    handler = (http.Request r) async {
      if (r.url.path == '/v1/feedback') {
        if (posts++ == 0) return _json(<String, dynamic>{'error': 'x'}, 503);
        return receipt(r);
      }
      return _json(<String, dynamic>{'slot': 'x'}, 201);
    };
    int prepared = 0;
    final FeedbackService s = service(
      prepare:
          (
            File src,
            Directory work,
            void Function(double) onProgress,
            FeedbackVideoPrepareOptions options,
          ) async {
            prepared++;
            final File out = await src.copy(p.join(work.path, 'out.mp4'));
            return PreparedFeedbackVideo(
              file: out,
              contentType: 'video/mp4',
              bytes: await out.length(),
              transcoded: true,
            );
          },
    );
    final FeedbackStagedVideo staged = await s.stageVideo(source);
    final FeedbackDraft draft = FeedbackDraft(
      category: FeedbackCategory.bug,
      title: 't',
      body: 'b',
      includeLogs: false,
      video: source,
    );
    await expectLater(s.submit(draft, stagedVideo: staged), throwsA(anything));
    expect(staged.video.file.existsSync(), isTrue);
    final FeedbackSubmitResult result = await s.submit(
      draft,
      stagedVideo: staged,
    );
    expect(result.failedAttachments, 0);
    expect(prepared, 1);
    await staged.discard();
  });

  test('BUG-3489 stageVideo 被取消：抛取消、工作目录清掉、什么也没发', () async {
    handler = receipt;
    final FeedbackService s = service(
      prepare:
          (
            File src,
            Directory work,
            void Function(double) onProgress,
            FeedbackVideoPrepareOptions options,
          ) async {
            File(p.join(work.path, 'half.mp4')).writeAsBytesSync(<int>[1, 2]);
            await options.cancel;
            throw const FeedbackVideoCancelledException();
          },
    );
    final Completer<void> cancel = Completer<void>();
    final Future<FeedbackStagedVideo> job = s.stageVideo(
      source,
      options: FeedbackVideoPrepareOptions(cancel: cancel.future),
    );
    cancel.complete();
    await expectLater(job, throwsA(isA<FeedbackVideoCancelledException>()));
    expect(
      Directory(p.join(root.path, 'feedback', 'video_work')).listSync(),
      isEmpty,
    );
    expect(requests, isEmpty);
  });

  test('视频太大：准备阶段就抛，正文不提交', () async {
    handler = receipt;
    final FeedbackService s = service(
      prepare:
          (
            File _,
            Directory _,
            void Function(double) _,
            FeedbackVideoPrepareOptions _,
          ) async =>
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

    // BUG-4502：冷启动时排行榜账户文件比反馈服务晚读出来（load 时身份还是 null）。
    // 此前随后的刷新把账户列表清空、用 seenAt=0 的条目重建并覆盖缓存，读过的回复
    // 每次重启都回到「新回复」。
    test('load 时身份未就绪：刷新后已读状态仍从账户缓存恢复，不再回到新回复', () async {
      final Map<String, dynamic> replied = <String, dynamic>{
        ..._summary('otherdev01'),
        'devReplyAt': 1500,
        'updatedAt': 1500,
      };
      handler = (http.Request r) async {
        if (r.url.path == '/v1/feedback/mine') {
          return _json(<String, dynamic>{
            'items': <Object>[replied],
            'next': null,
          });
        }
        if (r.url.path == '/v1/feedback/otherdev01') {
          return _json(<String, dynamic>{
            ...replied,
            'body': 'body-otherdev01',
            'attachments': <Object>[],
            'messages': <Object>[],
          });
        }
        return _json(<String, dynamic>{}, 404);
      };
      final FeedbackService first = service();
      await first.refresh();
      expect(first.byId('otherdev01')!.hasUnseenReply, isTrue);
      await first.detail('otherdev01');
      expect(first.byId('otherdev01')!.hasUnseenReply, isFalse);
      expect(first.unseenCount, 0);

      // 「重启」：新服务 load 那一刻账户还没读出来。
      final LeaderboardIdentity account = identity!;
      identity = null;
      final FeedbackService relaunched = service();
      await relaunched.load();
      identity = account;
      await relaunched.refresh();
      expect(relaunched.byId('otherdev01')!.hasUnseenReply, isFalse);
      expect(relaunched.unseenCount, 0);

      // 覆盖写回的缓存也保住了已读时刻：再「重启」一次照样是已读。
      final FeedbackService third = service();
      await third.load();
      expect(third.byId('otherdev01')!.hasUnseenReply, isFalse);
    });

    test('拉取 mine 期间身份短暂归 null（并发 refresh 置空状态）后恢复同一账户：保留已读并可继续落盘', () async {
      Map<String, dynamic> replied(String id, {int createdAt = 1000}) =>
          <String, dynamic>{
            ..._summary(id, createdAt: createdAt),
            'devReplyAt': 1500,
            'updatedAt': 1500,
          };
      Completer<void>? mineArrived;
      Completer<void>? mineRelease;
      handler = (http.Request r) async {
        if (r.url.path == '/v1/feedback/mine') {
          if (mineArrived != null && !mineArrived.isCompleted) {
            mineArrived.complete();
          }
          if (mineRelease != null) await mineRelease.future;
          return _json(<String, dynamic>{
            'items': <Object>[
              replied('otherdev01', createdAt: 2000),
              replied('otherdev02', createdAt: 1000),
            ],
            'next': null,
          });
        }
        if (r.url.path == '/v1/feedback/otherdev01' ||
            r.url.path == '/v1/feedback/otherdev02') {
          final String id = r.url.pathSegments.last;
          return _json(<String, dynamic>{
            ...replied(id),
            'body': 'body-$id',
            'attachments': <Object>[],
            'messages': <Object>[],
          });
        }
        return _json(<String, dynamic>{}, 404);
      };

      final FeedbackService first = service();
      await first.refresh();
      await first.detail('otherdev01');
      expect(first.byId('otherdev01')!.hasUnseenReply, isFalse);
      expect(first.byId('otherdev01')!.seenAt, 1500);
      expect(first.unseenCount, 1);

      mineArrived = Completer<void>();
      mineRelease = Completer<void>();
      final Future<void> r1 = first.refresh();
      await mineArrived.future;

      final LeaderboardIdentity account = identity!;
      identity = null;
      final Future<void> r2 = first.refresh();
      await pumpEventQueue();
      expect(first.byId('otherdev01'), isNull);

      identity = account;
      mineRelease.complete();
      await Future.wait<void>(<Future<void>>[r1, r2]);

      final FeedbackTicket after1 = first.byId('otherdev01')!;
      expect(after1.hasUnseenReply, isFalse);
      expect(after1.seenAt, 1500);
      expect(after1.body, 'body-otherdev01');
      expect(first.unseenCount, 1);

      // 恢复后 _accountKey 必须仍在位：继续点击第二条也应真实落盘。
      await first.detail('otherdev02');
      expect(first.unseenCount, 0);

      final FeedbackService relaunched = service();
      await relaunched.load();
      expect(relaunched.byId('otherdev01')!.hasUnseenReply, isFalse);
      expect(relaunched.byId('otherdev01')!.body, 'body-otherdev01');
      expect(relaunched.byId('otherdev02')!.hasUnseenReply, isFalse);
      expect(relaunched.unseenCount, 0);
    });

    test(
      '并发 refresh 撞上 _switchAccount 正在读缓存：等待读完再合并，不以 seenAt=0 覆写落盘',
      () async {
        final LeaderboardIdentity account = identity!;
        final Map<String, dynamic> replied = <String, dynamic>{
          ..._summary('otherdev01'),
          'devReplyAt': 1500,
          'updatedAt': 1500,
        };
        await FeedbackTicketStore.account(
          root,
          account.accountId,
        ).write(<FeedbackTicket>[
          const FeedbackTicket(
            id: 'otherdev01',
            ticket: '',
            title: 'server-otherdev01',
            category: FeedbackCategory.bug,
            createdAt: 1000,
            status: FeedbackStatus.open,
            updatedAt: 1500,
            devReplyAt: 1500,
            seenAt: 1500,
            body: 'body-otherdev01',
          ),
        ]);
        handler = (http.Request r) async {
          if (r.url.path == '/v1/feedback/mine') {
            return _json(<String, dynamic>{
              'items': <Object>[replied],
              'next': null,
            });
          }
          return _json(<String, dynamic>{}, 404);
        };

        Completer<Directory>? cacheReadGate;
        bool gatedOnce = false;
        final FeedbackService s = FeedbackService(
          supportRoot: () async {
            if (cacheReadGate != null && !gatedOnce) {
              gatedOnce = true;
              return cacheReadGate.future;
            }
            return root;
          },
          client: client,
        );

        // 先以 null 身份完成 load，随后身份就绪，卡住第一次切换账户时的读缓存。
        identity = null;
        await s.load();
        identity = account;
        cacheReadGate = Completer<Directory>();

        final Future<void> r1 = s.refresh();
        await pumpEventQueue();
        final Future<void> r2 = s.refresh();
        await pumpEventQueue();
        expect(
          requests,
          isEmpty,
          reason: '并发 refresh 须等在途读缓存完成，不能先空表跑 _refreshAccount',
        );

        cacheReadGate.complete(root);
        await Future.wait<void>(<Future<void>>[r1, r2]);

        final FeedbackTicket? restored = s.byId('otherdev01');
        expect(restored, isNotNull);
        expect(restored!.hasUnseenReply, isFalse);
        expect(restored.seenAt, 1500);
        expect(restored.body, 'body-otherdev01');

        final FeedbackService relaunched = service();
        await relaunched.load();
        expect(relaunched.byId('otherdev01')!.hasUnseenReply, isFalse);
        expect(relaunched.byId('otherdev01')!.body, 'body-otherdev01');
      },
    );

    test('在途 detail 返回前已退出登录：不回写已清空的账户列表、不覆盖原账户缓存', () async {
      final LeaderboardIdentity account = identity!;
      final Map<String, dynamic> initial = <String, dynamic>{
        ..._summary('otherdev01'),
        'devReplyAt': 1500,
        'updatedAt': 1500,
      };
      final Map<String, dynamic> newer = <String, dynamic>{
        ..._summary('otherdev01'),
        'devReplyAt': 2500,
        'updatedAt': 2500,
      };
      Completer<void>? detailArrived;
      Completer<void>? detailRelease;
      handler = (http.Request r) async {
        if (r.url.path == '/v1/feedback/mine') {
          return _json(<String, dynamic>{
            'items': <Object>[initial],
            'next': null,
          });
        }
        if (r.url.path == '/v1/feedback/otherdev01') {
          if (detailRelease == null) {
            return _json(<String, dynamic>{
              ...initial,
              'body': 'body-otherdev01',
              'attachments': <Object>[],
              'messages': <Object>[],
            });
          }
          detailArrived!.complete();
          await detailRelease.future;
          return _json(<String, dynamic>{
            ...newer,
            'body': 'updated-body',
            'attachments': <Object>[],
            'messages': <Object>[],
          });
        }
        return _json(<String, dynamic>{}, 404);
      };

      final FeedbackService s = service();
      await s.refresh();
      await s.detail('otherdev01');

      detailArrived = Completer<void>();
      detailRelease = Completer<void>();
      final Future<FeedbackDetail> pending = s.detail('otherdev01');
      await detailArrived.future;

      identity = null;
      await s.refresh();
      expect(s.byId('otherdev01'), isNull);

      detailRelease.complete();
      await pending;

      expect(s.byId('otherdev01'), isNull);
      expect(s.tickets, isEmpty);
      final List<FeedbackTicket> persisted = await FeedbackTicketStore.account(
        root,
        account.accountId,
      ).read();
      expect(persisted, hasLength(1));
      expect(persisted.single.seenAt, 1500);
      expect(persisted.single.body, 'body-otherdev01');
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

    // review of PR #2103：清旧账户列表原本排在批量查进度之后，断网时那一步先抛，
    // 换账户 / 退出登录后旧账户的工单标题一直挂在列表里。
    for (final bool signOut in <bool>[false, true]) {
      test('${signOut ? '退出登录' : '换账户'}后刷新断网：旧账户的列表照样立刻丢掉', () async {
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
          return _json(<String, dynamic>{
            'items': <Object>[_summary('otherdev01')],
            'next': null,
          });
        };
        final FeedbackService s = service();
        await s.refresh();
        expect(s.byId('otherdev01'), isNotNull);

        identity = signOut ? null : LeaderboardIdentity.generate();
        handler = (http.Request r) async =>
            throw const SocketException('offline');
        int notified = 0;
        s.addListener(() => notified++);
        await expectLater(s.refresh(), throwsA(anything));
        expect(s.byId('otherdev01'), isNull);
        expect(s.tickets.map((FeedbackTicket t) => t.id), <String>[
          'localloc00',
        ], reason: '本机回执不受换账户影响，只丢账户列表');
        expect(notified, greaterThan(0));
      });
    }
  });
}
