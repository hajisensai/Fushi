import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';

import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart';
import 'package:fushi/src/media/acquisition/media_acquisition_backends.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/ops/ctl_ai_download_routes.dart';
import 'package:fushi/src/ops/ctl_ai_download_session.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 这些用例只走注入的假会话；任何 ref 访问都说明路由越界读了 app 状态。
class _NoRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('不应访问 ref：${invocation.memberName}');
}

class _FakeBackend implements MediaAcquisitionBackend {
  _FakeBackend(this.titles);

  final List<String> titles;
  final List<String> queries = <String>[];

  @override
  Future<List<MediaAcquisitionCandidate>> search(String query) async {
    queries.add(query);
    return <MediaAcquisitionCandidate>[
      for (int i = 0; i < titles.length; i++)
        MediaAcquisitionCandidate(
          id: 'f:$i',
          title: titles[i],
          sourceLabel: 'Fake',
          backend: this,
          payload: titles[i],
          score: titles.length - i,
        ),
    ];
  }

  @override
  Future<DownloadStartResult> acquire(
    BuildContext context,
    MediaAcquisitionCandidate candidate,
  ) => throw UnimplementedError('会话应走注入的 acquire');
}

AiMediaAcquisitionAi _fakeAi({List<String> picks = const <String>['f:1']}) =>
    AiMediaAcquisitionAi(
      parseIntent: (AiMediaAcquisitionDomain domain, String utterance) async =>
          const AiMediaAcquisitionIntent(queries: <String>['葬送のフリーレン']),
      pick:
          (
            AiMediaAcquisitionDomain domain,
            String request,
            List<AiMediaAcquisitionCandidateFact> candidates,
          ) async => picks,
    );

/// 等到会话快照满足 [test]（会话的效果链全是微任务 / 已完成的 Future）。
Future<Map<String, Object?>> _until(
  HostAssistantSession session,
  bool Function(Map<String, Object?> view) test,
) async {
  if (test(session.snapshot())) return session.snapshot();
  await session.changes
      .firstWhere((_) => test(session.snapshot()))
      .timeout(const Duration(seconds: 5));
  return session.snapshot();
}

List<Map<String, Object?>> _candidates(Map<String, Object?> view) =>
    (view['candidates']! as List<Object?>).cast<Map<String, Object?>>();

/// 视频会话的替身：记录收到的动作，问题由测试摆好。
class _FakeVideoSession implements HostAssistantSession {
  _FakeVideoSession();

  final List<Map<String, Object?>> actions = <Map<String, Object?>>[];
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _revision = 0;
  Map<String, Object?> view = <String, Object?>{'stage': 'idle', 'busy': false};
  bool closed = false;

  @override
  int get revision => _revision;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Map<String, Object?> snapshot() => view;

  @override
  Future<void> act(Map<String, Object?> action) async {
    actions.add(action);
    if (action['type'] == 'text') {
      view = <String, Object?>{
        'stage': 'awaitingWorkChoice',
        'busy': false,
        'question': <String, Object?>{
          'slot': 'work',
          'options': <Object?>[
            <String, Object?>{'id': 'work:0', 'label': 'Frieren (2023)'},
            <String, Object?>{'id': 'work:1', 'label': 'Frieren (Movie)'},
          ],
        },
      };
    } else if (action['type'] == 'choose') {
      view = <String, Object?>{
        'stage': 'awaitingResourceConfirm',
        'busy': false,
        'question': <String, Object?>{
          'slot': 'resource',
          'options': <Object?>[
            <String, Object?>{'id': 'accept'},
            <String, Object?>{'id': 'cancel'},
          ],
        },
      };
    } else if (action['type'] == 'confirm') {
      view = <String, Object?>{'stage': 'done', 'busy': false};
    }
    _revision++;
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _changes.close();
  }
}

void main() {
  group('CtlMediaAcquisitionSession', () {
    test('一句话 → 候选（推荐在前）→ choose → confirm 才下载', () async {
      final _FakeBackend backend = _FakeBackend(<String>['甲', '乙', '丙']);
      final List<String> acquired = <String>[];
      final CtlMediaAcquisitionSession session = CtlMediaAcquisitionSession(
        domain: AiMediaAcquisitionDomain.manga,
        ai: _fakeAi(),
        backends: <MediaAcquisitionBackend>[backend],
        acquire: (MediaAcquisitionCandidate c) async {
          acquired.add(c.id);
          return CtlMediaAcquireOutcome(started: true, taskId: 't-${c.id}');
        },
      );
      addTearDown(session.close);

      await session.act(<String, Object?>{'type': 'text', 'text': '芙莉莲漫画'});
      final Map<String, Object?> ready = await _until(
        session,
        (Map<String, Object?> v) => v['stage'] == 'ready',
      );
      // AI 解析的搜索词被拿去搜；AI 推荐的「乙」排第一。
      expect(backend.queries, <String>['葬送のフリーレン']);
      expect(ready['queries'], <String>['葬送のフリーレン']);
      expect(_candidates(ready).first['title'], '乙');
      expect(_candidates(ready).first['recommended'], isTrue);
      expect(ready['busy'], isFalse);
      // 推荐不等于下载：没 confirm 之前一条都不动。
      expect(acquired, isEmpty);

      await session.act(<String, Object?>{
        'type': 'choose',
        'optionIds': <String>['3', 'f:1'],
      });
      final Map<String, Object?> chosen = session.snapshot();
      expect(
        <Object?>[
          for (final Map<String, Object?> c in _candidates(chosen))
            c['selected'],
        ],
        <bool>[true, false, true],
      );

      await session.act(<String, Object?>{'type': 'confirm'});
      final Map<String, Object?> done = await _until(
        session,
        (Map<String, Object?> v) => v['busy'] == false,
      );
      expect(acquired, unorderedEquals(<String>['f:1', 'f:2']));
      expect(_candidates(done).first['status'], 'started');
      expect(_candidates(done).first['taskId'], 't-f:1');
      expect(_candidates(done)[1]['status'], 'idle');
    });

    test('时机不对抛 StateError，形状不对抛 ArgumentError', () async {
      final Completer<AiMediaAcquisitionIntent?> parse =
          Completer<AiMediaAcquisitionIntent?>();
      final CtlMediaAcquisitionSession session = CtlMediaAcquisitionSession(
        domain: AiMediaAcquisitionDomain.novel,
        ai: AiMediaAcquisitionAi(
          parseIntent: (AiMediaAcquisitionDomain d, String u) => parse.future,
          pick:
              (
                AiMediaAcquisitionDomain d,
                String r,
                List<AiMediaAcquisitionCandidateFact> c,
              ) async => null,
        ),
        backends: <MediaAcquisitionBackend>[
          _FakeBackend(<String>['甲']),
        ],
        acquire: (MediaAcquisitionCandidate c) async =>
            const CtlMediaAcquireOutcome(started: true),
      );
      addTearDown(session.close);

      expect(
        () => session.act(<String, Object?>{'type': 'text', 'text': ' '}),
        throwsArgumentError,
      );
      await session.act(<String, Object?>{'type': 'text', 'text': '某书'});
      expect(session.snapshot()['stage'], 'parsing');
      expect(session.snapshot()['busy'], isTrue);
      expect(
        () => session.act(<String, Object?>{
          'type': 'choose',
          'optionIds': <String>['1'],
        }),
        throwsStateError,
      );
      parse.complete(null);
      await _until(session, (Map<String, Object?> v) => v['stage'] == 'ready');
      expect(
        () => session.act(<String, Object?>{'type': 'confirm'}),
        throwsStateError,
        reason: '还没选候选',
      );
      expect(
        () => session.act(<String, Object?>{
          'type': 'choose',
          'optionIds': <String>['9'],
        }),
        throwsArgumentError,
      );
      expect(
        () => session.act(<String, Object?>{'type': 'zap'}),
        throwsArgumentError,
      );
    });

    test('cancel 停止搜索并取消已起的可取消任务', () async {
      final List<String> cancelled = <String>[];
      final CtlMediaAcquisitionSession session = CtlMediaAcquisitionSession(
        domain: AiMediaAcquisitionDomain.novel,
        ai: _fakeAi(picks: const <String>[]),
        backends: <MediaAcquisitionBackend>[
          _FakeBackend(<String>['甲']),
        ],
        acquire: (MediaAcquisitionCandidate c) async =>
            const CtlMediaAcquireOutcome(started: true, taskId: 't9'),
        cancelTask: cancelled.add,
      );
      addTearDown(session.close);
      await session.act(<String, Object?>{'type': 'text', 'text': '某书'});
      await _until(session, (Map<String, Object?> v) => v['stage'] == 'ready');
      await session.act(<String, Object?>{
        'type': 'choose',
        'optionIds': <String>['1'],
      });
      await session.act(<String, Object?>{'type': 'confirm'});
      await _until(session, (Map<String, Object?> v) => v['busy'] == false);

      await session.act(<String, Object?>{'type': 'cancel'});
      expect(cancelled, <String>['t9']);
      expect(session.snapshot()['stage'], 'cancelled');
    });
  });

  group('resolveCtlVideoChoice', () {
    final Map<String, Object?> view = <String, Object?>{
      'stage': 'collectingSlots',
      'question': <String, Object?>{
        'slot': 'quality',
        'options': <Object?>[
          <String, Object?>{'id': '1080p'},
          <String, Object?>{'id': '720p', 'label': 'HD'},
        ],
      },
    };

    test('按 id / 序号 / 文字作答', () {
      expect(resolveCtlVideoChoice(view, '1080p'), <String, Object?>{
        'type': 'choose',
        'slot': 'quality',
        'optionId': '1080p',
      });
      expect(resolveCtlVideoChoice(view, '2')['optionId'], '720p');
      expect(resolveCtlVideoChoice(view, 'hd')['optionId'], '720p');
      expect(
        resolveCtlVideoChoice(view, '#1', remember: true),
        <String, Object?>{
          'type': 'choose',
          'slot': 'quality',
          'optionId': '1080p',
          'remember': true,
        },
      );
    });

    test('没有问题 409、答案不在选项里 400', () {
      expect(
        () => resolveCtlVideoChoice(<String, Object?>{'stage': 'done'}, '1'),
        throwsStateError,
      );
      expect(() => resolveCtlVideoChoice(view, '4k'), throwsArgumentError);
    });
  });

  group('AI 下载会话路由（注入假会话）', () {
    late Map<String, CtlRoute> routes;
    late List<_FakeVideoSession> videos;
    late List<String> acquired;

    Future<Map<String, Object?>> call(
      String method,
      String pattern, {
      Map<String, String> params = const <String, String>{},
      Map<String, String> query = const <String, String>{},
      Map<String, Object?> body = const <String, Object?>{},
    }) async {
      final CtlRoute route = routes['$method $pattern']!;
      final Object? result = await route.handler(
        CtlCall(
          method: method,
          path: pattern,
          params: params,
          query: query,
          body: body,
        ),
      );
      return (result as Map<Object?, Object?>?)?.cast<String, Object?>() ??
          const <String, Object?>{};
    }

    setUp(() {
      videos = <_FakeVideoSession>[];
      acquired = <String>[];
      routes = <String, CtlRoute>{
        for (final CtlRoute r in buildAiDownloadCtlRoutes(
          OpContext(ref: _NoRef(), focusMainWindow: () async {}),
          open: (CtlAiDownloadFeature feature) async {
            if (feature == CtlAiDownloadFeature.video) {
              final _FakeVideoSession s = _FakeVideoSession();
              videos.add(s);
              return s;
            }
            return CtlMediaAcquisitionSession(
              domain: feature.mediaDomain!,
              ai: _fakeAi(),
              backends: <MediaAcquisitionBackend>[
                _FakeBackend(<String>['甲', '乙']),
              ],
              acquire: (MediaAcquisitionCandidate c) async {
                acquired.add(c.title);
                return const CtlMediaAcquireOutcome(started: true);
              },
            );
          },
        ))
          '${r.method} ${r.pattern}': r,
      };
    });

    const String base = '/api/admin/ai-download/sessions';

    test('视频：CLI 作答把会话从选作品推进到确认再到完成', () async {
      final Map<String, Object?> started = await call(
        'POST',
        base,
        body: <String, Object?>{'domain': 'video', 'text': '芙莉莲'},
      );
      final String id = started['id']! as String;
      expect(started['domain'], 'video');
      expect(
        (started['view']! as Map<Object?, Object?>)['stage'],
        'awaitingWorkChoice',
      );

      final Map<String, Object?> chose = await call(
        'POST',
        '$base/:id/choose',
        params: <String, String>{'id': id},
        body: <String, Object?>{
          'answers': <String>['2'],
        },
      );
      expect(videos.single.actions[1], <String, Object?>{
        'type': 'choose',
        'slot': 'work',
        'optionId': 'work:1',
      });
      expect(
        (chose['view']! as Map<Object?, Object?>)['stage'],
        'awaitingResourceConfirm',
      );

      final Map<String, Object?> done = await call(
        'POST',
        '$base/:id/confirm',
        params: <String, String>{'id': id},
      );
      expect((done['view']! as Map<Object?, Object?>)['stage'], 'done');

      final Map<String, Object?> listed = await call('GET', base);
      expect(
        (listed['sessions']! as List<Object?>).single,
        containsPair('id', id),
      );
      await call('DELETE', '$base/:id', params: <String, String>{'id': id});
      expect(videos.single.closed, isTrue);
      await expectLater(
        call('GET', '$base/:id', params: <String, String>{'id': id}),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
        ),
      );
    });

    test('视频：答案不在选项里 400，多答 400', () async {
      final String id =
          (await call(
                'POST',
                base,
                body: <String, Object?>{'domain': 'video', 'text': 'x'},
              ))['id']!
              as String;
      for (final List<String> answers in <List<String>>[
        <String>['9'],
        <String>['1', '2'],
      ]) {
        await expectLater(
          call(
            'POST',
            '$base/:id/choose',
            params: <String, String>{'id': id},
            body: <String, Object?>{'answers': answers},
          ),
          throwsA(
            isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
          ),
        );
      }
    });

    test('AI 下载：start --wait → choose 序号 → confirm 后才下载', () async {
      final Map<String, Object?> started = await call(
        'POST',
        base,
        body: <String, Object?>{'domain': 'novel', 'text': '某书', 'wait': 5},
      );
      final String id = started['id']! as String;
      final Map<Object?, Object?> view =
          started['view']! as Map<Object?, Object?>;
      expect(view['stage'], 'ready');
      expect(acquired, isEmpty);

      await expectLater(
        call('POST', '$base/:id/confirm', params: <String, String>{'id': id}),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 409),
        ),
      );
      await call(
        'POST',
        '$base/:id/choose',
        params: <String, String>{'id': id},
        body: <String, Object?>{
          'answers': <String>['1'],
        },
      );
      final Map<String, Object?> confirmed = await call(
        'POST',
        '$base/:id/confirm',
        params: <String, String>{'id': id},
        body: <String, Object?>{'wait': 5},
      );
      // 推荐的「乙」排第一，选的是 #1。
      expect(acquired, <String>['乙']);
      final List<Object?> candidates =
          (confirmed['view']! as Map<Object?, Object?>)['candidates']!
              as List<Object?>;
      expect((candidates.first! as Map<Object?, Object?>)['status'], 'started');
    });

    test('未知 domain 400', () async {
      await expectLater(
        call(
          'POST',
          base,
          body: <String, Object?>{'domain': 'music', 'text': 'x'},
        ),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
    });

    test('开不了的会话转成 422 并给出去哪配', () async {
      final CtlAiDownloadSessions sessions = CtlAiDownloadSessions(
        (CtlAiDownloadFeature f) async =>
            throw const HostAssistantUnavailable('no_provider'),
      );
      await expectLater(
        sessions.start(CtlAiDownloadFeature.video, 'x'),
        throwsA(
          isA<CtlFailure>()
              .having((CtlFailure f) => f.status, 'status', 422)
              .having(
                (CtlFailure f) => f.message,
                'message',
                contains('设置 › 模型 › LLM'),
              ),
        ),
      );
    });
  });
}
