import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli video` 组里的「生成日语字幕」命令（app 侧路由见
/// `fushi/lib/src/ops/ctl_video_subtitle_routes.dart`）：与视频页
/// 面板、合集页「整季生成日语字幕」同一个 app 服务。提交后返回任务号（`vj<N>`），
/// `video job <id> --wait` 等结束、`video job-cancel <id>` 取消；AI 请求失败 /
/// 专名表校验没过时任务停下，处理后同一命令再跑一次即从缓存续。
const List<CtlCommandSpec> videoSubtitleCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'subtitle-gen',
    summary: '给一个视频条目或整个合集生成日语字幕（<视频名>.ja.srt；缺省 AI 校对，--no-ai 只识别）',
    usage: '<bookUid> | --collection <id>',
    configure: _configureGen,
    build: _buildGen,
    render: _renderGen,
  ),
  CtlCommandSpec(
    name: 'subtitle-glossary',
    summary: '查看作品专名表；--set <json 文件> 整表替换（改过的条目重新生成时保留）',
    usage: '<bookUid> | --collection <id>',
    configure: _configureGlossary,
    build: _buildGlossary,
    render: _renderGlossary,
  ),
];

const String _genPath = '/api/admin/video/subtitle-gen';
const String _glossaryPath = '/api/admin/video/subtitle-glossary';

const List<String> _segmenters = <String>['auto', 'moss', 'window'];
const List<String> _mossBackends = <String>['auto', 'cuda', 'vulkan', 'cpu'];

void _addTargetOption(ArgParser parser) {
  parser.addOption(
    'collection',
    valueHelp: 'id',
    help: '整季：合集 id（collection ls 查）',
  );
}

/// `<bookUid>` 与 `--collection` 恰好给一个。
Map<String, Object?> _target(CtlCommandContext context) {
  final String? book = context.optionalPositional(0)?.trim();
  final String? collection = context.option('collection');
  if ((book == null) == (collection == null)) {
    throw const CtlUsageError('给一个 <bookUid>，或用 --collection <id> 指定整季');
  }
  if (collection != null) {
    final int? id = int.tryParse(collection);
    if (id == null || id <= 0) {
      throw CtlUsageError('--collection 必须是正整数：$collection');
    }
    return <String, Object?>{'collectionId': id};
  }
  return <String, Object?>{'bookUid': book};
}

// ── subtitle-gen ─────────────────────────────────────────────────────────

void _configureGen(ArgParser parser) {
  _addTargetOption(parser);
  parser
    ..addFlag(
      'ai',
      defaultsTo: true,
      help: 'AI 校对（--no-ai 只做识别 + 拆分 + 导出，不发任何 AI 请求）',
    )
    ..addOption(
      'segmenter',
      allowed: _segmenters,
      help: '分段方式（缺省取设置里的值）：auto 能用 MOSS 就用 / moss 强制 / window 滑窗',
    )
    ..addOption(
      'moss-backend',
      allowed: _mossBackends,
      help: 'MOSS 后端（缺省取设置里的值）',
    )
    ..addFlag(
      'regen-glossary',
      negatable: false,
      help: '资料没变也重新生成专名表（编辑过的条目保留）',
    )
    ..addFlag(
      'consent-ai',
      negatable: false,
      help: '同意把 ASR 文本与专名表发给所选 AI 提供商（首次使用 AI 校对时需要一次）',
    )
    ..addFlag('wait', negatable: false, help: '等任务结束再返回（缺省提交即返回任务号）');
}

CtlRequestSpec _buildGen(CtlCommandContext context) {
  final String? segmenter = context.option('segmenter');
  final String? backend = context.option('moss-backend');
  return CtlRequestSpec.post(
    _genPath,
    body: <String, Object?>{
      ..._target(context),
      'proofread': context.flag('ai'),
      if (segmenter != null) 'segmenter': segmenter,
      if (backend != null) 'mossBackend': backend,
      if (context.flag('regen-glossary')) 'regenerateGlossary': true,
      if (context.flag('consent-ai')) 'consentAi': true,
      if (context.flag('wait')) 'wait': true,
    },
  );
}

String _renderGen(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[
    '${data['id']} ${data['status']}  ${data['title'] ?? ''}'
        '（${data['episodes'] ?? '?'} 集）',
  ];
  if (data['scrapeHint'] == true) {
    lines.add('提示：这部作品还没刮削，专名表只能凭标题推断，建议先 video scrape');
  }
  final Object? result = data['result'];
  if (result is Map) {
    final Object? episodes = result['episodes'];
    if (episodes is List) {
      for (final Object? e in episodes) {
        if (e is! Map) continue;
        lines.add(
          '  ${e['status']}  ${e['output'] ?? e['videoPath']}'
          '${e['reason'] == null ? '' : '（${e['reason']}）'}',
        );
      }
    }
    final Object? usage = result['usage'];
    if (usage is Map) {
      lines.add(
        'AI 用量：${usage['calls']} 次请求，输入 ${usage['input']} + 缓存读 '
        '${usage['cacheRead']} + 缓存写 ${usage['cacheWrite']}，输出 ${usage['output']} token'
        '${(usage['callsWithoutUsage'] as num? ?? 0) > 0 ? '；${usage['callsWithoutUsage']} 次未报用量' : ''}',
      );
    }
  } else if (data['status'] == 'running') {
    lines.add(
      '（fushi_cli video job ${data['id']} --wait 等结束，video job-cancel ${data['id']} 取消）',
    );
  }
  return lines.join('\n');
}

// ── subtitle-glossary ────────────────────────────────────────────────────

void _configureGlossary(ArgParser parser) {
  _addTargetOption(parser);
  parser.addOption(
    'set',
    valueHelp: 'json 文件',
    help:
        '用文件整表替换：条目数组 [{ja, reading, kind, misrecognitions, note}]，'
        '或 subtitle-glossary --json 的输出（取其 entries）',
  );
}

/// 读 `--set` 的文件：条目数组，或带 `entries` 的对象。
List<Object?> _readEntries(String path) {
  final File file = File(ctlAbsolutePath(path));
  if (!file.existsSync()) throw CtlUsageError('文件不存在：$path');
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    throw CtlUsageError('不是合法的 JSON：$path（${e.message}）');
  }
  final Object? entries = decoded is Map ? decoded['entries'] : decoded;
  if (entries is! List) {
    throw CtlUsageError('JSON 必须是条目数组，或带 entries 数组的对象：$path');
  }
  for (final Object? e in entries) {
    if (e is! Map || e['ja'] is! String || (e['ja'] as String).trim().isEmpty) {
      throw CtlUsageError('每个条目都必须是带非空 ja 的对象：$path');
    }
  }
  return entries;
}

CtlRequestSpec _buildGlossary(CtlCommandContext context) {
  final Map<String, Object?> target = _target(context);
  final String? set = context.option('set');
  if (set == null) {
    return CtlRequestSpec.get(
      _glossaryPath,
      query: <String, String>{
        for (final MapEntry<String, Object?> e in target.entries)
          e.key: '${e.value}',
      },
    );
  }
  return CtlRequestSpec.put(
    _glossaryPath,
    body: <String, Object?>{...target, 'entries': _readEntries(set)},
  );
}

String _renderGlossary(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String header =
      '${data['japaneseTitle'] ?? data['title']}  ${data['workKey']}'
      '${data['hasScrapedData'] == true ? '' : '（未刮削）'}';
  final Object? entries = data['entries'];
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    if (entries is List)
      for (final Object? e in entries)
        if (e is Map)
          <String, Object?>{
            'ja': e['ja'],
            'reading': e['reading'],
            'kind': e['kind'],
            'misrecognitions': e['misrecognitions'],
            'note': e['note'],
            'edited': e['userEdited'] == true ? '✓' : '',
          },
  ];
  return '$header\n${renderCtlTable(rows, const <(String, String)>[('正式写法', 'ja'), ('读音', 'reading'), ('类别', 'kind'), ('误写', 'misrecognitions'), ('说明', 'note'), ('已编辑', 'edited')], empty: '（专名表为空：第一次 AI 校对时生成，或用 --set 手填）')}';
}
