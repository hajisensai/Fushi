import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_skills.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';

/// 脚本化的技能上下文：按 (工具 id, 关键参数) 回放结果，记下每次调用。
class _Context implements AgentSkillContext {
  _Context(this.respond, {this.pick});

  final AgentToolResult Function(String id, Map<String, Object?> args) respond;
  final String? Function(String prompt, List<AgentChoiceOption> options)? pick;
  final List<(String, Map<String, Object?>, bool)> calls =
      <(String, Map<String, Object?>, bool)>[];
  final List<List<String>> cards = <List<String>>[];

  @override
  bool get cancelled => false;

  @override
  Future<AgentToolResult> call(
    String toolId,
    Map<String, Object?> args, {
    bool userChoseThisStep = false,
  }) async {
    calls.add((toolId, args, userChoseThisStep));
    return respond(toolId, args);
  }

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async {
    cards.add(<String>[for (final AgentChoiceOption o in options) o.id]);
    return pick?.call(prompt, options);
  }
}

AgentToolResult _ok(Map<String, Object?> data) => AgentToolResult.ok(data);

void main() {
  group('skill.subtitles.fill', () {
    test('自动装上的、已有的、有候选让用户挑的、都没有走 ASR 的，各归各类', () async {
      final _Context context = _Context((String id, Map<String, Object?> args) {
        final String book = '${args['bookUid'] ?? ''}';
        switch (id) {
          case 'video.subtitle.fetch':
            return _ok(<String, Object?>{
              'outcome': switch (book) {
                'e1' => 'installed',
                'e2' => 'alreadyHasSubtitle',
                _ => 'allCandidatesRejected',
              },
            });
          case 'video.subtitle.search':
            return _ok(<String, Object?>{
              'title': 'Show',
              'candidates': book == 'e3'
                  ? <Object?>[
                      <String, Object?>{
                        'id': 'vs1',
                        'fileName': 'a.srt',
                        'provider': 'jimaku',
                      },
                      <String, Object?>{
                        'id': 'vs2',
                        'fileName': 'b.srt',
                        'provider': 'subdl',
                      },
                    ]
                  : const <Object?>[],
            });
          case 'video.subtitle.download':
            return _ok(const <String, Object?>{'outcome': 'installed'});
          case 'video.subtitle.generate':
            return _ok(const <String, Object?>{'jobId': 'j1'});
        }
        return const AgentToolResult.error('unknown_tool');
      }, pick: (String _, List<AgentChoiceOption> options) => options.last.id);
      final Object? summary = await SubtitleFillSkill().run(
        context,
        <String, Object?>{
          'bookUids': <String>['e1', 'e2', 'e3', 'e4'],
          'language': 'ja',
        },
      );
      expect(summary, <String, Object?>{
        'installed': <String>['e1'],
        'pickedByUser': <String>['e3'],
        'generatingWithAsr': <String>['e4'],
        'alreadyHadOrSkipped': <String>['e2'],
        'noSubtitle': <String>[],
        'failed': <String>[],
      });
      expect(context.cards, <List<String>>[
        <String>['vs1', 'vs2'],
      ]);
      expect(
        context.calls
            .where(
              ((String, Map<String, Object?>, bool) c) =>
                  c.$1 == 'video.subtitle.download',
            )
            .single
            .$2,
        <String, Object?>{'id': 'vs2'},
      );
      // 语言透传给 fetch / search。
      expect(context.calls.first.$2, <String, Object?>{
        'bookUid': 'e1',
        'language': 'ja',
      });
    });

    test('asrFallback=false：都没有就记为 noSubtitle，不生成', () async {
      final _Context context = _Context(
        (String id, Map<String, Object?> _) => switch (id) {
          'video.subtitle.fetch' => _ok(const <String, Object?>{
            'outcome': 'noCandidate',
          }),
          'video.subtitle.search' => _ok(const <String, Object?>{
            'candidates': <Object?>[],
          }),
          _ => const AgentToolResult.error('unexpected'),
        },
      );
      final Map<Object?, Object?> summary =
          await SubtitleFillSkill().run(context, <String, Object?>{
                'bookUids': <String>['e1'],
                'asrFallback': false,
              })
              as Map<Object?, Object?>;
      expect(summary['noSubtitle'], <String>['e1']);
      expect(
        context.calls.map(((String, Map<String, Object?>, bool) c) => c.$1),
        isNot(contains('video.subtitle.generate')),
      );
    });

    test('bookUids 为空：整体失败', () {
      expect(
        () => SubtitleFillSkill().run(
          _Context(
            (String _, Map<String, Object?> _) =>
                _ok(const <String, Object?>{}),
          ),
          const <String, Object?>{},
        ),
        throwsA(isA<AgentSkillFailure>()),
      );
    });
  });

  group('skill.scrape.resolve', () {
    test('每部作品出候选卡；点中的那一项按「用户已选」认领，跳过的留在队列', () async {
      final _Context context = _Context(
        (String id, Map<String, Object?> args) => switch (id) {
          'video.work.list' => _ok(<String, Object?>{
            'works': <Object?>[
              <String, Object?>{'id': 'w1', 'title': 'Alpha'},
              <String, Object?>{'id': 'w2', 'title': 'Beta'},
              <String, Object?>{'id': 'w3', 'title': 'Gamma'},
            ],
          }),
          'video.work.candidates' => _ok(<String, Object?>{
            'candidates': args['id'] == 'w3'
                ? const <Object?>[]
                : <Object?>[
                    <String, Object?>{
                      'identity': 'anidb:1',
                      'provider': 'anidb',
                      'externalId': '1',
                      'mediaKind': 'tv',
                      'title': 'A',
                      'year': 2020,
                    },
                  ],
          }),
          'video.work.identify' => _ok(const <String, Object?>{'ok': true}),
          _ => const AgentToolResult.error('unknown_tool'),
        },
        pick: (String prompt, List<AgentChoiceOption> options) =>
            prompt.contains('Alpha') ? options.single.id : null,
      );
      final Object? summary = await ScrapeResolveSkill().run(
        context,
        const <String, Object?>{},
      );
      expect(summary, <String, Object?>{
        'pendingTotal': 3,
        'identified': <String>['Alpha'],
        'leftPending': <String>['Beta'],
        'noCandidates': <String>['Gamma'],
        'failed': <String>[],
      });
      final (String, Map<String, Object?>, bool) identify = context.calls
          .singleWhere(
            ((String, Map<String, Object?>, bool) c) =>
                c.$1 == 'video.work.identify',
          );
      expect(identify.$2, <String, Object?>{
        'id': 'w1',
        'provider': 'anidb',
        'externalId': '1',
        'type': 'tv',
        'wait': false,
      });
      expect(identify.$3, isTrue, reason: '候选卡即确认');
    });
  });
}
