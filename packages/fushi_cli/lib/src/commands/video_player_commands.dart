import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli video` 组里的播放页命令（app 侧路由见
/// `fushi/lib/src/ops/ctl_video_player_routes.dart`）：音量 / 音轨 /
/// 主副字幕、字幕导入与生成（整轨 OCR / 语音转录 / 重定时 / 对轴）、对当前句制卡、
/// 暂存制卡队列、片段导出与长任务查询 / 取消。全部作用于当前最上层的视频播放页
/// （暂存队列可用 --book 指定别的视频）。
const List<CtlCommandSpec> videoPlayerCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'player',
    summary: '当前视频播放页的状态（位置 / 倍速 / 音量 / 音轨 / 主副字幕）',
    build: _buildPlayer,
    render: _renderPlayer,
  ),
  CtlCommandSpec(
    name: 'volume',
    summary: '设音量（0–100）或切换静音（--mute）',
    usage: '[<0-100>]',
    configure: _configureVolume,
    build: _buildVolume,
    render: _renderVolume,
  ),
  CtlCommandSpec(
    name: 'audio',
    summary: '列出音轨；给出 id 时切到该音轨',
    usage: '[<音轨 id>]',
    build: _buildAudio,
    render: _renderAudio,
  ),
  CtlCommandSpec(
    name: 'subs',
    summary: '列出可选字幕轨与当前主 / 副字幕',
    build: _buildSubs,
    render: _renderSubs,
  ),
  CtlCommandSpec(
    name: 'sub',
    summary: '选主字幕（序号 / 源，off 关闭）',
    usage: '<序号|源|off>',
    build: _buildSub,
    render: _renderSubs,
  ),
  CtlCommandSpec(
    name: 'sub2',
    summary: '选副字幕（序号 / 源，off 关闭）',
    usage: '<序号|源|off>',
    build: _buildSub2,
    render: _renderSubs,
  ),
  CtlCommandSpec(
    name: 'sub-import',
    summary: '导入外部字幕文件并选为主字幕（远端视频可 --secondary 选为副字幕）',
    usage: '<字幕文件>',
    configure: _configureSubImport,
    build: _buildSubImport,
    render: _renderSubImport,
  ),
  CtlCommandSpec(
    name: 'sub-ocr',
    summary: '把图形字幕轨（PGS / VobSub / DVB）整轨 OCR 成文字字幕（需 --yes）',
    usage: '<图形轨序号|源>',
    configure: _configureSubOcr,
    build: _buildSubOcr,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'sub-asr',
    summary: '用设备端语音模型从音轨生成字幕',
    configure: _configureAsr,
    build: _buildSubAsr,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'sub-retime',
    summary: '用设备端语音模型逐句重定时当前字幕（另存新档）',
    configure: _configureAsr,
    build: _buildSubRetime,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'sub-align',
    summary: '按视频内封文本轨给当前外挂字幕对时间轴（另存新档）',
    configure: _configureAlign,
    build: _buildSubAlign,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'clip',
    summary: '导出片段（含当前字幕烧录），时间写秒数或 [hh:]mm:ss[.ms]',
    usage: '<起> <止>',
    configure: _configureClip,
    build: _buildClip,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'mine',
    summary: '对当前字幕句制卡（与查词弹窗「+」同一条落卡链路）',
    usage: '<词>',
    configure: _configureMine,
    build: _buildMine,
    render: _renderMine,
  ),
  CtlCommandSpec(
    name: 'mine-queue',
    summary: '列出暂存（看完再制卡）的待写入 / 写入失败卡片',
    configure: _configureBook,
    build: _buildMineQueue,
    render: _renderMineQueue,
  ),
  CtlCommandSpec(
    name: 'mine-send',
    summary: '把暂存卡片全部写入 Anki',
    configure: _configureBook,
    build: _buildMineSend,
    render: _renderMineSend,
  ),
  CtlCommandSpec(
    name: 'mine-discard',
    summary: '丢弃一张暂存卡片（需 --yes）',
    usage: '<暂存卡 id>',
    configure: _configureDiscard,
    build: _buildMineDiscard,
    render: _renderMineDiscard,
  ),
  CtlCommandSpec(
    name: 'jobs',
    summary: '列出视频页长任务（字幕 OCR / 转录 / 对轴 / 片段导出）',
    build: _buildJobs,
    render: _renderJobs,
  ),
  CtlCommandSpec(
    name: 'job',
    summary: '查看一个长任务的进度与结果',
    usage: '<任务 id>',
    configure: _configureJob,
    build: _buildJob,
    render: _renderJob,
  ),
  CtlCommandSpec(
    name: 'job-cancel',
    summary: '取消一个长任务',
    usage: '<任务 id>',
    build: _buildJobCancel,
    render: _renderJob,
  ),
];

const String _player = '/api/admin/video/player';

void _addWait(ArgParser parser) => parser.addFlag(
  'wait',
  negatable: false,
  help: '等任务结束再返回（缺省立即返回任务 id，用 video job <id> 查进度）',
);

// ── player / volume / audio ──────────────────────────────────────────────

CtlRequestSpec _buildPlayer(CtlCommandContext context) =>
    const CtlRequestSpec.get(_player);

String _clock(Object? ms) {
  if (ms is! num) return '--:--';
  final int total = ms ~/ 1000;
  final String mm = ((total % 3600) ~/ 60).toString().padLeft(2, '0');
  final String ss = (total % 60).toString().padLeft(2, '0');
  return total >= 3600 ? '${total ~/ 3600}:$mm:$ss' : '$mm:$ss';
}

String _renderPlayer(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['active'] != true) return '没有打开的视频播放页';
  if (data['ready'] != true) return '视频还在加载';
  return <String>[
    '${data['title'] ?? data['bookUid']}  '
        '${data['playing'] == true ? '播放中' : '已暂停'}  '
        '${_clock(data['positionMs'])} / ${_clock(data['durationMs'])}  '
        '×${data['speed']}  音量 ${(data['volume'] as num?)?.round() ?? '?'}',
    '音轨：${data['audioTrack'] ?? '默认'}  主字幕：${_subLabel(data['subtitle'])}  '
        '副字幕：${_subLabel(data['secondarySubtitle'])}',
    if (data['cue'] != null) '当前句：${data['cue']}',
  ].join('\n');
}

void _configureVolume(ArgParser parser) {
  parser.addFlag('mute', negatable: false, help: '切换静音');
}

CtlRequestSpec _buildVolume(CtlCommandContext context) {
  final String? raw = context.optionalPositional(0);
  final bool mute = context.flag('mute');
  if ((raw == null) == !mute) {
    throw const CtlUsageError('给出音量（0–100）或 --mute，二选一');
  }
  if (mute) {
    return const CtlRequestSpec.post(
      '$_player/volume',
      body: <String, Object?>{'mute': true},
    );
  }
  final double? volume = double.tryParse(raw!);
  if (volume == null || volume < 0 || volume > 100) {
    throw CtlUsageError('音量必须在 0–100 之间：$raw');
  }
  return CtlRequestSpec.post(
    '$_player/volume',
    body: <String, Object?>{'volume': volume},
  );
}

String _renderVolume(Object? data) => data is Map
    ? '音量 ${(data['volume'] as num?)?.round() ?? '?'}'
    : renderCtlJson(data);

CtlRequestSpec _buildAudio(CtlCommandContext context) {
  final String? id = context.optionalPositional(0);
  if (id == null) return const CtlRequestSpec.get('$_player/audio-tracks');
  return CtlRequestSpec.post(
    '$_player/audio-track',
    body: <String, Object?>{'id': id},
  );
}

String _renderAudio(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('名称', 'label'),
    ('语言', 'language'),
    ('当前', 'selected'),
  ],
  listKey: 'tracks',
  empty: '没有音轨',
);

// ── subs / sub / sub2 / sub-import ───────────────────────────────────────

CtlRequestSpec _buildSubs(CtlCommandContext context) =>
    const CtlRequestSpec.get('$_player/subtitles');

CtlRequestSpec _selectSub(CtlCommandContext context, {required bool second}) {
  final String target = context.positional(0, '序号|源|off').trim();
  return CtlRequestSpec.post(
    '$_player/subtitle',
    body: <String, Object?>{
      if (target.toLowerCase() == 'off') 'off': true else 'source': target,
      if (second) 'secondary': true,
    },
  );
}

CtlRequestSpec _buildSub(CtlCommandContext context) =>
    _selectSub(context, second: false);

CtlRequestSpec _buildSub2(CtlCommandContext context) =>
    _selectSub(context, second: true);

String _renderSubs(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('序号', 'index'),
      ('名称', 'label'),
      ('类型', 'kind'),
      ('语言', 'language'),
      ('主', 'primary'),
      ('副', 'secondary'),
      ('可OCR', 'ocr'),
      ('可选', 'selectable'),
      ('源', 'source'),
    ],
    listKey: 'tracks',
    empty: '没有可选字幕轨',
  );
  return <String>[
    table,
    '主字幕：${_subLabel(data['primary'])}  副字幕：${_subLabel(data['secondary'])}',
  ].join('\n');
}

String _subLabel(Object? source) {
  if (source == null) return '未选';
  if (source == 'off:') return '关闭';
  return '$source';
}

void _configureSubImport(ArgParser parser) {
  parser.addFlag(
    'secondary',
    negatable: false,
    help: '导入为副字幕（只有远端视频的副字幕区有导入，本机视频先导入再 sub2 选）',
  );
}

CtlRequestSpec _buildSubImport(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '$_player/subtitle/import',
      body: <String, Object?>{
        'path': ctlAbsolutePath(context.positional(0, '字幕文件')),
        if (context.flag('secondary')) 'secondary': true,
      },
    );

String _renderSubImport(Object? data) =>
    data is Map ? '已导入并选为主字幕：${data['subtitle']}' : renderCtlJson(data);

// ── sub-ocr / sub-asr / sub-retime / sub-align ───────────────────────────

void _configureSubOcr(ArgParser parser) {
  parser.addFlag(
    'yes',
    abbr: 'y',
    negatable: false,
    help: '确认开始（耗时较长，按 OCR 设置可能调用在线识别 / AI 重读）',
  );
  parser
    ..addFlag(
      'consent-llm',
      help:
          '首次使用时回答「低置信度结果默认交给 LLM」：--consent-llm 开启、'
          '--no-consent-llm 不用（与 app 首次询问写同一个档位；已选过则忽略）',
    )
    ..addFlag(
      'consent-upload',
      negatable: false,
      help: '同意把视频画面上传到 Google Lens（OCR 引擎解析到 Lens 时需要；与 app 披露框同一份记录）',
    );
  _addWait(parser);
}

CtlRequestSpec _buildSubOcr(CtlCommandContext context) {
  final String source = context.positional(0, '图形轨序号|源');
  if (!context.flag('yes')) {
    throw const CtlUsageError('整轨 OCR 需要 --yes 确认开始');
  }
  return CtlRequestSpec.post(
    '$_player/subtitle/ocr',
    body: <String, Object?>{
      'source': source,
      'confirm': true,
      if (context.explicitFlag('consent-llm') case final bool llm)
        'consentLlm': llm,
      if (context.flag('consent-upload')) 'consentUpload': true,
      if (context.flag('wait')) 'wait': true,
    },
  );
}

void _configureAsr(ArgParser parser) {
  parser.addOption('language', help: '转录语言标签（ja / en / zh …，缺省用上次转录语言）');
  _addWait(parser);
}

CtlRequestSpec _transcribe(CtlCommandContext context, {required bool retime}) {
  final String? language = context.option('language');
  return CtlRequestSpec.post(
    '$_player/subtitle/transcribe',
    body: <String, Object?>{
      if (language != null) 'language': language,
      if (retime) 'retime': true,
      if (context.flag('wait')) 'wait': true,
    },
  );
}

CtlRequestSpec _buildSubAsr(CtlCommandContext context) =>
    _transcribe(context, retime: false);

CtlRequestSpec _buildSubRetime(CtlCommandContext context) =>
    _transcribe(context, retime: true);

void _configureAlign(ArgParser parser) {
  parser.addFlag(
    'yes',
    abbr: 'y',
    negatable: false,
    help: '证据不足时仍应用 / 当前是对齐产物时恢复原始时间轴（缺省只报需要确认）',
  );
  _addWait(parser);
}

CtlRequestSpec _buildSubAlign(CtlCommandContext context) => CtlRequestSpec.post(
  '$_player/subtitle/align',
  body: <String, Object?>{
    if (context.flag('yes')) 'confirm': true,
    if (context.flag('wait')) 'wait': true,
  },
);

// ── clip ─────────────────────────────────────────────────────────────────

void _configureClip(ArgParser parser) {
  parser.addOption(
    'output',
    abbr: 'o',
    help: '输出 .mp4 路径（缺省落 app 文档目录 video_clips/）',
  );
  _addWait(parser);
}

/// 时间：纯秒数（可带小数），或 `[hh:]mm:ss[.ms]`。返回毫秒。
int parseCliVideoTimeMs(String raw) {
  final String text = raw.trim();
  final double? seconds = double.tryParse(text);
  if (seconds != null) {
    if (seconds < 0) throw CtlUsageError('时间不能为负：$raw');
    return (seconds * 1000).round();
  }
  final RegExpMatch? m = RegExp(
    r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$',
  ).firstMatch(text);
  if (m == null) {
    throw CtlUsageError('时间格式不对：$raw（秒数，或 [hh:]mm:ss[.ms]）');
  }
  final int hours = int.parse(m.group(1) ?? '0');
  final int minutes = int.parse(m.group(2)!);
  final int secs = int.parse(m.group(3)!);
  if (minutes > 59 || secs > 59) throw CtlUsageError('时间格式不对：$raw');
  final int millis = int.parse((m.group(4) ?? '0').padRight(3, '0'));
  return ((hours * 60 + minutes) * 60 + secs) * 1000 + millis;
}

CtlRequestSpec _buildClip(CtlCommandContext context) {
  final int start = parseCliVideoTimeMs(context.positional(0, '起'));
  final int end = parseCliVideoTimeMs(context.positional(1, '止'));
  if (end <= start) throw const CtlUsageError('结束时间必须晚于开始时间');
  final String? output = context.option('output');
  return CtlRequestSpec.post(
    '$_player/clip',
    body: <String, Object?>{
      'startMs': start,
      'endMs': end,
      if (output != null) 'output': ctlAbsolutePath(output),
      if (context.flag('wait')) 'wait': true,
    },
  );
}

// ── mine ─────────────────────────────────────────────────────────────────

void _configureMine(ArgParser parser) {
  parser
    ..addOption('reading', help: '读音（缺省从查词结果补）')
    ..addOption('glossary', help: '释义 HTML（缺省从查词结果补）')
    ..addOption('sentence', help: '例句（缺省用当前字幕句）')
    ..addMultiOption('field', help: '额外制卡字段 key=value（可重复）')
    ..addFlag('allow-duplicate', negatable: false, help: '已有同词卡片时仍新增')
    ..addFlag(
      'lookup',
      defaultsTo: true,
      help: '缺读音 / 释义时查词典补（--no-lookup 关闭）',
    );
}

CtlRequestSpec _buildMine(CtlCommandContext context) {
  final String word = context.joinedRest(0, '词');
  final Map<String, String> fields = <String, String>{};
  for (final String pair in context.multiOption('field')) {
    final int eq = pair.indexOf('=');
    if (eq <= 0) throw CtlUsageError('--field 必须是 key=value：$pair');
    fields[pair.substring(0, eq).trim()] = pair.substring(eq + 1);
  }
  return CtlRequestSpec.post(
    '$_player/mine',
    body: <String, Object?>{
      'word': word,
      if (context.option('reading') case final String reading)
        'reading': reading,
      if (context.option('glossary') case final String glossary)
        'glossary': glossary,
      if (context.option('sentence') case final String sentence)
        'sentence': sentence,
      if (fields.isNotEmpty) 'fields': fields,
      if (context.flag('allow-duplicate')) 'allowDuplicate': true,
      if (!context.flag('lookup')) 'lookup': false,
    },
  );
}

String _renderMine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String word = '${data['expression']}';
  final String sentence = data['sentence'] == null
      ? ''
      : '\n  句子：${data['sentence']}';
  if (data['duplicate'] == true) {
    return '未制卡：Anki 里已有「$word」（--allow-duplicate 强制新增）$sentence';
  }
  if (data['queued'] == true) {
    return '已收下：$word（后台 / 看完再制卡，稍后落地；video mine-queue 查看）$sentence';
  }
  return '已制卡：$word'
      '${data['noteId'] == null ? '' : '（note ${data['noteId']}）'}$sentence';
}

// ── mine-queue / mine-send / mine-discard ────────────────────────────────

void _configureBook(ArgParser parser) {
  parser.addOption('book', help: '视频 bookUid（缺省当前播放的视频）');
}

void _configureDiscard(ArgParser parser) {
  _configureBook(parser);
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认丢弃');
}

Map<String, String> _bookQuery(CtlCommandContext context) => <String, String>{
  if (context.option('book') case final String book) 'bookUid': book,
};

CtlRequestSpec _buildMineQueue(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/video/mine-queue',
  query: _bookQuery(context),
);

String _renderMineQueue(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('状态', 'status'),
    ('词', 'expression'),
    ('句子', 'sentence'),
    ('错误', 'error'),
  ],
  listKey: 'items',
  empty: '没有暂存的卡片',
);

CtlRequestSpec _buildMineSend(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/video/mine-queue/commit',
  body: _bookQuery(context),
);

String _renderMineSend(Object? data) => data is Map
    ? '写入完成：成功 ${data['succeeded']} / 失败 ${data['failed']}'
          '${data['firstError'] == null ? '' : '（${data['firstError']}）'}'
    : renderCtlJson(data);

CtlRequestSpec _buildMineDiscard(CtlCommandContext context) {
  final String id = context.positional(0, '暂存卡 id').trim();
  if (!RegExp(r'^[1-9]\d*$').hasMatch(id)) {
    throw CtlUsageError('暂存卡 id 必须是正整数：$id');
  }
  if (!context.flag('yes')) throw const CtlUsageError('丢弃暂存卡需要 --yes 确认');
  return CtlRequestSpec.post(
    '/api/admin/video/mine-queue/$id/discard',
    body: <String, Object?>{..._bookQuery(context), 'confirm': true},
  );
}

String _renderMineDiscard(Object? data) =>
    data is Map ? '已丢弃暂存卡 ${data['discarded']}' : renderCtlJson(data);

// ── jobs ─────────────────────────────────────────────────────────────────

CtlRequestSpec _buildJobs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/video/jobs');

String _renderJobs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('种类', 'kind'),
    ('状态', 'status'),
    ('阶段', 'phase'),
    ('进度', 'progress'),
    ('错误', 'error'),
  ],
  listKey: 'jobs',
  empty: '没有视频页任务',
);

void _configureJob(ArgParser parser) {
  parser.addFlag('wait', negatable: false, help: '等任务结束再返回');
}

String _jobId(CtlCommandContext context) {
  final String id = context.positional(0, '任务 id').trim();
  if (!RegExp(r'^vj[1-9]\d*$').hasMatch(id)) {
    throw CtlUsageError('任务 id 格式不对：$id（vj<N>，见 video jobs）');
  }
  return id;
}

CtlRequestSpec _buildJob(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/video/jobs/${_jobId(context)}',
  query: <String, String>{if (context.flag('wait')) 'wait': 'true'},
);

CtlRequestSpec _buildJobCancel(CtlCommandContext context) =>
    CtlRequestSpec.post('/api/admin/video/jobs/${_jobId(context)}/cancel');

String _renderJob(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? progress = data['progress'];
  final String percent = progress is num ? ' ${(progress * 100).round()}%' : '';
  final Object? result = data['result'];
  final List<String> lines = <String>[
    '任务 ${data['id']}（${data['kind']}）：${data['status']} · ${data['phase']}$percent'
        '${data['detail'] == null ? '' : ' · ${data['detail']}'}',
    if (data['status'] == 'running')
      '（fushi_cli video job ${data['id']} 查进度，video job-cancel ${data['id']} 取消）',
    if (result is Map && result['subtitle'] != null)
      '新字幕：${result['subtitle']}',
    if (result is Map && result['path'] != null) '已导出：${result['path']}',
    if (data['error'] != null) '原因：${data['error']}',
  ];
  return lines.join('\n');
}
