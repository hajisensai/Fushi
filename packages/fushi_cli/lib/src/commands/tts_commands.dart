import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli tts …`：漫画有声——演出稿、AI 看图标注、整卷生成、导入外部做好的成品（app 侧路由见
/// `fushi/lib/src/ops/ctl_tts_routes.dart`）。条目键用 `book:<bookKey>`（见 library ls），
/// 只认本地漫画卷。
const List<CtlCommandGroup> ttsCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'tts',
    summary:
        '漫画有声：演出稿 / AI 标注 / 改句改角色 / 单句或按角色重生成 / 按句换本地音频 / '
        '整卷生成 / 导入成品',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'voices',
        summary: '可选的声音（声音预设 + 声音包参考音频组）',
        build: _buildVoices,
        render: _renderVoices,
      ),
      CtlCommandSpec(
        name: 'script',
        summary: '演出稿摘要：角色表、行数、未定说话人、要不要重新标注',
        usage: '<key>',
        build: _buildScript,
        render: _renderScript,
      ),
      CtlCommandSpec(
        name: 'page',
        summary: '某页的行（页码 1 起）',
        usage: '<key> <页码>',
        build: _buildPage,
        render: _renderPage,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '标注任务与生成任务的状态',
        usage: '<key>',
        build: _buildStatus,
        render: _renderStatus,
      ),
      CtlCommandSpec(
        name: 'annotate',
        summary: '后台发起 AI 看图标注（页图会发给指派的 AI 服务商）',
        usage: '<key>',
        configure: _configureAnnotate,
        build: _buildAnnotate,
        render: _renderStatusPart,
      ),
      CtlCommandSpec(
        name: 'annotate-cancel',
        summary: '取消正在跑的标注（已标的页保留）',
        usage: '<key>',
        build: _buildAnnotateCancel,
      ),
      CtlCommandSpec(
        name: 'line',
        summary: '改一句：说话人 / 类型 / 一拍 / 语气与强度 / 页内位置 / 手填文字 / 错字修正',
        usage: '<key> <行 id>',
        configure: _configureLine,
        build: _buildLine,
      ),
      CtlCommandSpec(
        name: 'character',
        summary: '改某角色：改名 / 合并（只本卷）、声音指派（本卷或系列）',
        usage: '<key> <角色名|narrator>',
        configure: _configureCharacter,
        build: _buildCharacter,
      ),
      CtlCommandSpec(
        name: 'regenerate',
        summary: '单句换种子重生成并保留（这句要已经生成过）',
        usage: '<key> <行 id>',
        configure: _configureRegenerate,
        build: _buildRegenerate,
      ),
      CtlCommandSpec(
        name: 'regenerate-character',
        summary: '按角色批量重生成：这个角色已生成的合成句各换新种子，排进制作队列（--dry-run 只列句子）',
        usage: '<key> <角色名|narrator|unknown>',
        configure: _configureRegenerateCharacter,
        build: _buildRegenerateCharacter,
        render: _renderRegenerateCharacter,
      ),
      CtlCommandSpec(
        name: 'replace',
        summary: '按句换上本地音频（全有或全无；--dry-run 只预检）：<行 id>=<音频路径> 或 --map 映射 JSON',
        usage: '<key> [<行 id>=<音频路径> ...]',
        configure: _configureReplace,
        build: _buildReplace,
        render: _renderReplace,
      ),
      CtlCommandSpec(
        name: 'render',
        summary: '排整卷生成（进制作队列；生成完会替换这卷原有的音频）',
        usage: '<key>',
        configure: _configureRender,
        build: _buildRender,
        render: _renderStatusPart,
      ),
      CtlCommandSpec(
        name: 'render-cancel',
        summary: '取消这一卷在排队 / 在跑的生成任务',
        usage: '<key>',
        build: _buildRenderCancel,
      ),
      CtlCommandSpec(
        name: 'import',
        summary: '导入做好的成品清单 manifest.json（与漫画卡「导入漫画有声」同一套校验；已有成品要 --yes 才替换）',
        usage: '<key> <manifest.json>',
        configure: _configureImport,
        build: _buildImport,
        render: _renderImport,
      ),
    ],
  ),
];

const String _root = '/api/admin/tts/manga';

String _item(CtlCommandContext c) =>
    '$_root/${Uri.encodeComponent(c.positional(0, 'key').trim())}';

CtlRequestSpec _buildVoices(CtlCommandContext c) =>
    const CtlRequestSpec.get('/api/admin/tts/voices');

CtlRequestSpec _buildScript(CtlCommandContext c) =>
    CtlRequestSpec.get(_item(c));

CtlRequestSpec _buildPage(CtlCommandContext c) {
  final String page = c.positional(1, '页码').trim();
  if (int.tryParse(page) == null) throw CtlUsageError('页码应为整数，收到「$page」');
  return CtlRequestSpec.get('${_item(c)}/pages/${Uri.encodeComponent(page)}');
}

CtlRequestSpec _buildStatus(CtlCommandContext c) =>
    CtlRequestSpec.get('${_item(c)}/status');

void _configureAnnotate(ArgParser parser) => parser
  ..addOption('pages', help: '只标这些页（1 起，逗号分隔）；不给 = 还没标过的页')
  ..addFlag('roster', defaultsTo: null, help: '先跑 / 不跑角色表（不给 = 自动）')
  ..addFlag(
    'consent-upload',
    negatable: false,
    help: '同意把页图发给 AI 服务商（本机第一次标注时需要）',
  );

CtlRequestSpec _buildAnnotate(CtlCommandContext c) {
  final String path = '${_item(c)}/annotate';
  final String? raw = c.option('pages');
  final List<int> pages = <int>[];
  if (raw != null) {
    for (final String part in raw.split(',')) {
      final int? page = int.tryParse(part.trim());
      if (page == null || page < 1) {
        throw CtlUsageError('--pages 应为 1 起的页码，收到「$part」');
      }
      pages.add(page);
    }
  }
  final bool? roster = c.explicitFlag('roster');
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      if (pages.isNotEmpty) 'pages': pages,
      if (roster != null) 'roster': roster,
      if (c.flag('consent-upload')) 'consentUpload': true,
    },
  );
}

CtlRequestSpec _buildAnnotateCancel(CtlCommandContext c) =>
    CtlRequestSpec.post('${_item(c)}/annotate/cancel');

const List<String> _kinds = <String>[
  'narration',
  'monologue',
  'thought',
  'spoken',
  'shout',
  'mutter',
  'skip',
];

/// 语气词表（线上 wire 名，none = 不标）。CLI 不依赖 fushi_engine，所以这里手写；
/// 与引擎 `CastEmotion` 的一致性由 app 侧测试
/// `tts_manga_line_emotion_parity_test.dart` 钉住，操作目录描述也直接引用这份。
const List<String> kTtsMangaLineEmotions = <String>[
  'none',
  'neutral',
  'joy',
  'sadness',
  'anger',
  'surprise',
  'fear',
  'disgust',
  'embarrassment',
  'tenderness',
  'tension',
];

/// `--intensity`：整数，或 none（清掉强度，线上是 -1）。
MapEntry<String, Object?>? _intensityOption(CtlCommandContext c) {
  final String? raw = c.option('intensity');
  if (raw == null) return null;
  if (raw.trim() == 'none')
    return const MapEntry<String, Object?>('intensity', -1);
  return MapEntry<String, Object?>('intensity', _intOption(c, 'intensity'));
}

void _configureLine(ArgParser parser) => parser
  ..addOption('speaker', help: '说话人：角色名 / narrator / unknown')
  ..addFlag('new-character', negatable: false, help: '--speaker 是新角色，加进角色表')
  ..addOption('kind', allowed: _kinds, help: '台词类型')
  ..addOption('beat', help: '句后额外停顿（毫秒，0-10000）')
  ..addOption(
    'emotion',
    allowed: kTtsMangaLineEmotions,
    help: '语气（none = 不标，强度一并清掉）',
  )
  ..addOption('intensity', help: '语气强度 0-100（none = 不标强度）')
  ..addOption('position', help: '移到本页第几句（1 起）')
  ..addOption('say', help: '整句手填要念的文字（空串 = 清掉）')
  ..addMultiOption('fix', help: 'OCR 错字修正：<块下标>=<文字>（文字为空 = 删掉这处修正）');

int? _intOption(CtlCommandContext c, String name) {
  final String? raw = c.option(name);
  if (raw == null) return null;
  final int? value = int.tryParse(raw);
  if (value == null) throw CtlUsageError('--$name 应为整数，收到「$raw」');
  return value;
}

CtlRequestSpec _buildLine(CtlCommandContext c) {
  final String path =
      '${_item(c)}/lines/${Uri.encodeComponent(c.positional(1, '行 id').trim())}';
  final Map<String, String> fixes = <String, String>{};
  for (final String raw in c.multiOption('fix')) {
    final int eq = raw.indexOf('=');
    if (eq <= 0 || int.tryParse(raw.substring(0, eq).trim()) == null) {
      throw CtlUsageError('--fix 应为 <块下标>=<文字>，收到「$raw」');
    }
    fixes[raw.substring(0, eq).trim()] = raw.substring(eq + 1);
  }
  final Object? say = c.args.wasParsed('say') ? c.args['say'] : null;
  final Map<String, Object?> body = <String, Object?>{
    if (c.option('speaker') case final String speaker) 'speaker': speaker,
    if (c.flag('new-character')) 'newCharacter': true,
    if (c.option('kind') case final String kind) 'kind': kind,
    if (_intOption(c, 'beat') case final int beat) 'beat': beat,
    if (c.option('emotion') case final String emotion) 'emotion': emotion,
    if (_intensityOption(c) case final MapEntry<String, Object?> e)
      e.key: e.value,
    if (_intOption(c, 'position') case final int position) 'position': position,
    if (say != null) 'say': '$say',
    if (fixes.isNotEmpty) 'fixes': fixes,
  };
  if (body.isEmpty) {
    throw const CtlUsageError(
      '至少给一个要改的：--speaker / --kind / --beat / --emotion / --intensity / '
      '--position / --say / --fix',
    );
  }
  return CtlRequestSpec.put(path, body: body);
}

void _configureCharacter(ArgParser parser) => parser
  ..addOption('rename', help: '新名字（填已有的名字 = 合并两人），只改本卷')
  ..addOption('voice', help: '声音 id（见 tts voices）')
  ..addFlag('clear-voice', negatable: false, help: '清掉这一级的声音指派')
  ..addOption(
    'kind',
    allowed: _kinds.where((String k) => k != 'skip'),
    help: '只给这一类台词指派声音',
  )
  ..addOption(
    'scope',
    allowed: <String>['volume', 'series'],
    help: '声音指派写到哪：volume 只这一卷（默认）/ series 整个系列',
  );

CtlRequestSpec _buildCharacter(CtlCommandContext c) {
  final String path =
      '${_item(c)}/characters/${Uri.encodeComponent(c.positional(1, '角色名').trim())}';
  final String? voice = c.option('voice');
  final bool clear = c.flag('clear-voice');
  if (voice != null && clear) {
    throw const CtlUsageError('--voice 与 --clear-voice 只能给一个');
  }
  final Map<String, Object?> body = <String, Object?>{
    if (c.option('rename') case final String rename) 'rename': rename,
    if (voice != null) 'voice': voice,
    if (clear) 'voice': '',
    if (c.option('kind') case final String kind) 'kind': kind,
    if (c.option('scope') case final String scope) 'scope': scope,
  };
  if (!body.containsKey('rename') && !body.containsKey('voice')) {
    throw const CtlUsageError('至少给 --rename、--voice 或 --clear-voice');
  }
  return CtlRequestSpec.put(path, body: body);
}

void _configureRegenerate(ArgParser parser) =>
    parser.addOption('seed', help: '种子（0-4294967295）；不给 = 随机');

CtlRequestSpec _buildRegenerate(CtlCommandContext c) {
  final String path =
      '${_item(c)}/lines/${Uri.encodeComponent(c.positional(1, '行 id').trim())}/regenerate';
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      if (_intOption(c, 'seed') case final int seed) 'seed': seed,
    },
  );
}

void _configureRegenerateCharacter(ArgParser parser) => parser
  ..addOption(
    'kind',
    allowed: _kinds.where((String k) => k != 'skip'),
    help: '只重生成这一类台词',
  )
  ..addFlag('dry-run', negatable: false, help: '只列出会重生成 / 跳过的句子，不动任何东西');

CtlRequestSpec _buildRegenerateCharacter(CtlCommandContext c) {
  final String path =
      '${_item(c)}/characters/${Uri.encodeComponent(c.positional(1, '角色名').trim())}/regenerate';
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      if (c.option('kind') case final String kind) 'kind': kind,
      if (c.flag('dry-run')) 'dryRun': true,
    },
  );
}

void _configureReplace(ArgParser parser) => parser
  ..addOption('map', help: '映射 JSON 文件：{"行 id": "音频路径"}（相对路径按该文件所在目录）')
  ..addFlag('dry-run', negatable: false, help: '只逐句预检，不动任何东西');

CtlRequestSpec _buildReplace(CtlCommandContext c) {
  final String path = '${_item(c)}/lines/replace';
  final Map<String, String> files = <String, String>{};
  for (final String raw in c.rest.skip(1)) {
    final int eq = raw.indexOf('=');
    if (eq <= 0 || eq == raw.length - 1) {
      throw CtlUsageError('应为 <行 id>=<音频路径>，收到「$raw」');
    }
    files[raw.substring(0, eq).trim()] = ctlAbsolutePath(
      raw.substring(eq + 1).trim(),
    );
  }
  final String? map = c.option('map');
  if ((map == null) == files.isEmpty) {
    throw const CtlUsageError('给 <行 id>=<音频路径>（可多个）或 --map <映射 JSON>，二选一');
  }
  c.positional(0, 'key');
  return CtlRequestSpec.post(
    path,
    body: <String, Object?>{
      if (files.isNotEmpty) 'files': files,
      if (map != null) 'mapping': ctlAbsolutePath(map),
      if (c.flag('dry-run')) 'dryRun': true,
    },
  );
}

void _configureRender(ArgParser parser) =>
    parser.addOption('voice', help: '没有更细指派时用的声音 id（默认：上次生成的声音 / 当前朗读声音）');

CtlRequestSpec _buildRender(CtlCommandContext c) => CtlRequestSpec.post(
  '${_item(c)}/render',
  body: <String, Object?>{
    if (c.option('voice') case final String voice) 'voice': voice,
  },
);

CtlRequestSpec _buildRenderCancel(CtlCommandContext c) =>
    CtlRequestSpec.post('${_item(c)}/render/cancel');

void _configureImport(ArgParser parser) =>
    parser.addFlag('yes', negatable: false, help: '这一卷已有有声成品时确认替换');

CtlRequestSpec _buildImport(CtlCommandContext c) => CtlRequestSpec.post(
  '${_item(c)}/import',
  body: <String, Object?>{
    'manifest': ctlAbsolutePath(c.positional(1, 'manifest.json')),
    if (c.flag('yes')) 'confirm': true,
  },
);

// ── render ──────────────────────────────────────────────────────────────

String _renderVoices(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[('id', 'id'), ('名称', 'name'), ('引擎', 'provider')],
  listKey: 'voices',
  empty: '没有可用的声音（先在朗读设置里加一个声音）',
);

String _renderScript(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer(
    '${data['title']}（${data['key']}）\n'
    '页 ${data['pages']}，已标注 ${data['annotatedPages']}；'
    '行 ${data['lines']}（发声 ${data['audibleLines']}），'
    '说话人不明 ${data['unknownSpeakerLines']}，待复核 ${data['needsReviewLines']}',
  );
  if (data['needsReannotation'] == true) out.write('\nOCR 重跑过：需要重新标注');
  out.write(data['rendered'] == true ? '\n已生成音频' : '\n还没生成音频');
  out.write('\n');
  out.write(
    renderCtlTable(data['roster'], const <(String, String)>[
      ('角色', 'name'),
      ('行数', 'lines'),
      ('声音', 'voice'),
    ], empty: '角色表为空'),
  );
  return out.toString();
}

String _renderPage(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String head =
      '第 ${data['page']} 页'
      '${data['annotated'] == true ? '' : '（未标注）'}';
  return '$head\n${renderCtlTable(data['lines'], const <(String, String)>[('id', 'id'), ('说话人', 'speaker'), ('类型', 'kind'), ('文字', 'text')], empty: '这一页没有行')}';
}

String _task(Object? task) {
  if (task is! Map) return '无';
  final Object? error = task['error'];
  return '${task['status']} ${task['done']}/${task['total']}'
      '${error == null ? '' : '：$error'}';
}

String _renderStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '标注：${_task(data['annotate'])}\n生成：${_task(data['render'])}';
}

String _renderStatusPart(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? render = data['render'];
  if (render is Map) {
    return '${data['alreadyQueued'] == true ? '已在队列里' : '已排进队列'}：${_task(render)}';
  }
  return '已开始标注：${_task(data)}';
}

String _renderRegenerateCharacter(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> lines = data['lines'] is List
      ? data['lines']! as List<Object?>
      : const <Object?>[];
  final List<Object?> skipped = data['skipped'] is List
      ? data['skipped']! as List<Object?>
      : const <Object?>[];
  final StringBuffer out = StringBuffer(
    data['dryRun'] == true
        ? '${data['name']}：会重生成 ${lines.length} 句，跳过 ${skipped.length} 句\n'
        : '${data['name']}：${lines.length} 句已排进队列（${_task(data['render'])}），'
              '跳过 ${skipped.length} 句\n',
  );
  out.write(
    renderCtlTable(lines, const <(String, String)>[
      ('id', 'line'),
      ('页', 'page'),
      ('类型', 'kind'),
      ('文字', 'text'),
    ], empty: '没有要重生成的句子'),
  );
  if (skipped.isNotEmpty) {
    out.write('\n跳过：\n');
    out.write(
      renderCtlTable(skipped, const <(String, String)>[
        ('id', 'line'),
        ('原因', 'reason'),
      ]),
    );
  }
  return out.toString();
}

String _renderReplace(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String head = data['dryRun'] == true
      ? (data['ok'] == true ? '预检通过，可以换' : '预检没通过（什么都没改）')
      : '已换 ${data['replaced']} 句，原样 ${data['unchanged']} 句';
  final List<(String, String)> columns = data['dryRun'] == true
      ? const <(String, String)>[
          ('id', 'line'),
          ('结果', 'code'),
          ('说明', 'message'),
          ('文件', 'file'),
        ]
      : const <(String, String)>[
          ('id', 'line'),
          ('结果', 'status'),
          ('时长', 'durationMs'),
          ('原时长', 'previousDurationMs'),
        ];
  return '$head\n${renderCtlTable(data['lines'], columns, empty: '没有句子')}';
}

String _renderImport(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['replaced'] == true ? '已替换' : '已导入'}：${data['key']}，'
      '${data['pages']} 页 ${data['lines']} 句，'
      '共 ${((data['durationMs'] as num? ?? 0) / 1000).toStringAsFixed(1)} 秒'
      '${data['replaced'] == true ? '（原成品：${data['previous']}）' : ''}';
}
