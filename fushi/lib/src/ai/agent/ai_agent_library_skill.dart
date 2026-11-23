import 'package:fushi_engine/ai/agent/agent_tool.dart';

import 'package:fushi/src/ai/agent/ai_agent_skills.dart';

/// 「重新整理整个库」（spec `docs/specs/2026-11-22-ai-library-agent-design.md` §2 /
/// §3.5）：把本场对话切进长程模式——装上整库地图、批量变更集与相关的已有操作，
/// 本轮工具调用上限提到长程额度，再把整库概况与工作方法交给模型。之后由模型自己
/// 读库、列计划、成批提交、自查、汇报；每份变更集都是一条可撤销的操作记录。
///
/// 与 [CurateLibrarySkill]（库管家流水线：增量、便宜、步骤写死）的分工：用户要
/// 「重新整理 / 纠正分错的合集 / 重写关系网」这种需要全局判断的，走这里。
class ReorganizeLibrarySkill extends AiAgentAppSkill {
  /// 长程模式装进本场的工具：前两条必需，其余可用就装（模块关 / 平台不支持的
  /// 工具箱描述不出来，`beginLongTask` 自动略过）。
  static const List<String> longTaskTools = <String>[
    'library.map',
    'library.changes.apply',
    'library.collection.get',
    'library.item.get',
    'links.candidates',
    'links.list',
    'library.curate.links.infer',
    'library.curate.links.music',
    'library.curate.pending',
    'library.organize.history',
    'video.library.audit',
    'video.library.files',
    'video.work.get',
    'video.work.candidates',
    'video.work.identify',
    'video.work.regroup',
    'video.episode.pin',
  ];

  @override
  List<String> get requiredOps => const <String>[
    'library.map',
    'library.changes.apply',
  ];

  @override
  AgentToolSpec get spec => const AgentToolSpec(
    name: 'skill.library.reorganize',
    description:
        'Start a thorough, whole-library reorganization the way a careful '
        'librarian would: read the entire library, fix items sorted into the '
        'wrong collection (split / merge / move / take out / rename '
        'collections, including the user\'s own), and rewrite and complete '
        'the relation graph between works (same work, adaptation, sequel, '
        'side story, theme songs, soundtracks). Use when the user asks to '
        'reorganize, clean up, re-sort or fix their library or its relations. '
        'Loads the library tools and raises the tool-call budget for this '
        'turn; returns an overview and the working method.',
    parameters: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'focus': <String, Object?>{
          'type': 'string',
          'description':
              'Optional scope in the user\'s words (e.g. "only manga", '
              '"relations only").',
        },
      },
    },
    risk: AgentToolRisk.read,
  );

  @override
  Future<Object?> run(
    AgentSkillContext context,
    Map<String, Object?> args,
  ) async {
    context.beginLongTask(tools: longTaskTools);
    final AgentToolResult overview = await context.call(
      'library.map',
      const <String, Object?>{'view': 'summary'},
    );
    if (overview.isError) {
      throw AgentSkillFailure(overview.errorCode!, overview.errorMessage);
    }
    final Object? focus = args['focus'];
    return <String, Object?>{
      'overview': overview.data,
      if (focus is String && focus.trim().isNotEmpty) 'focus': focus.trim(),
      'method': _kMethod,
    };
  }
}

const List<String> _kMethod = <String>[
  'Keep a checklist with plan__update (one step per library page plus one for '
      'relations) and update it as you go.',
  'Read before you write: page through library.map for each library page '
      '(view=books / manga / video / games, follow nextOffset until null) and '
      'view=links. Use q to zoom into one series.',
  'Look for: volumes of one work spread over several collections or left '
      'loose; collections mixing different works; duplicate collections for '
      'the same work under different names or languages; collections whose '
      'name does not fit their members; works with obvious missing or wrong '
      'relations (novel <-> manga <-> anime <-> game, sequels, side stories, '
      'OP / ED singles and soundtracks).',
  'Submit fixes in batches with library.changes.apply (dozens of changes per '
      'call, one library page or one franchise at a time), each with a short '
      'why. Never use library.collection.add / remove for this: those record '
      'the change as the user\'s own decision.',
  'Respect the user: pinned members, folder collections and user-confirmed '
      'links are reported as skipped; do not retry them. Only act when you are '
      'confident; list doubtful cases for the user instead of guessing.',
  'Video placement problems (movies filed as season 0, wrong season / '
      'episode) go through video.library.audit and video.work.* tools.',
  'After each batch, re-read the affected part of library.map to verify. '
      'Finish with a short report: what changed per library page, relations '
      'added / fixed / removed, and what you left for the user. Every batch '
      'can be undone from the conversation.',
];
