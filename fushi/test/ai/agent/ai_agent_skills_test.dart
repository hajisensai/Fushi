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
        'reasons': <String, String>{'e4': 'allCandidatesRejected'},
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

    test('标了 mismatch 的候选不进卡片；全是 mismatch 按没有候选处理并给出原因', () async {
      final _Context context = _Context(
        (String id, Map<String, Object?> _) => switch (id) {
          'video.subtitle.fetch' => _ok(const <String, Object?>{
            'outcome': 'allCandidatesRejected',
          }),
          'video.subtitle.search' => _ok(const <String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{
                'id': 'vs1',
                'fileName': 'Show.S01E03.WEBRip.srt',
                'mismatch': 'release names a TV episode, target is a movie',
              },
              <String, Object?>{
                'id': 'vs2',
                'fileName': 'Show.S01E04.WEBRip.srt',
                'mismatch': 'release names a TV episode, target is a movie',
              },
            ],
          }),
          _ => const AgentToolResult.error('unexpected'),
        },
      );
      final Map<Object?, Object?> summary =
          await SubtitleFillSkill().run(context, <String, Object?>{
                'bookUids': <String>['m1'],
                'asrFallback': false,
              })
              as Map<Object?, Object?>;
      expect(context.cards, isEmpty);
      expect(summary['noSubtitle'], <String>['m1']);
      expect(
        (summary['reasons']! as Map<Object?, Object?>)['m1'],
        contains('target is a movie'),
      );
    });

    test('preferFormat=ass：ass 候选排在卡片最前，其余保持原序', () async {
      final _Context context = _Context(
        (String id, Map<String, Object?> _) => switch (id) {
          'video.subtitle.fetch' => _ok(const <String, Object?>{
            'outcome': 'allCandidatesRejected',
          }),
          'video.subtitle.search' => _ok(const <String, Object?>{
            'candidates': <Object?>[
              <String, Object?>{'id': 'vs1', 'fileName': 'a.srt'},
              <String, Object?>{'id': 'vs2', 'fileName': 'b.ass'},
              <String, Object?>{
                'id': 'vs3',
                'fileName': 'c.ass',
                'mismatch': 'other work',
              },
              <String, Object?>{'id': 'vs4', 'fileName': 'd.srt'},
            ],
          }),
          _ => const AgentToolResult.error('unexpected'),
        },
      );
      await SubtitleFillSkill().run(context, <String, Object?>{
        'bookUids': <String>['e1'],
        'preferFormat': '.ASS',
      });
      expect(context.cards, <List<String>>[
        <String>['vs2', 'vs1', 'vs4'],
      ]);
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

  group('skill.extension.find', () {
    AgentToolResult Function(String, Map<String, Object?>) app({
      required bool foundInExisting,
    }) {
      bool installed = false;
      return (String id, Map<String, Object?> args) {
        switch (id) {
          case 'online.source.list':
            return _ok(<String, Object?>{
              'sources': <Object?>[
                <String, Object?>{
                  'id': '1',
                  'name': 'Old',
                  'extension': 'pkg.old',
                  'enabled': true,
                  'lang': 'ja',
                },
                if (installed)
                  <String, Object?>{
                    'id': '2',
                    'name': 'New',
                    'extension': 'pkg.new',
                    'enabled': true,
                    'lang': 'ja',
                  },
              ],
            });
          case 'online.source.search':
            final bool hit = args['sourceId'] == 'pkg.new:2' || foundInExisting;
            return _ok(<String, Object?>{
              'items': hit
                  ? <Object?>[
                      <String, Object?>{'title': 'X vol.1'},
                    ]
                  : const <Object?>[],
            });
          case 'online.extension.list':
            return _ok(<String, Object?>{
              'available': <Object?>[
                <String, Object?>{
                  'id': 'pkg.low',
                  'name': 'Low',
                  'downloads': 5,
                },
                <String, Object?>{
                  'id': 'pkg.new',
                  'name': 'New',
                  'downloads': 50,
                  'repo': 'r',
                },
                <String, Object?>{
                  'id': 'pkg.nsfw',
                  'name': 'N',
                  'downloads': 999,
                  'nsfw': true,
                },
                <String, Object?>{
                  'id': 'pkg.old',
                  'name': 'Old',
                  'installed': true,
                },
              ],
            });
          case 'online.extension.install':
            installed = true;
            return _ok(const <String, Object?>{'ok': true});
        }
        return const AgentToolResult.error('unknown_tool');
      };
    }

    test('已装的源里搜得到：不装新扩展', () async {
      final _Context context = _Context(app(foundInExisting: true));
      final Map<Object?, Object?> summary =
          await ExtensionFindSkill().run(context, const <String, Object?>{
                'kind': 'manga',
                'title': 'X',
              })
              as Map<Object?, Object?>;
      expect(summary['alreadyAvailable'], <String, Object?>{
        'Old': <String>['X vol.1'],
      });
      expect(
        context.calls.map(((String, Map<String, Object?>, bool) c) => c.$1),
        isNot(contains('online.extension.install')),
      );
    });

    test('搜不到：候选按下载量、去掉成人与已装；安装照常出确认（D9），装完试搜', () async {
      final _Context context = _Context(
        app(foundInExisting: false),
        pick: (String _, List<AgentChoiceOption> options) => options.first.id,
      );
      final Map<Object?, Object?> summary =
          await ExtensionFindSkill().run(context, const <String, Object?>{
                'kind': 'manga',
                'title': 'X',
              })
              as Map<Object?, Object?>;
      expect(context.cards.single, <String>['pkg.new', 'pkg.low']);
      final (String, Map<String, Object?>, bool) install = context.calls
          .singleWhere(
            ((String, Map<String, Object?>, bool) c) =>
                c.$1 == 'online.extension.install',
          );
      expect(install.$2, <String, Object?>{'kind': 'manga', 'id': 'pkg.new'});
      expect(install.$3, isFalse, reason: 'D9：装扩展必须再出确认卡片');
      expect(summary['installed'], 'pkg.new');
      expect(summary['verified'], isTrue);
    });

    test('技能本身声明 confirm（装扩展类）', () {
      expect(ExtensionFindSkill().spec.confirm, isTrue);
    });
  });

  group('skill.srs.conflicts.resolve', () {
    test('同值不同时刻按规则取当前；其余出卡片；保留删除按用户已选；重复组合并', () async {
      final _Context context = _Context(
        (String id, Map<String, Object?> args) => switch (id) {
          'srs.conflicts.list' => _ok(<String, Object?>{
            'fields': <Object?>[
              <String, Object?>{
                'kind': 'note',
                'entity': 'n1',
                'key': 'front',
                'current': <String, Object?>{'value': 'a'},
                'replaced': <String, Object?>{'value': 'a'},
              },
              <String, Object?>{
                'kind': 'note',
                'entity': 'n2',
                'key': 'back',
                'current': <String, Object?>{'value': 'x'},
                'replaced': <String, Object?>{'value': 'y'},
              },
            ],
            'held': <Object?>[
              <String, Object?>{'id': 'h1', 'label': 'card'},
            ],
            'duplicates': <Object?>[
              <String, Object?>{
                'notes': <Object?>[
                  <String, Object?>{'id': 'd1', 'label': 'A'},
                  <String, Object?>{'id': 'd2', 'label': 'A'},
                ],
              },
            ],
            'pendingNotes': <Object?>[
              <String, Object?>{'id': 'p1'},
            ],
          }),
          _ => _ok(const <String, Object?>{'ok': true}),
        },
        pick: (String prompt, List<AgentChoiceOption> options) {
          if (prompt.startsWith('Deleted')) return 'keep';
          if (prompt.startsWith('These notes')) return 'd2';
          return 'replaced';
        },
      );
      final Object? summary = await SrsConflictsResolveSkill().run(
        context,
        const <String, Object?>{},
      );
      expect(summary, <String, Object?>{
        'resolvedByRule': 1,
        'resolvedByUser': 3,
        'skipped': 0,
        'failed': 0,
        'pendingNotesLeftForConflictCenter': 1,
      });
      final List<(String, Map<String, Object?>, bool)> calls = context.calls
          .where(
            ((String, Map<String, Object?>, bool) c) =>
                c.$1 != 'srs.conflicts.list',
          )
          .toList();
      expect(calls[0].$2, <String, Object?>{
        'kind': 'note',
        'entity': 'n1',
        'key': 'front',
        'keep': 'current',
      });
      expect(calls[1].$2['keep'], 'replaced');
      expect((calls[2].$1, calls[2].$3), ('srs.conflict.held.keep', true));
      expect(calls[3].$2, <String, Object?>{
        'keep': 'd2',
        'absorb': <String>['d1'],
      });
      expect(context.cards, hasLength(3), reason: '同值那条不出卡片');
    });
  });
}
