import 'dart:async';
import 'dart:convert';
import 'dart:isolate' show ReceivePort;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/youtube_live_chat_replay.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;
import 'package:test/test.dart';

/// 拍板台 zTedU_pOQF：YouTube 聊天回放的解析与分页会话。fixture 的结构取自 2026-11 线上
/// `youtubei/v1/next` 与 `live_chat/get_live_chat_replay` 实测响应（字段裁剪到解析用到的）。

Map<String, Object?> _nextResponse({required bool? isReplay}) =>
    <String, Object?>{
      'contents': <String, Object?>{
        'twoColumnWatchNextResults': <String, Object?>{
          'conversationBar': <String, Object?>{
            'liveChatRenderer': <String, Object?>{
              'continuations': <Object?>[
                <String, Object?>{
                  'reloadContinuationData': <String, Object?>{
                    'continuation': 'ENTRY',
                  },
                },
              ],
              'isReplay': ?isReplay,
            },
          },
        },
      },
    };

Map<String, Object?> _textAction(
  String id,
  int offsetMs,
  List<Map<String, Object?>> runs, {
  String author = '@viewer',
}) => <String, Object?>{
  'replayChatItemAction': <String, Object?>{
    'actions': <Object?>[
      <String, Object?>{
        'addChatItemAction': <String, Object?>{
          'item': <String, Object?>{
            'liveChatTextMessageRenderer': <String, Object?>{
              'message': <String, Object?>{'runs': runs},
              'authorName': <String, Object?>{'simpleText': author},
              'id': id,
            },
          },
        },
      },
    ],
    'videoOffsetTimeMsec': '$offsetMs',
  },
};

Map<String, Object?> _page(
  List<Map<String, Object?>> actions, {
  String? next = 'NEXT',
  String? seek = 'SEEK',
}) => <String, Object?>{
  'continuationContents': <String, Object?>{
    'liveChatContinuation': <String, Object?>{
      'continuations': <Object?>[
        if (next != null)
          <String, Object?>{
            'liveChatReplayContinuationData': <String, Object?>{
              'timeUntilLastMessageMsec': 5000,
              'continuation': next,
            },
          },
        if (seek != null)
          <String, Object?>{
            'playerSeekContinuationData': <String, Object?>{
              'continuation': seek,
            },
          },
      ],
      'actions': actions,
    },
  },
};

YoutubeChatMessage _msg(String id, int offsetMs, [String text = 'x']) =>
    YoutubeChatMessage(id: id, offsetMs: offsetMs, author: 'a', text: text);

YoutubeChatReplayPage _pageOf(
  List<YoutubeChatMessage> messages, {
  String? next = 'NEXT',
  String? seek = 'SEEK',
  int? lastActionOffsetMs,
}) => YoutubeChatReplayPage(
  messages: messages,
  nextContinuation: next,
  seekContinuation: seek,
  lastActionOffsetMs: lastActionOffsetMs,
);

class _FakeFetch {
  final List<({String continuation, int offsetMs})> calls =
      <({String continuation, int offsetMs})>[];
  final List<Completer<YoutubeChatReplayPage>> pending =
      <Completer<YoutubeChatReplayPage>>[];

  Future<YoutubeChatReplayPage> call(String continuation, int offsetMs) {
    calls.add((continuation: continuation, offsetMs: offsetMs));
    final Completer<YoutubeChatReplayPage> c =
        Completer<YoutubeChatReplayPage>();
    pending.add(c);
    return c.future;
  }

  /// 完成第 [i] 个请求并让会话的后续逻辑跑完。
  Future<void> answer(int i, YoutubeChatReplayPage page) async {
    pending[i].complete(page);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> fail(int i) async {
    pending[i].completeError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('parseYoutubeChatReplayEntry', () {
    test('直播回放（isReplay: true）返回入口 continuation', () {
      expect(
        parseYoutubeChatReplayEntry(_nextResponse(isReplay: true)),
        'ENTRY',
      );
    });

    test('直播中 / 预约中（没有 isReplay）不算聊天回放', () {
      expect(
        parseYoutubeChatReplayEntry(_nextResponse(isReplay: null)),
        isNull,
      );
      expect(
        parseYoutubeChatReplayEntry(_nextResponse(isReplay: false)),
        isNull,
      );
    });

    test('普通视频（没有 conversationBar）返回 null', () {
      expect(
        parseYoutubeChatReplayEntry(<String, Object?>{
          'contents': <String, Object?>{
            'twoColumnWatchNextResults': <String, Object?>{},
          },
        }),
        isNull,
      );
    });

    test('响应不是观看页数据（被拦截 / 只回 error）抛 FormatException，不当成「没有」', () {
      expect(
        () => decodeYoutubeChatReplayEntry('[]'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodeYoutubeChatReplayEntry(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'message': 'Precondition check failed.'},
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            contains('Precondition check failed.'),
          ),
        ),
      );
    });
  });

  group('parseYoutubeChatReplayPage', () {
    test('文字段 / Unicode 表情 / 自定义表情短码拼成正文，按时间升序', () {
      final YoutubeChatReplayPage page = parseYoutubeChatReplayPage(
        _page(<Map<String, Object?>>[
          _textAction('b', 2000, <Map<String, Object?>>[
            <String, Object?>{'text': '今の'},
            <String, Object?>{
              'emoji': <String, Object?>{
                'emojiId': '😂',
                'shortcuts': <Object?>[':joy:'],
              },
            },
            <String, Object?>{
              'emoji': <String, Object?>{
                'emojiId': 'UCxx/abc',
                'shortcuts': <Object?>[':_shukkin:', ':shukkin:'],
                'isCustomEmoji': true,
              },
            },
          ], author: '@yuki'),
          _textAction('a', 1000, <Map<String, Object?>>[
            <String, Object?>{'text': ' 草 '},
          ]),
        ]),
      );
      expect(page.messages.map((YoutubeChatMessage m) => m.id), <String>[
        'a',
        'b',
      ]);
      expect(page.messages[0].text, '草');
      expect(page.messages[1].text, '今の😂:_shukkin:');
      expect(page.messages[1].author, '@yuki');
      expect(page.messages[1].offsetMs, 2000);
      expect(page.nextContinuation, 'NEXT');
      expect(page.seekContinuation, 'SEEK');
    });

    test('Super Chat 带金额；会员 / 占位 / 系统提示 / 空正文都丢掉', () {
      final Map<String, Object?> json = _page(<Map<String, Object?>>[
        <String, Object?>{
          'replayChatItemAction': <String, Object?>{
            'actions': <Object?>[
              <String, Object?>{
                'addChatItemAction': <String, Object?>{
                  'item': <String, Object?>{
                    'liveChatPaidMessageRenderer': <String, Object?>{
                      'id': 'paid',
                      'authorName': <String, Object?>{'simpleText': '@rich'},
                      'purchaseAmountText': <String, Object?>{
                        'simpleText': '¥1,000',
                      },
                    },
                  },
                },
              },
              <String, Object?>{
                'addChatItemAction': <String, Object?>{
                  'item': <String, Object?>{
                    'liveChatPlaceholderItemRenderer': <String, Object?>{
                      'id': 'ph',
                    },
                  },
                },
              },
              <String, Object?>{
                'addChatItemAction': <String, Object?>{
                  'item': <String, Object?>{
                    'liveChatViewerEngagementMessageRenderer':
                        <String, Object?>{'id': 'sys'},
                  },
                },
              },
              <String, Object?>{
                'addLiveChatTickerItemAction': <String, Object?>{},
              },
            ],
            'videoOffsetTimeMsec': '5000',
          },
        },
        _textAction('empty', 6000, <Map<String, Object?>>[]),
      ], next: null);
      final YoutubeChatReplayPage page = parseYoutubeChatReplayPage(json);
      expect(page.messages, hasLength(1));
      expect(page.messages.single.paidAmount, '¥1,000');
      expect(page.messages.single.text, '');
      expect(page.messages.single.author, '@rich');
      expect(page.nextContinuation, isNull);
      // 被过滤掉的动作也计入时间轴推进（空正文那条在 6000）。
      expect(page.lastActionOffsetMs, 6000);
    });

    test('一页全是被过滤掉的动作：messages 为空，lastActionOffsetMs 仍是最晚动作时刻', () {
      final YoutubeChatReplayPage page = parseYoutubeChatReplayPage(
        _page(<Map<String, Object?>>[
          _textAction('e1', 7000, <Map<String, Object?>>[]),
          _textAction('e2', 9000, <Map<String, Object?>>[]),
        ]),
      );
      expect(page.messages, isEmpty);
      expect(page.lastActionOffsetMs, 9000);
      expect(page.nextContinuation, 'NEXT');
    });

    test('认不出的结构是空页（无 continuation），非 JSON 对象抛 FormatException', () {
      final YoutubeChatReplayPage page = parseYoutubeChatReplayPage(
        <String, Object?>{'responseContext': <String, Object?>{}},
      );
      expect(page.messages, isEmpty);
      expect(page.nextContinuation, isNull);
      expect(
        () => decodeYoutubeChatReplayPage('[1]'),
        throwsA(isA<FormatException>()),
      );
      expect(
        decodeYoutubeChatReplayPage(
          jsonEncode(_page(<Map<String, Object?>>[])),
        ).nextContinuation,
        'NEXT',
      );
    });
  });

  test('请求体：WEB client + continuation + playerOffsetMs（负数夹到 0）', () {
    final Map<String, Object?> body = youtubeChatReplayRequestBody('C', -5);
    expect(body['continuation'], 'C');
    expect(
      (body['currentPlayerState']! as Map<String, Object?>)['playerOffsetMs'],
      '0',
    );
    final Map<String, Object?> client =
        (body['context']! as Map<String, Object?>)['client']!
            as Map<String, Object?>;
    expect(client['clientName'], 'WEB');
    expect(client['clientVersion'], kYoutubeChatWebClientVersion);
  });

  // BUG-5411：探测曾在 IO 函数体里 `Isolate.run(() => decode(body))`，闭包把作用域链上的
  // HTTP client（连接池里有未完成的 Future / 原生 socket）一起拷进 isolate 消息，拷贝必抛、
  // 被 catch 吞成「没有聊天回放」——生产上从没出过按钮。测试里的 transport 故意攥着一个
  // 不可发送的 ReceivePort（等同真实连接池），走与生产同一条 YoutubeHttpClient 链路。
  group('probeYoutubeChatReplay', () {
    late ReceivePort unsendable;
    late _RecordingLog log;
    late EngineLogSink previousLog;

    setUp(() {
      unsendable = ReceivePort();
      log = _RecordingLog();
      previousLog = engineLog;
      engineLog = log;
    });

    tearDown(() {
      unsendable.close();
      engineLog = previousLog;
    });

    /// [reply] 回 (状态码, UTF-8 正文)；响应带上 request，与真实 IOClient 一致
    /// （YoutubeHttpClient 校验状态码时要读它）。
    MockClient transport((int, String) Function(http.Request) reply) =>
        MockClient((http.Request request) async {
          // 让 transport 的闭包真正持有不可发送的对象。
          expect(unsendable.sendPort, isNotNull);
          final (int status, String body) = reply(request);
          return http.Response.bytes(
            utf8.encode(body),
            status,
            request: request,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        });

    test('有聊天回放：POST next 带 videoId，回入口 continuation', () async {
      http.Request? seen;
      final YoutubeChatReplayProbe probe = await probeYoutubeChatReplay(
        'vid123',
        transport: transport((http.Request r) {
          seen = r;
          return (200, jsonEncode(_nextResponse(isReplay: true)));
        }),
      );
      expect(
        probe,
        isA<YoutubeChatReplayAvailable>().having(
          (YoutubeChatReplayAvailable p) => p.entryContinuation,
          'entryContinuation',
          'ENTRY',
        ),
      );
      expect(seen!.url.path, '/youtubei/v1/next');
      expect(
        (jsonDecode(seen!.body) as Map<String, Object?>)['videoId'],
        'vid123',
      );
      expect(log.errors, isEmpty);
    });

    test('观看页正常但没有聊天回放 → Absent，不记错误', () async {
      final YoutubeChatReplayProbe probe = await probeYoutubeChatReplay(
        'vid123',
        transport: transport(
          (http.Request _) => (
            200,
            jsonEncode(<String, Object?>{
              'contents': <String, Object?>{
                'twoColumnWatchNextResults': <String, Object?>{},
              },
            }),
          ),
        ),
      );
      expect(probe, isA<YoutubeChatReplayAbsent>());
      expect(log.errors, isEmpty);
    });

    test('HTTP 错误 / 响应不是观看页数据 → ProbeFailed，并写诊断日志', () async {
      final YoutubeChatReplayProbe http403 = await probeYoutubeChatReplay(
        'vid403',
        transport: transport((http.Request _) => (403, 'nope')),
      );
      expect(http403, isA<YoutubeChatReplayProbeFailed>());
      final YoutubeChatReplayProbe blocked = await probeYoutubeChatReplay(
        'vidBlocked',
        transport: transport(
          (http.Request _) => (
            200,
            jsonEncode(<String, Object?>{
              'playabilityStatus': <String, Object?>{
                'status': 'LOGIN_REQUIRED',
              },
            }),
          ),
        ),
      );
      expect(blocked, isA<YoutubeChatReplayProbeFailed>());
      expect(log.errors, hasLength(2));
      expect(
        log.errors.first,
        startsWith('YoutubeChatReplay.probe: videoId=vid403'),
      );
      expect(log.errors.last, contains('LOGIN_REQUIRED'));
    });

    test('取页 fetcher 走同一条链路也能解析（transport 持有不可发送对象）', () async {
      final YoutubeChatReplayHttpFetcher fetcher = YoutubeChatReplayHttpFetcher(
        transport: transport(
          (http.Request _) => (
            200,
            jsonEncode(
              _page(<Map<String, Object?>>[
                _textAction('a', 1000, <Map<String, Object?>>[
                  <String, Object?>{'text': 'こんばんは'},
                ]),
              ], next: 'NEXT'),
            ),
          ),
        ),
      );
      addTearDown(fetcher.close);
      final YoutubeChatReplayPage page = await fetcher.fetch('ENTRY', 0);
      expect(page.messages.single.text, 'こんばんは');
      expect(page.nextContinuation, 'NEXT');
    });

    test('会话取页失败写诊断日志（不再静默吞掉）', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
      );
      unawaited(s.syncTo(0));
      await fetch.fail(0);
      expect(s.status, YoutubeChatReplayStatus.failed);
      expect(log.errors.single, startsWith('YoutubeChatReplay.page: '));
      expect(log.errors.single, contains('boom'));
    });
  });

  group('YoutubeChatReplaySession', () {
    test('首次同步用入口 continuation 从播放头跳转，窗口 = 这一页的范围', () async {
      final _FakeFetch fetch = _FakeFetch();
      int changes = 0;
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        onChanged: () => changes++,
        lookaheadMs: 10000,
      );
      expect(s.status, YoutubeChatReplayStatus.idle);
      unawaited(s.syncTo(600000));
      expect(fetch.calls.single, (continuation: 'ENTRY', offsetMs: 600000));
      expect(s.status, YoutubeChatReplayStatus.loading);
      // 在途时同一位置附近反复同步不重复打请求。
      unawaited(s.syncTo(600500));
      expect(fetch.calls, hasLength(1));
      await fetch.answer(
        0,
        _pageOf(<YoutubeChatMessage>[_msg('a', 591963), _msg('b', 615000)]),
      );
      expect(s.covered, (fromMs: 591963, toMs: 615000));
      expect(s.messages.map((YoutubeChatMessage m) => m.id), <String>[
        'a',
        'b',
      ]);
      expect(s.status, YoutubeChatReplayStatus.ready);
      // 离窗口尾 > lookahead：不再取。
      expect(fetch.calls, hasLength(1));
      expect(changes, greaterThan(0));
    });

    test('接近窗口尾就用 next continuation 接着取，重复消息去重', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(0));
      await fetch.answer(
        0,
        _pageOf(<YoutubeChatMessage>[_msg('a', 1000), _msg('b', 30000)]),
      );
      unawaited(s.syncTo(25000));
      expect(fetch.calls[1], (continuation: 'NEXT', offsetMs: 30000));
      await fetch.answer(
        1,
        _pageOf(<YoutubeChatMessage>[
          _msg('b', 30000),
          _msg('c', 50000),
        ], next: 'NEXT2'),
      );
      expect(s.messages.map((YoutubeChatMessage m) => m.id), <String>[
        'a',
        'b',
        'c',
      ]);
      expect(s.covered, (fromMs: 0, toMs: 50000));
    });

    test('拖到窗口外：清掉旧窗口，用 seek continuation 从新位置重开', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(100000));
      await fetch.answer(
        0,
        _pageOf(<YoutubeChatMessage>[_msg('a', 90000), _msg('b', 200000)]),
      );
      // 往回拖到窗口前。
      unawaited(s.syncTo(10000));
      expect(fetch.calls[1], (continuation: 'SEEK', offsetMs: 10000));
      expect(s.messages, isEmpty, reason: '旧窗口立刻作废，列表不显示别处的消息');
      await fetch.answer(1, _pageOf(<YoutubeChatMessage>[_msg('z', 5000)]));
      expect(s.messages.single.id, 'z');
      expect(s.covered, (fromMs: 5000, toMs: 10000));
    });

    test('跳转后旧请求晚到的结果作废', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(0));
      unawaited(s.syncTo(500000));
      expect(fetch.calls, hasLength(2));
      await fetch.answer(1, _pageOf(<YoutubeChatMessage>[_msg('new', 499000)]));
      await fetch.answer(0, _pageOf(<YoutubeChatMessage>[_msg('old', 100)]));
      expect(s.messages.map((YoutubeChatMessage m) => m.id), <String>['new']);
    });

    test('一页覆盖不到播放头 + lookahead 时自动接着取下一页', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 20000,
      );
      unawaited(s.syncTo(0));
      await fetch.answer(0, _pageOf(<YoutubeChatMessage>[_msg('a', 3000)]));
      expect(fetch.calls[1], (continuation: 'NEXT', offsetMs: 3000));
    });

    test('到头（没有 next continuation）后不再请求，往后拖也不重开窗口', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(0));
      await fetch.answer(
        0,
        _pageOf(<YoutubeChatMessage>[_msg('a', 1000)], next: null),
      );
      expect(s.status, YoutubeChatReplayStatus.ended);
      unawaited(s.syncTo(5000));
      unawaited(s.syncTo(9000000));
      expect(fetch.calls, hasLength(1));
    });

    test('接续页没带任何新消息就当到头，不原地打转', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(0));
      await fetch.answer(0, _pageOf(<YoutubeChatMessage>[_msg('a', 1000)]));
      await fetch.answer(1, _pageOf(<YoutubeChatMessage>[_msg('a', 1000)]));
      expect(s.status, YoutubeChatReplayStatus.ended);
      expect(fetch.calls, hasLength(2));
    });

    test('接续页只有被过滤掉的动作但时间轴往前走了：不算到头，接着取', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(0));
      await fetch.answer(0, _pageOf(<YoutubeChatMessage>[_msg('a', 1000)]));
      await fetch.answer(
        1,
        _pageOf(
          const <YoutubeChatMessage>[],
          next: 'NEXT2',
          lastActionOffsetMs: 4000,
        ),
      );
      expect(s.status, isNot(YoutubeChatReplayStatus.ended));
      expect(s.covered, (fromMs: 0, toMs: 4000));
      expect(fetch.calls[2], (continuation: 'NEXT2', offsetMs: 4000));
    });

    test('失败停在 failed、不自动重试；retry 按最后的播放头重新同步', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 10000,
      );
      unawaited(s.syncTo(42000));
      await fetch.fail(0);
      expect(s.status, YoutubeChatReplayStatus.failed);
      unawaited(s.syncTo(43000));
      expect(fetch.calls, hasLength(1));
      unawaited(s.retry());
      expect(fetch.calls[1], (continuation: 'ENTRY', offsetMs: 43000));
      await fetch.answer(1, _pageOf(<YoutubeChatMessage>[_msg('a', 42500)]));
      expect(s.status, isNot(YoutubeChatReplayStatus.failed));
    });

    test('超过 maxMessages 从最旧的一头裁（只裁播放头之前的），窗口起点随之后移', () async {
      final _FakeFetch fetch = _FakeFetch();
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        lookaheadMs: 1000,
        maxMessages: 3,
      );
      unawaited(s.syncTo(4500));
      await fetch.answer(
        0,
        _pageOf(<YoutubeChatMessage>[
          for (int i = 0; i < 5; i++) _msg('m$i', i * 1000),
        ]),
      );
      expect(s.messages.map((YoutubeChatMessage m) => m.id), <String>[
        'm2',
        'm3',
        'm4',
      ]);
      expect(s.covered!.fromMs, 2000);
    });

    test('dispose 后到达的结果与同步都不再生效', () async {
      final _FakeFetch fetch = _FakeFetch();
      int changes = 0;
      final YoutubeChatReplaySession s = YoutubeChatReplaySession(
        entryContinuation: 'ENTRY',
        fetch: fetch.call,
        onChanged: () => changes++,
      );
      unawaited(s.syncTo(0));
      final int before = changes;
      s.dispose();
      await fetch.answer(0, _pageOf(<YoutubeChatMessage>[_msg('a', 1)]));
      unawaited(s.syncTo(99999));
      expect(changes, before);
      expect(fetch.calls, hasLength(1));
      expect(s.messages, isEmpty);
    });
  });

  test('youtubeChatVisibleCount：播放头之前（含）已发出的条数', () {
    final List<YoutubeChatMessage> list = <YoutubeChatMessage>[
      _msg('a', 1000),
      _msg('b', 2000),
      _msg('c', 2000),
      _msg('d', 5000),
    ];
    expect(youtubeChatVisibleCount(list, 0), 0);
    expect(youtubeChatVisibleCount(list, 2000), 3);
    expect(youtubeChatVisibleCount(list, 4999), 3);
    expect(youtubeChatVisibleCount(list, 99999), 4);
  });
}

class _RecordingLog implements EngineLogSink {
  final List<String> errors = <String>[];

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      errors.add('$source: $error');

  @override
  void logDiagnostic(String source, Object info) {}

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      errors.add('$source: $error');
}
