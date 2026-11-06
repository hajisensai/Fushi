import 'package:fushi_engine/ai/agent/agent_tool.dart';

/// AI 助手的组合技能（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.3）：确定性的多步配方。模型只负责选技能、填参数；每一步都调操作目录里的
/// 现有操作（与按钮同一个 handler），照常走确认 / 记账 / 撤销。
///
/// 技能只依赖操作 id 与它们的结果形状，不碰业务对象。
List<AiAgentAppSkill> buildAiAgentSkills() => <AiAgentAppSkill>[
  SubtitleFillSkill(),
  ScrapeResolveSkill(),
  ExtensionFindSkill(),
  SrsConflictsResolveSkill(),
];

/// app 侧技能：声明它要用的操作；任一当前不可用（模块关、平台 / 合规不支持）时
/// 技能不出现在工具表里。
abstract class AiAgentAppSkill implements AgentSkill {
  List<String> get requiredOps;
}

Map<String, Object?> _map(Object? data) =>
    data is Map ? Map<String, Object?>.from(data) : const <String, Object?>{};

List<Map<String, Object?>> _list(Object? data, String key) =>
    <Map<String, Object?>>[
      for (final Object? row
          in (_map(data)[key] as List<Object?>? ?? const <Object?>[]))
        if (row is Map) Map<String, Object?>.from(row),
    ];

/// 「补字幕」：对一组视频逐集补在线字幕。
///
/// - 每集先走与刮削后自动补同一条路（`video.subtitle.fetch`：搜 → 校验 → 落盘，
///   命中可靠的直接装；撤销 = 删掉这份字幕）。
/// - 自动没装上但有候选的，汇总成一张选择卡让用户点（`video.subtitle.search` →
///   `video.subtitle.download`）；用户点「都不是」就跳过。搜索结果里标了
///   `mismatch`（不是这部作品）的候选不进卡片——全是这种就按「没有候选」处理。
/// - 一个候选都没有的，按 [asrFallback] 用设备端 ASR 生成（`video.subtitle.generate`，
///   要走 LLM 校对时会出确认卡片——那会把 ASR 文本发给提供商、按量计费）。
class SubtitleFillSkill extends AiAgentAppSkill {
  @override
  List<String> get requiredOps => const <String>[
    'video.subtitle.fetch',
    'video.subtitle.search',
    'video.subtitle.download',
  ];

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.subtitles.fill',
    description:
        'Fill missing subtitles for one or more videos (e.g. every episode of a '
        'series): auto-installs reliable matches, shows the user a choice card '
        'when several candidates fit, and optionally generates subtitles with '
        'on-device ASR when none exist. Video bookUids come from the library ops '
        'or the UI context.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'bookUids': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
          'description': 'Video bookUids (episodes) to fill.',
        },
        'language': <String, Object?>{
          'type': 'string',
          'description': 'Subtitle language code (default: setting).',
        },
        'asrFallback': <String, Object?>{
          'type': 'boolean',
          'description':
              'Generate with on-device ASR when no online subtitle exists '
              '(default true).',
        },
        'preferFormat': <String, Object?>{
          'type': 'string',
          'description':
              'Preferred subtitle file format when the user names one, e.g. '
              '"ass" or "srt": such candidates are listed first.',
        },
      },
      'required': <String>['bookUids'],
    },
    risk: AgentToolRisk.write,
  );

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    final List<String> bookUids = <String>[
      for (final Object? id
          in (args['bookUids'] as List<Object?>? ?? const <Object?>[]))
        if ('$id'.trim().isNotEmpty) '$id'.trim(),
    ];
    if (bookUids.isEmpty) {
      throw const AgentSkillFailure('bad_request', 'bookUids is empty');
    }
    final String? language = args['language'] as String?;
    final bool asrFallback = args['asrFallback'] != false;
    final List<String> installed = <String>[];
    final List<String> skipped = <String>[];
    final List<String> picked = <String>[];
    final List<String> generated = <String>[];
    final List<String> failed = <String>[];
    final List<String> missing = <String>[];
    // 没有可挑候选的集为什么没有（给模型向用户如实解释）。
    final Map<String, String> reasons = <String, String>{};
    final String? preferFormat = switch ('${args['preferFormat'] ?? ''}'
        .trim()
        .toLowerCase()
        .replaceFirst('.', '')) {
      '' => null,
      final String f => f,
    };
    for (final String bookUid in bookUids) {
      if (context.cancelled) break;
      final AgentToolResult fetched = await context.call(
        'video.subtitle.fetch',
        <String, Object?>{'bookUid': bookUid, 'language': ?language},
      );
      if (fetched.isError) {
        failed.add(bookUid);
        continue;
      }
      switch (_map(fetched.data)['outcome']) {
        case 'installed':
          installed.add(bookUid);
          continue;
        case 'alreadyHasSubtitle':
          skipped.add(bookUid);
          continue;
      }
      // 自动没装上：看还有没有候选让用户挑。
      final AgentToolResult searched = await context.call(
        'video.subtitle.search',
        <String, Object?>{'bookUid': bookUid, 'language': ?language},
      );
      // 只给用户挑**可能是这部作品**的：搜索路由用与自动补同一道作品核对标出
      // `mismatch`（如剧场版搜回 TV 版分集），那些自动补已经判过错，再拿出来让
      // 用户逐条辨认毫无意义。
      final List<Map<String, Object?>> found = searched.isError
          ? const <Map<String, Object?>>[]
          : _list(searched.data, 'candidates');
      final List<Map<String, Object?>> candidates = <Map<String, Object?>>[
        for (final Map<String, Object?> c in found)
          if (c['mismatch'] == null) c,
      ];
      if (preferFormat != null) {
        // 稳定排序：偏好格式的排前，其余保持来源顺序。
        final List<Map<String, Object?>> preferred = <Map<String, Object?>>[
          for (final Map<String, Object?> c in candidates)
            if (_hasFormat(c, preferFormat)) c,
        ];
        candidates
          ..removeWhere(preferred.contains)
          ..insertAll(0, preferred);
      }
      if (candidates.isEmpty) {
        final Map<String, Object?> fetchData = _map(fetched.data);
        reasons[bookUid] = found.isNotEmpty
            ? '${found.length} online candidates are for a different work '
                  '(${found.first['mismatch']})'
            : '${fetchData['detail'] ?? fetchData['outcome']}';
      }
      if (candidates.isNotEmpty) {
        final String title = '${_map(searched.data)['title'] ?? bookUid}';
        final String? choice = await context.askChoice(
          'Subtitles for $title',
          <AgentChoiceOption>[
            for (final Map<String, Object?> c in candidates.take(8))
              AgentChoiceOption(
                id: '${c['id']}',
                label: '${c['fileName'] ?? c['release'] ?? c['id']}',
                detail: <String>[
                  '${c['provider'] ?? ''}',
                  '${c['language'] ?? ''}',
                  if (c['episode'] != null) 'ep ${c['episode']}',
                ].where((String s) => s.isNotEmpty).join(' · '),
              ),
          ],
        );
        if (choice == null) {
          skipped.add(bookUid);
          continue;
        }
        final AgentToolResult downloaded = await context.call(
          'video.subtitle.download',
          <String, Object?>{'id': choice},
        );
        (downloaded.isError ? failed : picked).add(bookUid);
        continue;
      }
      if (!asrFallback) {
        missing.add(bookUid);
        continue;
      }
      final AgentToolResult generatedResult = await context.call(
        'video.subtitle.generate',
        <String, Object?>{'bookUid': bookUid, 'wait': false},
      );
      (generatedResult.isError ? missing : generated).add(bookUid);
    }
    return <String, Object?>{
      'installed': installed,
      'pickedByUser': picked,
      'generatingWithAsr': generated,
      'alreadyHadOrSkipped': skipped,
      'noSubtitle': missing,
      'failed': failed,
      'reasons': reasons,
    };
  }

  /// 候选文件名（或发布名）是不是 [format] 格式（`ass` / `srt` …）。
  static bool _hasFormat(Map<String, Object?> candidate, String format) {
    final String name = '${candidate['fileName'] ?? candidate['release'] ?? ''}'
        .toLowerCase();
    return name.endsWith('.$format');
  }
}

/// 「处理刮削」：把待确认的视频作品逐个过一遍。
///
/// 每部作品搜候选（`video.work.candidates`），出一张候选卡让用户点；点中的那一项
/// 就是确认，直接认领（`video.work.identify`）。用户点「都不是」就留在待确认队列。
///
/// 与设计稿的差异：设计稿要「高置信的直接认领（撤销 = 退回待确认）」，但目前没有
/// 「清除作品身份、退回待确认」的路由，认领撤销不了；所以每一部都让用户在卡片上
/// 点，不自动认领。
class ScrapeResolveSkill extends AiAgentAppSkill {
  @override
  List<String> get requiredOps => const <String>[
    'video.work.list',
    'video.work.candidates',
    'video.work.identify',
  ];

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.scrape.resolve',
    description:
        'Go through video works waiting for scrape confirmation: search '
        'candidates for each and let the user tap the right one (or skip). '
        'Use when the user asks to deal with the scrape queue.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'limit': <String, Object?>{
          'type': 'integer',
          'description': 'At most this many works this time (default 10).',
        },
      },
    },
    risk: AgentToolRisk.irreversible,
  );

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    final int limit = switch (args['limit']) {
      final int n when n > 0 => n,
      _ => 10,
    };
    final AgentToolResult listed = await context.call(
      'video.work.list',
      const <String, Object?>{'pending': true},
    );
    if (listed.isError) {
      throw AgentSkillFailure(listed.errorCode!, listed.errorMessage);
    }
    final List<Map<String, Object?>> works = _list(listed.data, 'works');
    final List<String> identified = <String>[];
    final List<String> skipped = <String>[];
    final List<String> noCandidates = <String>[];
    final List<String> failed = <String>[];
    for (final Map<String, Object?> work in works.take(limit)) {
      if (context.cancelled) break;
      final String id = '${work['id']}';
      final String title = '${work['title'] ?? id}';
      final AgentToolResult found = await context.call(
        'video.work.candidates',
        <String, Object?>{'id': id},
      );
      final List<Map<String, Object?>> candidates = found.isError
          ? const <Map<String, Object?>>[]
          : _list(found.data, 'candidates');
      if (candidates.isEmpty) {
        noCandidates.add(title);
        continue;
      }
      final String? choice = await context.askChoice(
        'Which is "$title"?',
        <AgentChoiceOption>[
          for (final Map<String, Object?> c in candidates.take(8))
            AgentChoiceOption(
              id: '${c['identity']}',
              label: '${c['title'] ?? c['identity']}',
              detail: <String>[
                if (c['year'] != null) '${c['year']}',
                '${c['kind'] ?? ''}',
                if (c['episodes'] != null) '${c['episodes']} ep',
                '${c['identity']}',
              ].where((String s) => s.isNotEmpty).join(' · '),
            ),
        ],
      );
      if (choice == null) {
        skipped.add(title);
        continue;
      }
      final Map<String, Object?> candidate = candidates.firstWhere(
        (Map<String, Object?> c) => '${c['identity']}' == choice,
      );
      final AgentToolResult result = await context
          .call('video.work.identify', <String, Object?>{
            'id': id,
            'provider': candidate['provider'],
            'externalId': '${candidate['externalId']}',
            if (candidate['mediaKind'] == 'movie' ||
                candidate['mediaKind'] == 'tv')
              'type': candidate['mediaKind'],
            'wait': false,
          }, userChoseThisStep: true);
      (result.isError ? failed : identified).add(title);
    }
    return <String, Object?>{
      'pendingTotal': works.length,
      'identified': identified,
      'leftPending': skipped,
      'noCandidates': noCandidates,
      'failed': failed,
    };
  }
}

/// 「装一个能看 X 的源」：先在已装、已启用的源里搜 X；都搜不到再从仓库目录里挑
/// 候选扩展（按下载量，去掉成人内容与已装的）出选择卡；用户选中后安装——**装扩展
/// 一律再出确认卡片**（spec D9，所有者「装扩展的时候也要确认一下」：选择卡只是选
/// 哪一个，确认卡写明来源与签名，两步都要用户点）；装好后在它提供的源里试搜 X
/// 验证可用。撤销 = 卸载（安装操作自己的撤销）。
class ExtensionFindSkill extends AiAgentAppSkill {
  @override
  List<String> get requiredOps => const <String>[
    'online.extension.list',
    'online.extension.install',
    'online.source.list',
    'online.source.search',
  ];

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.extension.find',
    description:
        'Find a way to read / watch a title online: search it in the installed '
        'sources first; if none has it, let the user pick an extension from the '
        'repositories, install it (the user confirms) and test-search the title.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'kind': <String, Object?>{
          'type': 'string',
          'enum': <String>['manga', 'anime', 'novel'],
          'description':
              'manga (Mihon), anime (Aniyomi video), novel (LNReader).',
        },
        'title': <String, Object?>{
          'type': 'string',
          'description': 'The work to find, in its original language if known.',
        },
        'lang': <String, Object?>{
          'type': 'string',
          'description': 'Preferred source language code, e.g. "ja".',
        },
      },
      'required': <String>['kind', 'title'],
    },
    risk: AgentToolRisk.write,
    confirm: true,
  );

  /// 最多试搜几个源（已装的源可能很多）。
  static const int _maxSourcesToTry = 6;

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    final String kind = '${args['kind'] ?? ''}';
    final String title = '${args['title'] ?? ''}'.trim();
    final String? lang = (args['lang'] as String?)?.trim();
    if (!const <String>['manga', 'anime', 'novel'].contains(kind) ||
        title.isEmpty) {
      throw const AgentSkillFailure(
        'bad_request',
        'kind and title are required',
      );
    }
    // ① 已装的源里有没有。
    final Map<String, Object?> already = await _searchSources(
      context,
      kind: kind,
      title: title,
      lang: lang,
    );
    if (already.isNotEmpty) {
      return <String, Object?>{'alreadyAvailable': already, 'installed': null};
    }
    // ② 仓库目录里挑候选扩展。
    final AgentToolResult listed = await context
        .call('online.extension.list', <String, Object?>{
          'kind': kind,
          'available': true,
          if (lang != null && lang.isNotEmpty) 'lang': lang,
        });
    if (listed.isError) {
      throw AgentSkillFailure(listed.errorCode!, listed.errorMessage);
    }
    final List<Map<String, Object?>> candidates =
        _list(listed.data, 'available')
            .where(
              (Map<String, Object?> e) =>
                  e['installed'] != true && e['nsfw'] != true,
            )
            .toList()
          ..sort(
            (Map<String, Object?> a, Map<String, Object?> b) =>
                ((b['downloads'] as num?) ?? 0).compareTo(
                  (a['downloads'] as num?) ?? 0,
                ),
          );
    if (candidates.isEmpty) {
      return <String, Object?>{
        'installed': null,
        'note': 'no installable extension in the configured repositories',
      };
    }
    final String? picked = await context.askChoice(
      'No installed source has "$title". Install which extension?',
      <AgentChoiceOption>[
        for (final Map<String, Object?> e in candidates.take(8))
          AgentChoiceOption(
            id: '${e['id']}',
            label: '${e['name'] ?? e['id']}',
            detail: <String>[
              '${e['lang'] ?? ''}',
              if (e['version'] != null) 'v${e['version']}',
              '${e['repo'] ?? ''}',
            ].where((String s) => s.isNotEmpty).join(' · '),
          ),
      ],
    );
    if (picked == null) {
      return <String, Object?>{'installed': null, 'cancelled': true};
    }
    // ③ 安装：照常出确认卡片（D9），选择卡不算确认。
    final AgentToolResult installed = await context.call(
      'online.extension.install',
      <String, Object?>{'kind': kind, 'id': picked},
    );
    if (installed.isError) {
      return <String, Object?>{
        'installed': null,
        'installError': installed.errorCode,
      };
    }
    // ④ 在新扩展提供的源里试搜。
    final Map<String, Object?> found = await _searchSources(
      context,
      kind: kind,
      title: title,
      lang: lang,
      onlyExtension: picked,
    );
    return <String, Object?>{
      'installed': picked,
      'verified': found.isNotEmpty,
      'found': found,
    };
  }

  /// 在（某个扩展提供的 / 全部已启用的）源里搜 [title]，返回 {源名: 前几条标题}。
  Future<Map<String, Object?>> _searchSources(
    AgentSkillContext context, {
    required String kind,
    required String title,
    String? lang,
    String? onlyExtension,
  }) async {
    final AgentToolResult listed = await context.call(
      'online.source.list',
      <String, Object?>{'kind': kind},
    );
    if (listed.isError) return const <String, Object?>{};
    final String wantLang = (lang ?? '').toLowerCase();
    final List<Map<String, Object?>> sources = _list(listed.data, 'sources')
        .where(
          (Map<String, Object?> s) =>
              s['enabled'] == true &&
              (onlyExtension == null ||
                  s['extension'] == onlyExtension ||
                  s['id'] == onlyExtension) &&
              (wantLang.isEmpty ||
                  s['lang'] == 'all' ||
                  '${s['lang'] ?? ''}'.toLowerCase().contains(wantLang)),
        )
        .take(_maxSourcesToTry)
        .toList();
    final Map<String, Object?> hits = <String, Object?>{};
    for (final Map<String, Object?> source in sources) {
      if (context.cancelled) break;
      final String sourceId = source['extension'] == null
          ? '${source['id']}'
          : '${source['extension']}:${source['id']}';
      final AgentToolResult searched = await context.call(
        'online.source.search',
        <String, Object?>{'sourceId': sourceId, 'kind': kind, 'q': title},
      );
      if (searched.isError) continue;
      final List<Map<String, Object?>> items = _list(searched.data, 'items');
      if (items.isEmpty) continue;
      hits['${source['name'] ?? sourceId}'] = <String>[
        for (final Map<String, Object?> item in items.take(3))
          '${item['title'] ?? item['url']}',
      ];
    }
    return hits;
  }
}

/// 「处理冲突」：复习（SRS）的同步冲突与重复笔记。
///
/// - 字段冲突：两侧值相同、只是写入时刻不同 → 按规则直接取当前生效的那一侧
///   （`srs.conflict.field.resolve keep=current`，可撤销）；值不同的出候选卡让用户选。
/// - 被扣住的删除：出候选卡——「删除」可撤销（墓碑带快照）；「保留」撤销不了，
///   用户在卡片上点了「保留」即确认这一步。
/// - 重复笔记组：出候选卡——保留哪一条（其余合并进来，可撤销）/「不是重复」/ 跳过。
/// - 待决的笔记（`pendingNotes`）只报告数量，交给冲突中心页。
///
/// 云同步（书 / 播放位置）中途的冲突走 `sync.run` 的冲突策略参数，不在这里。
class SrsConflictsResolveSkill extends AiAgentAppSkill {
  @override
  List<String> get requiredOps => const <String>[
    'srs.conflicts.list',
    'srs.conflict.field.resolve',
    'srs.conflict.held.delete',
    'srs.conflict.held.keep',
    'srs.duplicates.merge',
    'srs.duplicates.dismiss',
  ];

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.srs.conflicts.resolve',
    description:
        'Resolve spaced-repetition sync conflicts and duplicate notes: settles '
        'the trivial ones by rule (same value, different time) and shows the '
        'user choice cards for the rest.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{},
    },
    risk: AgentToolRisk.write,
  );

  static const String _keep = 'keep';
  static const String _delete = 'delete';
  static const String _current = 'current';
  static const String _replaced = 'replaced';
  static const String _notDuplicate = '__not_duplicate__';

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    final AgentToolResult listed = await context.call(
      'srs.conflicts.list',
      const <String, Object?>{},
    );
    if (listed.isError) {
      throw AgentSkillFailure(listed.errorCode!, listed.errorMessage);
    }
    int byRule = 0;
    int byUser = 0;
    int skipped = 0;
    int failed = 0;
    void count(AgentToolResult r, {required bool rule}) {
      if (r.isError) {
        failed++;
      } else if (rule) {
        byRule++;
      } else {
        byUser++;
      }
    }

    for (final Map<String, Object?> field in _list(listed.data, 'fields')) {
      if (context.cancelled) break;
      final Map<String, Object?> current = _map(field['current']);
      final Map<String, Object?> replaced = _map(field['replaced']);
      final Map<String, Object?> target = <String, Object?>{
        'kind': field['kind'],
        'entity': field['entity'],
        'key': field['key'],
      };
      if ('${current['value']}' == '${replaced['value']}') {
        count(
          await context.call('srs.conflict.field.resolve', <String, Object?>{
            ...target,
            'keep': _current,
          }),
          rule: true,
        );
        continue;
      }
      final String? choice = await context.askChoice(
        '${field['label'] ?? field['entity']} · ${field['key']}',
        <AgentChoiceOption>[
          AgentChoiceOption(
            id: _current,
            label: '${current['value']}',
            detail: 'device ${current['device'] ?? '?'}',
          ),
          AgentChoiceOption(
            id: _replaced,
            label: '${replaced['value']}',
            detail: 'device ${replaced['device'] ?? '?'}',
          ),
        ],
      );
      if (choice == null) {
        skipped++;
        continue;
      }
      count(
        await context.call('srs.conflict.field.resolve', <String, Object?>{
          ...target,
          'keep': choice,
        }),
        rule: false,
      );
    }

    for (final Map<String, Object?> held in _list(listed.data, 'held')) {
      if (context.cancelled) break;
      final String id = '${held['id']}';
      final String? choice = await context.askChoice(
        'Deleted on another device: ${held['label'] ?? held['entity']}',
        const <AgentChoiceOption>[
          AgentChoiceOption(id: _delete, label: 'Delete', detail: 'undoable'),
          AgentChoiceOption(
            id: _keep,
            label: 'Keep',
            detail: 'cannot be undone',
          ),
        ],
      );
      if (choice == null) {
        skipped++;
        continue;
      }
      count(
        choice == _delete
            ? await context.call('srs.conflict.held.delete', <String, Object?>{
                'id': id,
              })
            : await context.call('srs.conflict.held.keep', <String, Object?>{
                'id': id,
              }, userChoseThisStep: true),
        rule: false,
      );
    }

    for (final Map<String, Object?> group in _list(listed.data, 'duplicates')) {
      if (context.cancelled) break;
      final List<Map<String, Object?>> notes = _list(group, 'notes');
      if (notes.length < 2) continue;
      final String? choice = await context.askChoice(
        'These notes look like duplicates. Keep which one?',
        <AgentChoiceOption>[
          for (final Map<String, Object?> n in notes)
            AgentChoiceOption(
              id: '${n['id']}',
              label: '${n['label'] ?? n['id']}',
              detail: '${n['reviews'] ?? 0} reviews',
            ),
          const AgentChoiceOption(id: _notDuplicate, label: 'Not duplicates'),
        ],
      );
      if (choice == null) {
        skipped++;
        continue;
      }
      count(
        choice == _notDuplicate
            ? await context.call('srs.duplicates.dismiss', <String, Object?>{
                'notes': <String>[
                  for (final Map<String, Object?> n in notes) '${n['id']}',
                ],
              })
            : await context.call('srs.duplicates.merge', <String, Object?>{
                'keep': choice,
                'absorb': <String>[
                  for (final Map<String, Object?> n in notes)
                    if ('${n['id']}' != choice) '${n['id']}',
                ],
              }),
        rule: false,
      );
    }

    return <String, Object?>{
      'resolvedByRule': byRule,
      'resolvedByUser': byUser,
      'skipped': skipped,
      'failed': failed,
      'pendingNotesLeftForConflictCenter': _list(
        listed.data,
        'pendingNotes',
      ).length,
    };
  }
}
