import 'package:fushi_engine/ai/agent/agent_tool.dart';

/// AI 助手的组合技能（spec `docs/specs/2026-10-26-ai-operations-agent-design.md`
/// §6.3）：确定性的多步配方。模型只负责选技能、填参数；每一步都调操作目录里的
/// 现有操作（与按钮同一个 handler），照常走确认 / 记账 / 撤销。
///
/// 技能只依赖操作 id 与它们的结果形状，不碰业务对象。
List<AiAgentAppSkill> buildAiAgentSkills() => <AiAgentAppSkill>[
  SubtitleFillSkill(),
  ScrapeResolveSkill(),
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
///   `video.subtitle.download`）；用户点「都不是」就跳过。
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
      final List<Map<String, Object?>> candidates = searched.isError
          ? const <Map<String, Object?>>[]
          : _list(searched.data, 'candidates');
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
    };
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
