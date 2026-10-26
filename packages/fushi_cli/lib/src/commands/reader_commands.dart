import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'library_commands.dart' show libraryItemPath;

/// 阅读会话遥控、有声书、漫画 OCR 命令组（app 侧路由见
/// `fushi/lib/src/ops/ctl_reader_routes.dart` /
/// `ctl_audiobook_routes.dart` / `ctl_manga_ocr_routes.dart`）。
const List<CtlCommandGroup> readerCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'reader',
    summary: '当前阅读器（EPUB / PDF / 漫画）：查看位置、翻页、跳章 / 跳页 / 跳百分比',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'status',
        summary: '当前阅读位置',
        build: _buildReaderStatus,
        render: _renderReader,
      ),
      CtlCommandSpec(
        name: 'next',
        summary: '下一页',
        configure: _configureTurn,
        build: _buildNext,
        render: _renderReader,
      ),
      CtlCommandSpec(
        name: 'prev',
        summary: '上一页',
        configure: _configureTurn,
        build: _buildPrev,
        render: _renderReader,
      ),
      CtlCommandSpec(
        name: 'goto',
        summary:
            'EPUB：--chapter [--progress] / --percent；PDF：--page；漫画：--page / --chapter（在线第几话）',
        configure: _configureGoto,
        build: _buildGoto,
        render: _renderReader,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'audiobook',
    summary: '有声书：挂 / 换音频与字幕、重新匹配、设备端转录任务',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'attach',
        summary: '给书挂有声书，或替换已有有声书 / 字幕书的音频、字幕（后台任务；--wait 等结束）',
        usage: '<key>',
        configure: _configureAttach,
        build: _buildAttach,
        render: _renderTask,
      ),
      CtlCommandSpec(
        name: 'rematch',
        summary: '用已存字幕重新对正文做匹配（后台任务；--wait 等结束）',
        usage: '<key>',
        configure: _configureRematch,
        build: _buildRematch,
        render: _renderTask,
      ),
      CtlCommandSpec(
        name: 'tasks',
        summary: '挂载 / 替换 / 重新匹配任务列表',
        build: _buildTasks,
        render: _renderTasks,
      ),
      CtlCommandSpec(
        name: 'task',
        summary: '单个挂载 / 匹配任务的进度（--wait 等到结束）',
        usage: '<id>',
        configure: _configureWait,
        build: _buildTask,
        render: _renderTask,
      ),
      CtlCommandSpec(
        name: 'task-cancel',
        summary: '取消挂载 / 匹配任务（进入写入阶段后不可取消）',
        usage: '<id>',
        build: _buildTaskCancel,
        render: _renderTask,
      ),
      CtlCommandSpec(
        name: 'transcribe',
        summary: '把音频排进设备端转录队列，转完自动入库（--text 带正文对齐 / --into 挂到已有书）',
        usage: '<音频...>',
        configure: _configureTranscribe,
        build: _buildTranscribe,
        render: _renderJob,
      ),
      CtlCommandSpec(
        name: 'jobs',
        summary: '转录任务列表',
        build: _buildJobs,
        render: _renderJobs,
      ),
      CtlCommandSpec(
        name: 'job',
        summary: '单个转录任务的进度',
        usage: '<id>',
        build: _buildJob,
        render: _renderJob,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消转录任务（进度保留，可 retry 续跑）',
        usage: '<id>',
        build: _buildJobCancel,
        render: _renderJob,
      ),
      CtlCommandSpec(
        name: 'retry',
        summary: '重试失败 / 已取消的转录任务',
        usage: '<id>',
        build: _buildJobRetry,
        render: _renderJob,
      ),
      CtlCommandSpec(
        name: 'job-rm',
        summary: '从列表移除已结束的转录任务（不删文件）',
        usage: '<id>',
        build: _buildJobRemove,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'ocr',
    summary: '漫画 OCR：启动、查看进度、取消',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'start',
        summary: '识别漫画还没识别的部分（--force 整卷重跑；Lens 引擎需 --consent-upload）',
        usage: '<key>',
        configure: _configureOcrStart,
        build: _buildOcrStart,
        render: _renderOcr,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '识别进度（不给键 = 全部在跑的任务）',
        usage: '[<key>]',
        build: _buildOcrStatus,
        render: _renderOcr,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消这部漫画的识别（含排队中的）',
        usage: '<key>',
        build: _buildOcrCancel,
      ),
    ],
  ),
];

const String _readerPath = '/api/admin/library/reader';
const String _jobsPath = '/api/admin/library/audiobook/jobs';
const String _tasksPath = '/api/admin/library/audiobook/tasks';
const String _ocrPath = '/api/admin/library/ocr';

/// `ocr start --engine` 的值域（与 app 设置里的 OCR 引擎偏好键同名，不含 auto）。
const List<String> kOcrEngineKeys = <String>[
  'local_onnx',
  'system_ocr',
  'google_lens',
  'external_mokuro',
  'paired_host',
];

// ── reader ─────────────────────────────────────────────────────────────

CtlRequestSpec _buildReaderStatus(CtlCommandContext context) =>
    const CtlRequestSpec.get(_readerPath);

void _configureTurn(ArgParser parser) =>
    parser.addOption('count', abbr: 'n', help: '翻几页（缺省 1，最多 50）');

CtlRequestSpec _turn(CtlCommandContext context, String direction) {
  final int? count = context.intOption('count');
  if (count != null && (count < 1 || count > 50)) {
    throw const CtlUsageError('--count 必须在 1–50 之间');
  }
  return CtlRequestSpec.post(
    '$_readerPath/turn',
    body: <String, Object?>{
      'direction': direction,
      if (count != null) 'count': count,
    },
  );
}

CtlRequestSpec _buildNext(CtlCommandContext context) => _turn(context, 'next');

CtlRequestSpec _buildPrev(CtlCommandContext context) => _turn(context, 'prev');

void _configureGoto(ArgParser parser) => parser
  ..addOption('chapter', help: 'EPUB 第几章 / 在线漫画第几话（1 起计）')
  ..addOption('progress', help: 'EPUB：配合 --chapter 的章内百分比 0–100')
  ..addOption('percent', help: 'EPUB：全书百分比 0–100')
  ..addOption('page', help: 'PDF / 漫画：第几页（1 起计）');

double? _doubleOption(CtlCommandContext context, String name) {
  final String? raw = context.option(name);
  if (raw == null) return null;
  final double? value = double.tryParse(raw);
  if (value == null) throw CtlUsageError('--$name 必须是数字');
  return value;
}

CtlRequestSpec _buildGoto(CtlCommandContext context) {
  final int? chapter = context.intOption('chapter');
  final int? page = context.intOption('page');
  final double? percent = _doubleOption(context, 'percent');
  final double? progress = _doubleOption(context, 'progress');
  final int given = <Object?>[
    chapter,
    page,
    percent,
  ].where((Object? v) => v != null).length;
  if (given != 1) {
    throw const CtlUsageError('--chapter / --page / --percent 只给一个');
  }
  if (progress != null && chapter == null) {
    throw const CtlUsageError('--progress 只配合 --chapter');
  }
  return CtlRequestSpec.post(
    '$_readerPath/goto',
    body: <String, Object?>{
      if (chapter != null) 'chapter': chapter,
      if (page != null) 'page': page,
      if (progress != null) 'progress': progress,
      if (percent != null) 'percent': percent,
    },
  );
}

String _renderReader(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['active'] != true) return '（没有打开的阅读器）';
  final List<String> parts = <String>[];
  if (data['chapter'] != null) {
    final String unit = data['kind'] == 'manga' ? '话' : '章';
    final StringBuffer chapter = StringBuffer(
      '第 ${data['chapter']}/${data['chapterCount']} $unit',
    );
    if (data['chapterProgress'] != null) {
      chapter.write('（章内 ${data['chapterProgress']}%）');
    }
    parts.add(chapter.toString());
  }
  if (data['page'] != null) {
    parts.add('第 ${data['page']}/${data['pageCount']} 页');
  }
  if (data['percent'] != null) parts.add('全书 ${data['percent']}%');
  final StringBuffer out = StringBuffer(
    '[${data['kind']}] ${data['title'] ?? data['key']}：${parts.join('，')}',
  );
  if (data['ready'] != true) out.write('（加载中）');
  return out.toString();
}

// ── audiobook ──────────────────────────────────────────────────────────

void _configureAttach(ArgParser parser) => parser
  ..addMultiOption('audio', abbr: 'a', help: '音频文件（可重复，按给出顺序拼接）')
  ..addOption(
    'subtitle',
    abbr: 's',
    help: '对齐用字幕（srt/lrc/vtt/ass/ssa/smil/json）',
  )
  ..addFlag('wait', negatable: false, help: '等任务结束再返回（缺省立即返回任务 id）');

void _configureWait(ArgParser parser) =>
    parser.addFlag('wait', negatable: false, help: '等任务结束再返回');

CtlRequestSpec _buildAttach(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final List<String> audio = <String>[
    for (final String raw in context.multiOption('audio'))
      if (raw.trim().isNotEmpty) ctlAbsolutePath(raw.trim()),
  ];
  final String? subtitle = context.option('subtitle');
  if (audio.isEmpty && subtitle == null) {
    throw const CtlUsageError('至少给 --audio 或 --subtitle');
  }
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/audiobook',
    body: <String, Object?>{
      if (audio.isNotEmpty) 'audio': audio,
      if (subtitle != null) 'subtitle': <String>[ctlAbsolutePath(subtitle)],
      if (context.flag('wait')) 'wait': true,
    },
  );
}

const Map<String, String> _attachModes = <String, String>{
  'attach': '已挂上有声书',
  'subtitle_replace': '已替换字幕并重新对齐',
  'audio_replace': '已替换音频',
  'srt_reimport': '字幕书已重新导入',
};

String _renderAttachResult(Map<Object?, Object?> data) {
  final StringBuffer out = StringBuffer(
    '${_attachModes['${data['mode']}'] ?? data['mode']}：${data['key']}',
  );
  if (data['cues'] != null) out.write('，${data['cues']} 句');
  if (data['audioFiles'] != null) out.write('，音频 ${data['audioFiles']} 个');
  if (data['health'] != null) out.write('，匹配 ${data['health']}');
  if (data['healthReason'] != null) out.write('（${data['healthReason']}）');
  return out.toString();
}

const Map<String, String> _taskStatusLabels = <String, String>{
  'running': '进行中',
  'done': '完成',
  'failed': '失败',
  'cancelled': '已取消',
};

String _taskLine(Map<Object?, Object?> task) {
  final StringBuffer out = StringBuffer(
    '${task['id']}  ${task['kind']}  ${task['key']}  '
    '${_taskStatusLabels['${task['status']}'] ?? task['status']}',
  );
  if (task['phase'] != null) out.write(' ${task['phase']}');
  if (task['progress'] != null) out.write(' ${task['progress']}%');
  if (task['cancelRequested'] == true) out.write('（正在取消）');
  return out.toString();
}

String _renderTask(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer(_taskLine(data));
  final Object? result = data['result'];
  if (result is Map) {
    out.write(
      '\n  ${data['kind'] == 'rematch' ? _renderRematchResult(result) : _renderAttachResult(result)}',
    );
  }
  if (data['error'] != null) out.write('\n  错误：${data['error']}');
  if (data['status'] == 'running') {
    out.write(
      '\n  进度：audiobook task ${data['id']}；取消：audiobook task-cancel ${data['id']}',
    );
  }
  return out.toString();
}

String _renderTasks(Object? data) {
  if (data is! Map || data['tasks'] is! List) return renderCtlJson(data);
  final List<Object?> tasks = data['tasks'] as List<Object?>;
  if (tasks.isEmpty) return '（没有挂载 / 匹配任务）';
  return <String>[
    for (final Object? task in tasks)
      if (task is Map) _taskLine(task),
  ].join('\n');
}

String _taskPath(CtlCommandContext context) =>
    '$_tasksPath/${Uri.encodeComponent(context.positional(0, 'id'))}';

CtlRequestSpec _buildTasks(CtlCommandContext context) =>
    const CtlRequestSpec.get(_tasksPath);

CtlRequestSpec _buildTask(CtlCommandContext context) => CtlRequestSpec.get(
  _taskPath(context),
  query: <String, String>{if (context.flag('wait')) 'wait': 'true'},
);

CtlRequestSpec _buildTaskCancel(CtlCommandContext context) =>
    CtlRequestSpec.post('${_taskPath(context)}/cancel');

void _configureRematch(ArgParser parser) => parser
  ..addOption('window', help: '搜索窗口（缺省自动探测最佳窗口）')
  ..addOption('threshold', help: '相似度阈值 (0, 1]')
  ..addFlag('wait', negatable: false, help: '等任务结束再返回');

CtlRequestSpec _buildRematch(CtlCommandContext context) {
  final String key = context.positional(0, 'key');
  final int? window = context.intOption('window');
  if (window != null && window <= 0) {
    throw const CtlUsageError('--window 必须大于 0');
  }
  final double? threshold = _doubleOption(context, 'threshold');
  return CtlRequestSpec.post(
    '${libraryItemPath(key)}/audiobook/rematch',
    body: <String, Object?>{
      if (window != null) 'window': window,
      if (threshold != null) 'threshold': threshold,
      if (context.flag('wait')) 'wait': true,
    },
  );
}

String _renderRematchResult(Map<Object?, Object?> data) {
  return '重新匹配 ${data['key']}：${data['matched']}/${data['total']} 句'
      '（${data['rate']}%，window=${data['window']}）';
}

void _configureTranscribe(ArgParser parser) => parser
  ..addOption('text', help: '正文（EPUB / 文本）；给了就转完对齐成有声书，没给成独立字幕书')
  ..addOption('into', help: '挂到库里已有的书（book:<bookKey> / srt:<uid>），与 --text 互斥')
  ..addOption('title', help: '书名（缺省按音频文件名推）');

CtlRequestSpec _buildTranscribe(CtlCommandContext context) {
  context.positional(0, '音频');
  final String? text = context.option('text');
  final String? title = context.option('title');
  final String? into = context.option('into');
  if (text != null && into != null) {
    throw const CtlUsageError('--text 与 --into 只给一个');
  }
  return CtlRequestSpec.post(
    _jobsPath,
    body: <String, Object?>{
      'audio': <String>[
        for (final String raw in context.rest)
          if (raw.trim().isNotEmpty) ctlAbsolutePath(raw.trim()),
      ],
      if (text != null) 'text': <String>[ctlAbsolutePath(text)],
      if (into != null) 'into': into,
      if (title != null) 'title': title,
    },
  );
}

String _jobPath(CtlCommandContext context) =>
    '$_jobsPath/${Uri.encodeComponent(context.positional(0, 'id'))}';

CtlRequestSpec _buildJobs(CtlCommandContext context) =>
    const CtlRequestSpec.get(_jobsPath);

CtlRequestSpec _buildJob(CtlCommandContext context) =>
    CtlRequestSpec.get(_jobPath(context));

CtlRequestSpec _buildJobCancel(CtlCommandContext context) =>
    CtlRequestSpec.post('${_jobPath(context)}/cancel');

CtlRequestSpec _buildJobRetry(CtlCommandContext context) =>
    CtlRequestSpec.post('${_jobPath(context)}/retry');

CtlRequestSpec _buildJobRemove(CtlCommandContext context) =>
    CtlRequestSpec.delete(_jobPath(context));

String _jobProgress(Map<Object?, Object?> job) {
  final Object? phase = job['phase'];
  final Object? progress = job['progress'];
  if (phase == null) return '${job['status']}';
  return progress == null
      ? '${job['status']}/$phase'
      : '${job['status']}/$phase $progress%';
}

String _renderJob(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer(
    '${data['id']}  ${data['title']}  ${_jobProgress(data)}',
  );
  if (data['error'] != null) out.write('\n  错误：${data['error']}');
  if (data['into'] != null) out.write('\n  挂到：${data['into']}');
  if (data['resultKey'] != null) out.write('\n  入库：${data['resultKey']}');
  return out.toString();
}

String _renderJobs(Object? data) {
  if (data is! Map || data['jobs'] is! List) return renderCtlJson(data);
  final List<Object?> jobs = data['jobs'] as List<Object?>;
  if (jobs.isEmpty) return '（没有转录任务）';
  return <String>[
    for (final Object? job in jobs)
      if (job is Map) '${job['id']}  ${_jobProgress(job)}  ${job['title']}',
  ].join('\n');
}

// ── ocr ────────────────────────────────────────────────────────────────

void _configureOcrStart(ArgParser parser) => parser
  ..addFlag('force', negatable: false, help: '连已识别的部分一起整卷重跑')
  ..addOption(
    'engine',
    help: '本次用哪个引擎（缺省按设置里的偏好；不改偏好）',
    allowed: kOcrEngineKeys,
  )
  ..addFlag(
    'consent-upload',
    negatable: false,
    help: '同意把漫画页面上传给 Google Lens（引擎是 Lens 且本机还没同意过时必需）',
  );

CtlRequestSpec _buildOcrStart(CtlCommandContext context) => CtlRequestSpec.post(
  _ocrPath,
  body: <String, Object?>{
    'key': context.positional(0, 'key'),
    if (context.flag('force')) 'force': true,
    if (context.option('engine') != null) 'engine': context.option('engine'),
    if (context.flag('consent-upload')) 'consentUpload': true,
  },
);

CtlRequestSpec _buildOcrStatus(CtlCommandContext context) {
  final String? key = context.optionalPositional(0);
  return CtlRequestSpec.get(
    _ocrPath,
    query: <String, String>{if (key != null) 'key': key},
  );
}

CtlRequestSpec _buildOcrCancel(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '$_ocrPath/cancel',
      body: <String, Object?>{'key': context.positional(0, 'key')},
    );

String _ocrLine(Map<Object?, Object?> job) {
  final StringBuffer out = StringBuffer('${job['key']}  ${job['state']}');
  if (job['pagesTotal'] != null) {
    // 远程引擎先上传再识别，两段各自从 0 数起（BUG-3605）。
    final String phase = job['phase'] == 'uploading' ? ' 上传' : '';
    out.write('$phase ${job['pagesDone']}/${job['pagesTotal']} 页');
  }
  if (job['directory'] != null) out.write('（${job['directory']}）');
  final Object? queued = job['queued'];
  if (queued is int && queued > 0) out.write('，排队 $queued 个');
  if (job['pending'] != null) out.write('，待识别 ${job['pending']} 个');
  if (job['error'] != null) out.write('\n  错误：${job['error']}');
  return out.toString();
}

String _renderOcr(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? jobs = data['jobs'];
  if (jobs is List) {
    if (jobs.isEmpty) return '（没有在跑的 OCR 任务）';
    return <String>[
      for (final Object? job in jobs)
        if (job is Map) _ocrLine(job),
    ].join('\n');
  }
  return _ocrLine(data);
}
