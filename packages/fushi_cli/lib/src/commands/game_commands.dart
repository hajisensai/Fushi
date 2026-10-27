import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';

/// game 域命令（Galgame Hook，仅 Windows；app 侧路由见
/// `fushi/lib/src/ops/ctl_game_routes.dart`）：启动 / 附着 / 停止
/// 捕获、文本线程与当前台词、对当前台词制卡、逐级能力阶段。
const List<CtlCommandGroup> gameCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'game',
    summary: 'Galgame Hook（Windows）：启动 / 附着捕获、文本线程、台词制卡、能力阶段',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出游戏库（id 用于 game launch）',
        build: _buildLs,
        render: _renderLs,
      ),
      CtlCommandSpec(
        name: 'launch',
        summary: '经 Hook 会话启动游戏并等待启动结果（含各能力阶段）',
        usage: '<gameId|game:<id>>',
        configure: _configureLaunch,
        build: _buildLaunch,
        render: _renderLaunch,
      ),
      CtlCommandSpec(
        name: 'windows',
        summary: '列出可附着的顶层窗口（hwnd / pid）',
        build: _buildWindows,
        render: _renderWindows,
      ),
      CtlCommandSpec(
        name: 'attach',
        summary: '附着捕获到已在运行的游戏窗口（--hwnd 或 --pid）',
        configure: _configureAttach,
        build: _buildAttach,
        render: _renderAttach,
      ),
      CtlCommandSpec(
        name: 'stop',
        summary: '停止捕获（结算本局游玩时长）',
        configure: _configureStop,
        build: _buildStop,
        render: _renderStop,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '会话状态、逐级能力阶段与最近事件',
        configure: _configureStatus,
        build: _buildStatus,
        render: _renderStatus,
      ),
      CtlCommandSpec(
        name: 'threads',
        summary: '列出本会话的文本线程（key 用于 game select）',
        build: _buildThreads,
        render: _renderThreads,
      ),
      CtlCommandSpec(
        name: 'select',
        summary: '选择文本线程（写入本游戏记忆）；--clear 取消选择',
        usage: '<threadKey>',
        configure: _configureSelect,
        build: _buildSelect,
        render: _renderSelect,
      ),
      CtlCommandSpec(
        name: 'text',
        summary: '读当前台词（--limit 看最近多行）',
        configure: _configureText,
        build: _buildText,
        render: _renderText,
      ),
      CtlCommandSpec(
        name: 'mine',
        summary: '对当前台词（或 --line 指定行）里的一个词制卡（画面 + 句音走游戏制卡链路）',
        usage: '<词>',
        configure: _configureMine,
        build: _buildMine,
        render: _renderMine,
      ),
      // ── 工作台细项 ─────────────────────────────────────────────────────
      CtlCommandSpec(
        name: 'config',
        summary: '每游戏启动期配置：转区 / 窗口超分 / 内容语言（下次启动生效）',
        usage: '<gameId>',
        configure: _configureConfig,
        build: _buildConfig,
        render: _renderConfig,
      ),
      CtlCommandSpec(
        name: 'bind',
        summary: '绑定游戏窗口（外部窗口模式开着时会随即附着捕获）；--clear 解绑',
        configure: _configureBind,
        build: _buildBind,
        render: _renderBind,
      ),
      CtlCommandSpec(
        name: 'window-mode',
        summary: '外部窗口模式开关（on | off）',
        usage: '<on|off>',
        build: _buildWindowMode,
        render: _renderWindowMode,
      ),
      CtlCommandSpec(
        name: 'tracks',
        summary: '会话音轨列表（ptr 用于 track-select / track-exclude / track-preview）',
        configure: _configureTracks,
        build: _buildTracks,
        render: _renderTracks,
      ),
      CtlCommandSpec(
        name: 'track-select',
        summary: '会话级选定语音轨（只在引擎 PCM 是当前音源时影响取音）',
        usage: '<ptr>',
        build: _buildTrackSelect,
        render: _renderTrackSelect,
      ),
      CtlCommandSpec(
        name: 'track-exclude',
        summary: '把音轨标为排除（BGM / 音效）；--include 取消排除',
        usage: '<ptr>',
        configure: _configureTrackExclude,
        build: _buildTrackExclude,
        render: _renderTrackExclude,
      ),
      CtlCommandSpec(
        name: 'track-preview',
        summary: '试听音轨：导出 WAV 返回路径，--play 在 app 内播放；--line 用指定台词的时间点',
        usage: '<ptr>',
        configure: _configurePreview,
        build: _buildTrackPreview,
        render: _renderPreview,
      ),
      CtlCommandSpec(
        name: 'audio-stop',
        summary: '停止 app 内的试听播放',
        build: _buildAudioStop,
        render: _renderAudioStop,
      ),
      CtlCommandSpec(
        name: 'audio-policy',
        summary: '音频降级策略：full | cleanOnly | resourceOnly（按游戏记住）',
        usage: '<policy>',
        build: _buildAudioPolicy,
        render: _renderAudioPolicy,
      ),
      CtlCommandSpec(
        name: 'line-tracks',
        summary: '某句台词时刻的音轨快照与当前所用轨',
        usage: '<lineId>',
        build: _buildLineTracks,
        render: _renderTracks,
      ),
      CtlCommandSpec(
        name: 'line-track',
        summary: '为某句台词改用指定语音轨（用户裁决，按该句时间重抓整句）',
        usage: '<lineId> <ptr>',
        build: _buildLineTrack,
        render: _renderLineTrack,
      ),
      CtlCommandSpec(
        name: 'line-preview',
        summary: '试听某句已配的音频：返回文件路径，--play 在 app 内播放',
        usage: '<lineId>',
        configure: _configurePlayOnly,
        build: _buildLinePreview,
        render: _renderPreview,
      ),
      CtlCommandSpec(
        name: 'recapture',
        summary: '补录某句语音：start 后在游戏里重播，再 finish（或 discard）',
        usage: '<lineId> <start|finish|discard>',
        build: _buildRecapture,
        render: _renderRecapture,
      ),
      CtlCommandSpec(
        name: 'favorite',
        summary: '切换某句台词的收藏',
        usage: '<lineId>',
        build: _buildFavorite,
        render: _renderFavorite,
      ),
      CtlCommandSpec(
        name: 'textproc',
        summary: '查看 / 设置所选线程的文本处理管线（--set-file / --set-json，格式同输出）',
        configure: _configureTextProc,
        build: _buildTextProc,
        render: _renderTextProc,
      ),
      CtlCommandSpec(
        name: 'events-clear',
        summary: '清空会话事件记录（诊断页「清空」）',
        build: _buildEventsClear,
        render: _renderEventsClear,
      ),
      CtlCommandSpec(
        name: 'lookup-mode',
        summary: '内嵌查词表面模式：auto | nativeOnly | attachedOnly | off（不给参数 = 查看）',
        usage: '[mode]',
        build: _buildLookupMode,
        render: _renderLookupMode,
      ),
      CtlCommandSpec(
        name: 'lookup-clear',
        summary: '清除本游戏的内嵌查词校准 profile（需 --yes）',
        configure: _configureYes,
        build: _buildLookupClear,
        render: _renderLookupMode,
      ),
      // ── 游戏条目管理（游戏库页 / 详情页）──────────────────────────────
      CtlCommandSpec(
        name: 'rename',
        summary: '改游戏显示名（用户覆盖层）；--clear 回落到 exe 推导名',
        usage: '<gameId> [新名字...]',
        configure: _configureClearFlag,
        build: _buildRename,
        render: _renderGameEntry,
      ),
      CtlCommandSpec(
        name: 'play-status',
        summary:
            '游玩状态：unset | wantToPlay | playing | played | onHold | dropped',
        usage: '<gameId> <status>',
        build: _buildPlayStatus,
        render: _renderGameEntry,
      ),
      CtlCommandSpec(
        name: 'cover',
        summary: '换封面：--file <图片> 拷进封面目录，或 --auto 从游戏目录 / exe 图标取',
        usage: '<gameId>',
        configure: _configureCover,
        build: _buildCover,
        render: _renderCover,
      ),
      CtlCommandSpec(
        name: 'edit',
        summary:
            '编辑条目：exe / 工作目录 / 启动参数 / 简介 / 标签 / 开发商 / NSFW / 评分 / 评价 / 发售日',
        usage: '<gameId>',
        configure: _configureEdit,
        build: _buildEdit,
        render: _renderGameEntry,
      ),
      CtlCommandSpec(
        name: 'remove',
        summary: '从游戏库移除（不删磁盘文件，需 --yes；--delete-stats 同时删统计）',
        usage: '<gameId>',
        configure: _configureRemove,
        build: _buildRemove,
        render: _renderRemove,
      ),
      CtlCommandSpec(
        name: 'sessions',
        summary: '游玩会话流水（id 用于 session-delete）',
        usage: '<gameId>',
        configure: _configureSessions,
        build: _buildSessions,
        render: _renderSessions,
      ),
      CtlCommandSpec(
        name: 'session-delete',
        summary: '删除一条游玩会话（改变统计时长，需 --yes）',
        usage: '<gameId> <sessionId>',
        configure: _configureYes,
        build: _buildSessionDelete,
        render: _renderSessionDelete,
      ),
      CtlCommandSpec(
        name: 'scrape',
        summary: '搜游戏资料候选（Bangumi / VNDB；输入即 ID 时直接取详情）',
        usage: '<gameId>',
        configure: _configureScrape,
        build: _buildScrape,
        render: _renderScrape,
      ),
      CtlCommandSpec(
        name: 'scrape-apply',
        summary: '把一个候选（<source>:<externalId>）绑定到游戏并下载封面',
        usage: '<gameId> <candidateId>',
        build: _buildScrapeApply,
        render: _renderGameEntry,
      ),
      CtlCommandSpec(
        name: 'sources',
        summary: '列出游戏已有的资料源快照',
        usage: '<gameId>',
        build: _buildSources,
        render: _renderSources,
      ),
      CtlCommandSpec(
        name: 'source-remove',
        summary: '移除某个资料源快照（换数据源）',
        usage: '<gameId> <bgm|vndb|dlsite>',
        build: _buildSourceRemove,
        render: _renderSources,
      ),
      // ── 内嵌查词截图校准 ───────────────────────────────────────────────
      CtlCommandSpec(
        name: 'screenshot',
        summary: '截取游戏窗口校准样本（不含 Fushi 覆盖层），返回 PNG 路径与像素尺寸',
        configure: _configureScreenshot,
        build: _buildScreenshot,
        render: _renderScreenshot,
      ),
      CtlCommandSpec(
        name: 'lookup-profile',
        summary: '查看内嵌查词当前状态与已保存的校准 profile',
        build: _buildLookupProfile,
        render: _renderLookupProfile,
      ),
      CtlCommandSpec(
        name: 'lookup-calibrate',
        summary: '用显式几何写入内嵌查词校准（与截图校准「应用」同一个落库函数）',
        configure: _configureLookupCalibrate,
        build: _buildLookupCalibrate,
        render: _renderLookupCalibrate,
      ),
    ],
  ),
];

String _str(Object? v) => v == null ? '' : '$v';

// ── ls ───────────────────────────────────────────────────────────────────

CtlRequestSpec _buildLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/game/games');

String _renderLs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('标题', 'title'),
    ('运行中', 'running'),
    ('exe存在', 'exeExists'),
    ('exe', 'exePath'),
  ],
  listKey: 'games',
  empty: '游戏库是空的',
);

// ── launch ───────────────────────────────────────────────────────────────

void _configureLaunch(ArgParser parser) {
  parser.addFlag(
    'replace',
    negatable: false,
    help: '已有其它游戏的捕获会话时替换它（会结束那一局的 Hook 与计时）',
  );
}

CtlRequestSpec _buildLaunch(CtlCommandContext context) {
  String id = context.positional(0, 'gameId').trim();
  if (id.startsWith('game:')) id = id.substring('game:'.length);
  if (id.isEmpty) throw const CtlUsageError('游戏 id 为空');
  return CtlRequestSpec.post(
    '/api/admin/game/launch',
    body: <String, Object?>{
      'id': id,
      if (context.flag('replace')) 'replace': true,
    },
  );
}

/// 阶段表：每一级单独一行，绝不压成一个「成功」。
String _renderStages(Object? stages) {
  if (stages is! List || stages.isEmpty) return '';
  final List<String> lines = <String>['能力阶段：'];
  for (final Object? s in stages) {
    if (s is! Map) continue;
    final Object? evidence = s['evidence'];
    final String ev = evidence is Map && evidence.isNotEmpty
        ? '  ${evidence.entries.map((MapEntry<Object?, Object?> e) => '${e.key}=${e.value}').join(' ')}'
        : '';
    final String note = s['note'] == null ? '' : '  （${s['note']}）';
    lines.add('  ${_str(s['stage']).padRight(20)}${_str(s['status'])}$ev$note');
  }
  return lines.join('\n');
}

String _renderSessionLine(Object? session) {
  if (session is! Map) return '';
  final Object? window = session['window'];
  return '会话：${session['phase']}'
      '${session['mode'] == null ? '' : ' · ${session['mode']}'}'
      '${session['pid'] == null ? '' : ' · pid ${session['pid']}'}'
      '${window is Map ? ' · 窗口「${window['title']}」' : ''}'
      ' · 音频 ${session['audioBackend']}'
      '${session['injectorFailure'] == 'none' ? '' : ' · 注入失败 ${session['injectorFailure']}'}'
      '${session['injectorDetail'] == null ? '' : '（${session['injectorDetail']}）'}'
      '${session['lastError'] == null ? '' : '\n错误：${session['lastError']}'}';
}

String _renderLaunch(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String head = switch (data['outcome']) {
    'running' => '已启动：${data['title']}（注入成功、窗口已绑定）',
    'degradedLoopback' => '已启动：${data['title']}，但引擎注入失败，只有整机混音兜底',
    'windowMissing' => '游戏进程已拉起，但窗口始终没出现：${data['title']}',
    'superseded' => '本次启动已被更新的会话操作取代',
    'preflight_failed' => '未启动：${data['message']}',
    _ =>
      '启动失败：${data['title']}${data['reason'] == null ? '' : '（${data['reason']}）'}',
  };
  final Object? diagnostics = data['diagnostics'];
  return <String>[
    head,
    if (diagnostics is Map)
      '诊断：${diagnostics['failure']} exit=${diagnostics['exitCode']}'
          '${_str(diagnostics['stderrTail']).isEmpty ? '' : '\n${diagnostics['stderrTail']}'}',
    if (data['session'] != null) _renderSessionLine(data['session']),
    _renderStages(data['stages']),
  ].where((String s) => s.isNotEmpty).join('\n');
}

// ── windows / attach / stop ──────────────────────────────────────────────

CtlRequestSpec _buildWindows(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/game/windows');

String _renderWindows(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('hwnd', 'hwnd'),
    ('pid', 'pid'),
    ('当前游戏', 'currentGame'),
    ('已绑定', 'bound'),
    ('标题', 'title'),
  ],
  listKey: 'windows',
  empty: '没有可捕获的窗口',
);

void _configureAttach(ArgParser parser) {
  parser
    ..addOption('hwnd', help: '窗口句柄（见 game windows）')
    ..addOption('pid', help: '进程 id（该进程只有一个顶层窗口时可用）');
}

CtlRequestSpec _buildAttach(CtlCommandContext context) {
  final int? hwnd = context.intOption('hwnd');
  final int? pid = context.intOption('pid');
  if ((hwnd == null) == (pid == null)) {
    throw const CtlUsageError('--hwnd 与 --pid 二选一');
  }
  if ((hwnd ?? pid!) <= 0) throw const CtlUsageError('句柄 / pid 必须为正整数');
  return CtlRequestSpec.post(
    '/api/admin/game/attach',
    body: <String, Object?>{'hwnd': ?hwnd, 'pid': ?pid},
  );
}

String _renderAttach(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? window = data['window'];
  final String title = window is Map ? '「${window['title']}」' : '';
  return <String>[
    data['alreadyAttached'] == true
        ? '已在捕获$title，未重启会话'
        : data['ok'] == true
        ? '已附着$title'
        : '附着未成功$title',
    _renderSessionLine(data['session']),
    _renderStages(data['stages']),
  ].where((String s) => s.isNotEmpty).join('\n');
}

void _configureStop(ArgParser parser) {
  parser.addFlag('unbind', negatable: false, help: '同时解除窗口绑定');
}

CtlRequestSpec _buildStop(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/game/stop',
  body: <String, Object?>{if (context.flag('unbind')) 'unbind': true},
);

String _renderStop(Object? data) {
  if (data is! Map) return '已停止';
  if (data['wasActive'] != true) return '本来就没有进行中的捕获';
  return data['ok'] == true
      ? '已停止捕获'
      : '已请求停止，但会话仍在：${_renderSessionLine(data['session'])}';
}

// ── status ───────────────────────────────────────────────────────────────

void _configureStatus(ArgParser parser) {
  parser.addOption('events', help: '附带最近多少条会话事件（缺省 20，0 = 不要）');
}

CtlRequestSpec _buildStatus(CtlCommandContext context) {
  final int? events = context.intOption('events');
  if (events != null && events < 0) throw const CtlUsageError('--events 不能为负');
  return CtlRequestSpec.get(
    '/api/admin/game/status',
    query: <String, String>{if (events != null) 'events': '$events'},
  );
}

String _renderStatus(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? events = data['events'];
  return <String>[
    _renderSessionLine(data['session']),
    _renderStages(data['stages']),
    if (events is List && events.isNotEmpty)
      '最近事件：\n${renderCtlTable(events, const <(String, String)>[('时间', 'at'), ('级别', 'severity'), ('阶段', 'stage'), ('代码', 'code'), ('摘要', 'summary')])}',
  ].where((String s) => s.isNotEmpty).join('\n');
}

// ── threads / select ─────────────────────────────────────────────────────

CtlRequestSpec _buildThreads(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/game/threads');

String _renderThreads(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('key', 'key'),
    ('选中', 'selected'),
    ('名称', 'label'),
    ('行数', 'observedLines'),
    ('伪影', 'observedArtifacts'),
    ('有音频', 'audioLines'),
    ('预览', 'preview'),
  ],
  listKey: 'threads',
  empty: '本会话还没有文本线程（先 game launch / game attach，并让游戏出几句台词）',
);

void _configureSelect(ArgParser parser) {
  parser.addFlag('clear', negatable: false, help: '取消线程选择');
}

CtlRequestSpec _buildSelect(CtlCommandContext context) {
  final bool clear = context.flag('clear');
  final String? key = context.optionalPositional(0);
  if (clear == (key != null)) {
    throw const CtlUsageError('<threadKey> 与 --clear 二选一');
  }
  return CtlRequestSpec.post(
    '/api/admin/game/threads/select',
    body: <String, Object?>{'key': ?key, if (clear) 'clear': true},
  );
}

String _renderSelect(Object? data) {
  if (data is! Map) return '完成';
  final Object? thread = data['thread'];
  return thread is Map
      ? '已选择线程 ${thread['key']}「${thread['label']}」'
      : '已取消线程选择';
}

// ── text ─────────────────────────────────────────────────────────────────

void _configureText(ArgParser parser) {
  parser.addOption('limit', help: '最近多少行（缺省 1 = 只要当前台词）');
}

CtlRequestSpec _buildText(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  if (limit != null && limit < 1) throw const CtlUsageError('--limit 至少为 1');
  return CtlRequestSpec.get(
    '/api/admin/game/text',
    query: <String, String>{if (limit != null) 'limit': '$limit'},
  );
}

String _renderText(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? lines = data['lines'];
  if (lines is! List || lines.isEmpty) {
    return _str(data['hint']).isEmpty ? '（没有台词）' : _str(data['hint']);
  }
  if (lines.length == 1 && lines.single is Map) {
    final Map<Object?, Object?> line = lines.single as Map<Object?, Object?>;
    return '${line['text']}\n'
        '（${line['id']} · 音频 ${line['audioStatus']}'
        '${line['audioBackend'] == null ? '' : '/${line['audioBackend']}'}）';
  }
  return renderCtlTable(lines, const <(String, String)>[
    ('id', 'id'),
    ('音频', 'audioStatus'),
    ('台词', 'text'),
  ]);
}

// ── mine ─────────────────────────────────────────────────────────────────

void _configureMine(ArgParser parser) {
  parser
    ..addOption('line', help: '台词 id（见 game text；缺省当前台词）')
    ..addOption('reading', help: '读音（缺省查词典）')
    ..addOption('glossary', help: '释义（缺省查词典）')
    ..addFlag('lookup', defaultsTo: true, help: '缺读音 / 释义时查词典补齐')
    ..addFlag('allow-duplicate', negatable: false, help: '允许重复卡')
    ..addOption('update', help: '覆盖已有笔记（note id）而不是新建');
}

CtlRequestSpec _buildMine(CtlCommandContext context) {
  final String word = context.joinedRest(0, '词');
  final int? update = context.intOption('update');
  if (update != null && update <= 0) {
    throw const CtlUsageError('--update 必须是正整数 note id');
  }
  return CtlRequestSpec.post(
    '/api/admin/game/mine',
    body: <String, Object?>{
      'word': word,
      if (context.option('line') case final String line) 'lineId': line,
      if (context.option('reading') case final String r) 'reading': r,
      if (context.option('glossary') case final String g) 'glossary': g,
      if (!context.flag('lookup')) 'lookup': false,
      if (context.flag('allow-duplicate')) 'allowDuplicate': true,
      'updateNoteId': ?update,
    },
  );
}

String _renderMine(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String head = switch (data['result']) {
    'success' =>
      '已制卡：${data['expression']}${data['noteId'] == null ? '' : '（note ${data['noteId']}）'}',
    'queued' => '已排入待发队列：${data['expression']}（Anki 暂不可达，之后补发）',
    'duplicate' => 'Anki 里已有这张卡：${data['expression']}',
    'aborted' => '未制卡：${data['failureReason'] ?? '捕获失败'}',
    _ =>
      '制卡失败（${data['result']}）：${data['errorDetail'] ?? data['failureReason'] ?? ''}',
  };
  final Object? unmapped = data['unmappedTokens'];
  return <String>[
    head,
    '台词：${data['sentence']}',
    if (data['sentenceAudioMissing'] == true) '注意：该台词没有可用的对应语音',
    if (data['audioFallbackDisabled'] == true) '注意：音频策略只认干净源，缺音频已拒绝制卡',
    if (data['staleScene'] == true) '注意：制的是历史行，画面可能与该台词不对应',
    if (data['degradedToAnimated'] == true) '注意：视频片段没做出来，退回动图',
    if (data['degradedToStill'] == true) '注意：动图没做出来，退回静图',
    if (data['glossaryFilled'] == false) '注意：释义为空（词典没查到）',
    if (unmapped is List && unmapped.isNotEmpty)
      '注意：字段映射缺 ${unmapped.join(', ')}',
  ].join('\n');
}

// ── 工作台细项 ───────────────────────────────────────────────────────────

/// 路径段编码（台词 id / 游戏 id 可能含任意字符）。
String _seg(String raw) => Uri.encodeComponent(raw);

int _ptrArg(CtlCommandContext context, int index) {
  final String raw = context.positional(index, 'ptr');
  final int? ptr = int.tryParse(raw);
  if (ptr == null || ptr <= 0) {
    throw CtlUsageError('音轨 ptr 必须是正整数（见 game tracks）：$raw');
  }
  return ptr;
}

String _gameIdArg(CtlCommandContext context) {
  String id = context.positional(0, 'gameId').trim();
  if (id.startsWith('game:')) id = id.substring('game:'.length);
  if (id.isEmpty) throw const CtlUsageError('游戏 id 为空');
  return id;
}

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认');
}

void _configurePlayOnly(ArgParser parser) {
  parser.addFlag('play', negatable: false, help: '在 app 内播放（缺省只导出并返回文件路径）');
}

void _configurePreview(ArgParser parser) {
  _configurePlayOnly(parser);
  parser.addOption('line', help: '按这句台词的时间点抓取（缺省用最近一句）');
}

// config

void _configureConfig(ArgParser parser) {
  parser
    ..addOption('locale', help: '日语区域（转区）：auto | on | off')
    ..addOption('upscaling', help: '窗口超分（Magpie）：auto | installed_only | off')
    ..addOption('language', help: '内容语言（BCP-47，如 ja）')
    ..addFlag('clear-language', negatable: false, help: '恢复未指定的内容语言');
}

CtlRequestSpec _buildConfig(CtlCommandContext context) {
  final String id = _gameIdArg(context);
  final String? locale = context.option('locale')?.toLowerCase();
  if (locale != null && !const <String>['auto', 'on', 'off'].contains(locale)) {
    throw CtlUsageError('--locale 只能是 auto | on | off：$locale');
  }
  final String? upscaling = context.option('upscaling');
  final String? language = context.option('language');
  final bool clearLanguage = context.flag('clear-language');
  if (language != null && clearLanguage) {
    throw const CtlUsageError('--language 与 --clear-language 二选一');
  }
  if (locale == null &&
      upscaling == null &&
      language == null &&
      !clearLanguage) {
    throw const CtlUsageError(
      '至少给一项：--locale / --upscaling / --language / --clear-language',
    );
  }
  return CtlRequestSpec.put(
    '/api/admin/game/games/${_seg(id)}/config',
    body: <String, Object?>{
      'locale': ?locale,
      'upscaling': ?upscaling,
      'language': ?language,
      if (clearLanguage) 'clearLanguage': true,
    },
  );
}

String _renderConfig(Object? data) => data is Map
    ? '${data['title']}：转区 ${data['locale']} · 超分 ${data['upscaling']} · '
          '语言 ${data['language'] ?? '（未指定）'}（下次启动生效）'
    : '完成';

// bind / window-mode

void _configureBind(ArgParser parser) {
  parser
    ..addOption('hwnd', help: '窗口句柄（见 game windows）')
    ..addOption('pid', help: '进程 id（该进程只有一个顶层窗口时可用）')
    ..addFlag('clear', negatable: false, help: '解除窗口绑定');
}

CtlRequestSpec _buildBind(CtlCommandContext context) {
  final int? hwnd = context.intOption('hwnd');
  final int? pid = context.intOption('pid');
  final bool clear = context.flag('clear');
  final int given =
      (hwnd == null ? 0 : 1) + (pid == null ? 0 : 1) + (clear ? 1 : 0);
  if (given != 1) throw const CtlUsageError('--hwnd / --pid / --clear 三选一');
  if ((hwnd ?? pid ?? 1) <= 0) throw const CtlUsageError('句柄 / pid 必须为正整数');
  return CtlRequestSpec.post(
    '/api/admin/game/bind',
    body: <String, Object?>{
      'hwnd': ?hwnd,
      'pid': ?pid,
      if (clear) 'clear': true,
    },
  );
}

String _renderBind(Object? data) {
  if (data is! Map) return '完成';
  if (data['unchanged'] == true) return '已经绑定在这个窗口上，未改动';
  return <String>[
    data['ok'] == true ? '绑定已更新' : '绑定未生效',
    _renderSessionLine(data['session']),
  ].where((String s) => s.isNotEmpty).join('\n');
}

CtlRequestSpec _buildWindowMode(CtlCommandContext context) {
  final String raw = context.positional(0, 'on|off').toLowerCase();
  final bool enabled = switch (raw) {
    'on' || 'true' || '1' => true,
    'off' || 'false' || '0' => false,
    _ => throw CtlUsageError('只能是 on 或 off：$raw'),
  };
  return CtlRequestSpec.put(
    '/api/admin/game/window-mode',
    body: <String, Object?>{'enabled': enabled},
  );
}

String _renderWindowMode(Object? data) => data is Map
    ? '外部窗口模式：${data['enabled'] == true ? '开' : '关'}'
          '${data['hint'] == null ? '' : '\n${data['hint']}'}'
    : '完成';

// tracks

void _configureTracks(ArgParser parser) {
  parser.addFlag(
    'refresh',
    defaultsTo: true,
    help: '先向引擎刷新一次音轨（--no-refresh 只读当前快照）',
  );
}

CtlRequestSpec _buildTracks(CtlCommandContext context) => CtlRequestSpec.get(
  '/api/admin/game/tracks',
  query: <String, String>{if (!context.flag('refresh')) 'refresh': 'false'},
);

String _renderTracks(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('ptr', 'ptr'),
      ('序', 'order'),
      ('选中', 'selected'),
      ('排除', 'excluded'),
      ('能量', 'avgEnergy'),
      ('片段', 'clips'),
      ('采样率', 'sampleRate'),
      ('声道', 'channels'),
    ],
    listKey: 'tracks',
    empty: '（没有音轨）',
  );
  if (data is! Map) return table;
  return <String>[
    table,
    if (data['backend'] != null) '音频后端：${data['backend']}',
    if (data['selectionAffectsCapture'] == false) '注意：当前后端下会话级选轨不影响制卡取音',
    if (data['emptyHint'] == 'resourceMode') '资源模式按句直提语音，没有 PCM 轨是常态',
    if (data['emptyHint'] == 'loopbackMode') '整机混音是单流，没有逐轨枚举',
    if (data['note'] != null) '${data['note']}',
    if (data.containsKey('chosen')) '本句所用轨：${data['chosen'] ?? '（自动）'}',
  ].join('\n');
}

CtlRequestSpec _buildTrackSelect(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/tracks/select',
      body: <String, Object?>{'ptr': _ptrArg(context, 0)},
    );

String _renderTrackSelect(Object? data) => data is Map
    ? '已选定音轨 ${data['selected']}'
          '${data['note'] == null ? '' : '\n${data['note']}'}'
    : '完成';

void _configureTrackExclude(ArgParser parser) {
  parser.addFlag('include', negatable: false, help: '取消排除');
}

CtlRequestSpec _buildTrackExclude(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/tracks/exclude',
      body: <String, Object?>{
        'ptr': _ptrArg(context, 0),
        'excluded': !context.flag('include'),
      },
    );

String _renderTrackExclude(Object? data) => data is Map
    ? '音轨 ${data['ptr']}：${data['excluded'] == true ? '已排除' : '未排除'}'
    : '完成';

CtlRequestSpec _buildTrackPreview(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/tracks/preview',
      body: <String, Object?>{
        'ptr': _ptrArg(context, 0),
        if (context.option('line') case final String line) 'lineId': line,
        if (context.flag('play')) 'play': true,
      },
    );

String _renderPreview(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    '试听文件：${data['filePath']}（${data['durationMs']} ms）',
    if (data['played'] == true) '已在 app 内播放（game audio-stop 停止）',
    if (data['message'] != null) '${data['message']}',
  ].join('\n');
}

CtlRequestSpec _buildAudioStop(CtlCommandContext context) =>
    const CtlRequestSpec.post('/api/admin/game/audio/stop');

String _renderAudioStop(Object? data) => '已停止试听播放';

CtlRequestSpec _buildAudioPolicy(CtlCommandContext context) {
  final String raw = context.positional(0, 'policy');
  if (!const <String>[
    'full',
    'cleanonly',
    'resourceonly',
  ].contains(raw.toLowerCase())) {
    throw CtlUsageError('策略只能是 full | cleanOnly | resourceOnly：$raw');
  }
  return CtlRequestSpec.put(
    '/api/admin/game/audio-policy',
    body: <String, Object?>{'policy': raw},
  );
}

String _renderAudioPolicy(Object? data) => data is Map
    ? '音频降级策略：${data['policy']}'
          '（引擎 PCM ${data['allowsEnginePcm'] == true ? '允许' : '禁止'} · '
          '整机混音 ${data['allowsLoopback'] == true ? '允许' : '禁止'}'
          '${data['blocksMiningWhenMissing'] == true ? ' · 缺音频拒绝制卡' : ''}）'
    : '完成';

// 逐句

CtlRequestSpec _buildLineTracks(CtlCommandContext context) =>
    CtlRequestSpec.get(
      '/api/admin/game/lines/${_seg(context.positional(0, 'lineId'))}/tracks',
    );

CtlRequestSpec _buildLineTrack(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/lines/${_seg(context.positional(0, 'lineId'))}/track',
      body: <String, Object?>{'ptr': _ptrArg(context, 1)},
    );

String _renderLineTrack(Object? data) =>
    data is Map ? '台词 ${data['lineId']} 已改用音轨 ${data['chosen']}' : '完成';

CtlRequestSpec _buildLinePreview(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/lines/${_seg(context.positional(0, 'lineId'))}/preview',
      body: <String, Object?>{if (context.flag('play')) 'play': true},
    );

CtlRequestSpec _buildRecapture(CtlCommandContext context) {
  final String id = context.positional(0, 'lineId');
  final String action = context
      .positional(1, 'start|finish|discard')
      .toLowerCase();
  if (!const <String>['start', 'finish', 'discard'].contains(action)) {
    throw CtlUsageError('动作只能是 start | finish | discard：$action');
  }
  return CtlRequestSpec.post(
    '/api/admin/game/lines/${_seg(id)}/recapture',
    body: <String, Object?>{'action': action},
  );
}

String _renderRecapture(Object? data) {
  if (data is! Map) return '完成';
  if (data['recapturing'] == true) {
    return '开始补录 ${data['lineId']}：${data['hint']}';
  }
  if (data['discarded'] == true) return '已放弃补录 ${data['lineId']}';
  final Object? line = data['line'];
  return data['ok'] == true
      ? '补录完成 ${data['lineId']}'
            '${line is Map ? '（音频 ${line['audioStatus']}）' : ''}'
      : '补录收束了，但没取到声音（该句标为 missing）';
}

CtlRequestSpec _buildFavorite(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/game/lines/${_seg(context.positional(0, 'lineId'))}/favorite',
);

String _renderFavorite(Object? data) => data is Map
    ? '台词 ${data['lineId']}：${data['favorited'] == true ? '已收藏' : '已取消收藏'}'
    : '完成';

// textproc

void _configureTextProc(ArgParser parser) {
  parser
    ..addOption('set-file', help: '从 JSON 文件读入步骤数组并保存')
    ..addOption('set-json', help: '直接给 JSON 步骤数组并保存（[] = 清空）');
}

CtlRequestSpec _buildTextProc(CtlCommandContext context) {
  final String? file = context.option('set-file');
  final String? json = context.option('set-json');
  if (file != null && json != null) {
    throw const CtlUsageError('--set-file 与 --set-json 二选一');
  }
  if (file == null && json == null) {
    return const CtlRequestSpec.get('/api/admin/game/textproc');
  }
  final String text;
  if (file != null) {
    try {
      text = File(ctlAbsolutePath(file)).readAsStringSync();
    } on FileSystemException catch (e) {
      throw CtlUsageError('读不了 $file：${e.message}');
    }
  } else {
    text = json!;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    throw CtlUsageError('文本处理管线不是合法 JSON：${e.message}');
  }
  if (decoded is! List) throw const CtlUsageError('文本处理管线必须是 JSON 数组');
  return CtlRequestSpec.put(
    '/api/admin/game/textproc',
    body: <String, Object?>{'pipeline': decoded},
  );
}

String _renderTextProc(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '所选线程：${data['selectedThread'] ?? '（未选）'}\n'
      '${renderCtlJson(data['pipeline'])}';
}

CtlRequestSpec _buildEventsClear(CtlCommandContext context) =>
    const CtlRequestSpec.post('/api/admin/game/events/clear');

String _renderEventsClear(Object? data) => '已清空会话事件';

// lookup

CtlRequestSpec _buildLookupMode(CtlCommandContext context) {
  final String? mode = context.optionalPositional(0);
  if (mode == null) {
    return const CtlRequestSpec.get('/api/admin/game/lookup-mode');
  }
  if (!const <String>[
    'auto',
    'nativeOnly',
    'attachedOnly',
    'off',
  ].contains(mode)) {
    throw CtlUsageError('模式只能是 auto | nativeOnly | attachedOnly | off：$mode');
  }
  return CtlRequestSpec.put(
    '/api/admin/game/lookup-mode',
    body: <String, Object?>{'mode': mode},
  );
}

CtlRequestSpec _buildLookupClear(CtlCommandContext context) {
  if (!context.flag('yes')) throw const CtlUsageError('清除校准需要 --yes 确认');
  return const CtlRequestSpec.post(
    '/api/admin/game/lookup-profile/clear',
    body: <String, Object?>{'confirm': true},
  );
}

String _renderLookupMode(Object? data) => data is Map
    ? '内嵌查词：${data['mode']}'
          '${data['hasProfile'] == true ? '' : '（无校准 profile）'}'
          '${data['executable'] == null ? '' : ' · ${data['executable']}'}'
    : '完成';

// ── 游戏条目管理 ─────────────────────────────────────────────────────────

String _gamePath(CtlCommandContext context, [String suffix = '']) =>
    '/api/admin/game/games/${_seg(_gameIdArg(context))}$suffix';

void _configureClearFlag(ArgParser parser) {
  parser.addFlag('clear', negatable: false, help: '清除用户覆盖');
}

String _renderGameEntry(Object? data) {
  if (data is! Map) return '完成';
  return <String>[
    '${data['title']}（${data['id']}）· 状态 ${data['playStatus']}',
    'exe：${data['exePath']}${data['exeExists'] == false ? '（不存在）' : ''}',
    if (_str(data['launchArgs']).isNotEmpty) '启动参数：${data['launchArgs']}',
    if (data['releaseDate'] != null) '发售日：${data['releaseDate']}',
    if (data['tags'] is List) '标签：${(data['tags'] as List).join(', ')}',
    if (data['rating'] != null) '评分：${data['rating']}',
    if (data['warning'] != null) '注意：${data['warning']}',
  ].join('\n');
}

CtlRequestSpec _buildRename(CtlCommandContext context) {
  final bool clear = context.flag('clear');
  final String name = context.rest.skip(1).join(' ').trim();
  if (clear == name.isNotEmpty) {
    throw const CtlUsageError('<新名字> 与 --clear 二选一');
  }
  return CtlRequestSpec.put(
    _gamePath(context, '/name'),
    body: <String, Object?>{if (clear) 'clear': true else 'name': name},
  );
}

const List<String> _playStatuses = <String>[
  'unset',
  'wantToPlay',
  'playing',
  'played',
  'onHold',
  'dropped',
];

CtlRequestSpec _buildPlayStatus(CtlCommandContext context) {
  final String raw = context.positional(1, 'status');
  final String? status = _playStatuses
      .where((String s) => s.toLowerCase() == raw.toLowerCase())
      .firstOrNull;
  if (status == null) {
    throw CtlUsageError('状态只能是 ${_playStatuses.join(' | ')}：$raw');
  }
  return CtlRequestSpec.put(
    _gamePath(context, '/play-status'),
    body: <String, Object?>{'status': status},
  );
}

void _configureCover(ArgParser parser) {
  parser
    ..addOption('file', help: '本地图片路径')
    ..addFlag('auto', negatable: false, help: '自动：游戏目录封面图 → exe 图标');
}

CtlRequestSpec _buildCover(CtlCommandContext context) {
  final String? file = context.option('file');
  final bool auto = context.flag('auto');
  if (auto == (file != null)) throw const CtlUsageError('--file 与 --auto 二选一');
  return CtlRequestSpec.post(
    _gamePath(context, '/cover'),
    body: <String, Object?>{
      if (file != null) 'file': ctlAbsolutePath(file),
      if (auto) 'auto': true,
    },
  );
}

String _renderCover(Object? data) {
  if (data is! Map) return '完成';
  return data['ok'] == true
      ? '封面已更新：${data['coverPath']}'
      : '没换封面：${data['message'] ?? ''}';
}

const List<String> _editClearable = <String>[
  'launchArgs',
  'summary',
  'tags',
  'developer',
  'nsfw',
  'rating',
  'review',
  'releaseDate',
];

void _configureEdit(ArgParser parser) {
  parser
    ..addOption('exe', help: '游戏 exe 路径')
    ..addOption('workdir', help: '工作目录')
    ..addOption('args', help: '启动参数（整行，按 Windows 规则拆分）')
    ..addOption('summary', help: '简介')
    ..addOption('tags', help: '标签（逗号分隔）')
    ..addOption('developer', help: '开发商')
    ..addFlag('nsfw', help: '标记 / 取消 NSFW（不给 = 不改）')
    ..addOption('rating', help: '我的评分 0–10')
    ..addOption('review', help: '我的评价')
    ..addOption('release-date', help: '发售日 YYYY-MM-DD')
    ..addMultiOption('clear', help: '清空某项（可重复）：${_editClearable.join(' | ')}');
}

CtlRequestSpec _buildEdit(CtlCommandContext context) {
  final List<String> clear = context.multiOption('clear');
  for (final String f in clear) {
    if (!_editClearable.contains(f)) {
      throw CtlUsageError('--clear 不认识 $f（可选 ${_editClearable.join(' | ')}）');
    }
  }
  final String? rating = context.option('rating');
  if (rating != null) {
    final double? v = double.tryParse(rating);
    if (v == null || v < 0 || v > 10) {
      throw CtlUsageError('--rating 必须是 0–10 的数字：$rating');
    }
  }
  final String? release = context.option('release-date');
  if (release != null && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(release)) {
    throw CtlUsageError('--release-date 必须是 YYYY-MM-DD：$release');
  }
  final Map<String, Object?> body = <String, Object?>{
    if (context.option('exe') case final String exe)
      'exePath': ctlAbsolutePath(exe),
    if (context.option('workdir') case final String dir)
      'workdir': ctlAbsolutePath(dir),
    if (context.option('args') case final String args) 'launchArgs': args,
    if (context.option('summary') case final String s) 'summary': s,
    if (context.option('tags') case final String t) 'tags': t,
    if (context.option('developer') case final String d) 'developer': d,
    'nsfw': ?context.explicitFlag('nsfw'),
    'rating': ?rating,
    if (context.option('review') case final String r) 'review': r,
    'releaseDate': ?release,
    if (clear.isNotEmpty) 'clear': clear,
  };
  if (body.isEmpty) throw const CtlUsageError('没有要修改的字段');
  return CtlRequestSpec.put(_gamePath(context, '/details'), body: body);
}

void _configureRemove(ArgParser parser) {
  _configureYes(parser);
  parser.addFlag('delete-stats', negatable: false, help: '同时删除这款游戏的统计数据');
}

CtlRequestSpec _buildRemove(CtlCommandContext context) {
  if (!context.flag('yes')) {
    throw const CtlUsageError('从库移除需要 --yes 确认（不会删磁盘上的游戏文件）');
  }
  return CtlRequestSpec.delete(
    _gamePath(context),
    query: <String, String>{
      'confirm': 'true',
      if (context.flag('delete-stats')) 'deleteStatistics': 'true',
    },
  );
}

String _renderRemove(Object? data) {
  if (data is! Map) return '已移除';
  return <String>[
    '已从游戏库移除：${data['title']}（磁盘文件未动）',
    if (data['statisticsDeleted'] == true) '统计数据已删除',
    if (data['statisticsError'] != null) '统计删除失败：${data['statisticsError']}',
  ].join('\n');
}

void _configureSessions(ArgParser parser) {
  parser
    ..addOption('limit', help: '条数（缺省 50）')
    ..addOption('offset', help: '跳过条数');
}

CtlRequestSpec _buildSessions(CtlCommandContext context) {
  final int? limit = context.intOption('limit');
  final int? offset = context.intOption('offset');
  if (limit != null && limit < 1) throw const CtlUsageError('--limit 至少为 1');
  if (offset != null && offset < 0) throw const CtlUsageError('--offset 不能为负');
  return CtlRequestSpec.get(
    _gamePath(context, '/sessions'),
    query: <String, String>{
      if (limit != null) 'limit': '$limit',
      if (offset != null) 'offset': '$offset',
    },
  );
}

String _renderSessions(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('日期', 'dateKey'),
      ('秒数', 'durationSeconds'),
      ('开始(ms)', 'startMs'),
      ('结束(ms)', 'endMs'),
    ],
    listKey: 'sessions',
    empty: '还没有游玩会话',
  );
  if (data is! Map) return table;
  return '${data['title']} · 总时长 ${data['totalPlaySeconds']} 秒 · '
      '${data['sessionCount']} 次\n$table';
}

CtlRequestSpec _buildSessionDelete(CtlCommandContext context) {
  final String raw = context.positional(1, 'sessionId');
  if (int.tryParse(raw) == null) {
    throw CtlUsageError('sessionId 必须是整数：$raw');
  }
  if (!context.flag('yes')) {
    throw const CtlUsageError('删除游玩会话需要 --yes 确认（会改变统计时长）');
  }
  return CtlRequestSpec.delete(
    _gamePath(context, '/sessions/${_seg(raw)}'),
    query: const <String, String>{'confirm': 'true'},
  );
}

String _renderSessionDelete(Object? data) {
  final Object? deleted = data is Map ? data['deleted'] : null;
  return deleted is Map
      ? '已删除会话 ${deleted['id']}（${deleted['dateKey']}，${deleted['durationSeconds']} 秒）'
      : '已删除';
}

/// app 侧 `GalgameMetadataSource` 的持久化键（CLI 不依赖引擎包，只能镜像一份）。
const Set<String> _metadataSources = <String>{'bgm', 'vndb', 'dlsite'};

void _configureScrape(ArgParser parser) {
  parser
    ..addOption('query', abbr: 'q', help: '搜索词或资料源 ID（缺省用游戏显示名）')
    ..addOption('source', help: '只查一个资料源：bgm | vndb | dlsite');
}

CtlRequestSpec _buildScrape(CtlCommandContext context) {
  final String? source = context.option('source')?.toLowerCase();
  if (source != null && !_metadataSources.contains(source)) {
    throw CtlUsageError('--source 只能是 bgm | vndb | dlsite：$source');
  }
  return CtlRequestSpec.get(
    _gamePath(context, '/scrape'),
    query: <String, String>{
      if (context.option('query') case final String q) 'q': q,
      'source': ?source,
    },
  );
}

String _renderScrape(Object? data) {
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('中文名', 'nameCn'),
      ('发售', 'releaseDate'),
    ],
    listKey: 'candidates',
    empty: '没有候选',
  );
  if (data is! Map) return table;
  final Object? failures = data['failures'];
  return <String>[
    '搜索「${data['query']}」',
    table,
    if (failures is Map)
      for (final MapEntry<Object?, Object?> f in failures.entries)
        '  来源失败 ${f.key}: ${f.value}',
    '（用 fushi_cli game scrape-apply ${data['id']} <候选 id> 绑定）',
  ].join('\n');
}

CtlRequestSpec _buildScrapeApply(CtlCommandContext context) {
  final String candidate = context.positional(1, 'candidateId');
  if (!RegExp(r'^(bgm|vndb|dlsite):.+$').hasMatch(candidate)) {
    throw CtlUsageError(
      '候选 id 应为 bgm:<id> / vndb:<id> / dlsite:<编号>：$candidate',
    );
  }
  return CtlRequestSpec.post(
    _gamePath(context, '/scrape'),
    body: <String, Object?>{'candidate': candidate},
  );
}

CtlRequestSpec _buildSources(CtlCommandContext context) =>
    CtlRequestSpec.get(_gamePath(context, '/sources'));

CtlRequestSpec _buildSourceRemove(CtlCommandContext context) {
  final String source = context.positional(1, 'bgm|vndb|dlsite').toLowerCase();
  if (!_metadataSources.contains(source)) {
    throw CtlUsageError('资料源只能是 bgm | vndb | dlsite：$source');
  }
  return CtlRequestSpec.delete(_gamePath(context, '/sources/$source'));
}

String _renderSources(Object? data) {
  if (data is! Map) return '完成';
  final Object? sources = data['sources'];
  return <String>[
    if (data['removed'] != null) '已移除 ${data['removed']}',
    '资料源：${sources is List && sources.isNotEmpty ? sources.join(', ') : '（无）'}',
  ].join('\n');
}

// ── 内嵌查词截图校准 ─────────────────────────────────────────────────────

void _configureScreenshot(ArgParser parser) {
  parser.addOption('output', abbr: 'o', help: 'PNG 保存路径（缺省写系统临时目录）');
}

CtlRequestSpec _buildScreenshot(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/game/screenshot',
      body: <String, Object?>{
        if (context.option('output') case final String out)
          'output': ctlAbsolutePath(out),
      },
    );

String _renderScreenshot(Object? data) => data is Map
    ? '截图：${data['path']}（${data['widthPx']}×${data['heightPx']} px）\n'
          '当前台词：${data['sourceText']}\n${data['hint']}'
    : '完成';

CtlRequestSpec _buildLookupProfile(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/game/lookup-profile');

String _renderLookupProfile(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? client = data['currentClient'];
  final Object? profile = data['profile'];
  final Object? variants = profile is Map ? profile['variants'] : null;
  return <String>[
    '内嵌查词：${data['status']}'
        '${data['statusReason'] == null ? '' : ' / ${data['statusReason']}'}'
        ' · 模式 ${data['mode']}',
    if (data['executable'] != null) 'exe：${data['executable']}',
    if (client is Map)
      '当前客户区：${client['widthPx']}×${client['heightPx']} @ ${client['dpi']}dpi',
    if (variants is List && variants.isNotEmpty)
      '已保存校准 ${variants.length} 组：\n${renderCtlJson(variants)}'
    else
      '还没有校准',
  ].join('\n');
}

void _configureLookupCalibrate(ArgParser parser) {
  parser
    ..addOption('rect', help: '正文框 x,y,w,h（缺省按客户区归一化 0–1；--px 时为像素）')
    ..addFlag('px', negatable: false, help: 'rect / grid / --font-size 用像素')
    ..addOption('grid', help: '字格：字距,行距,字高,列数（按客户区高度归一；--px 时为像素）')
    ..addOption('indent', help: '续行缩进（字格数，可为负）')
    ..addOption('quoted-indent', help: '引号台词的续行缩进（缺省同 --indent）')
    ..addOption('font-size', help: '字号（缺省同字高）')
    ..addFlag('quoted-only', negatable: false, help: '只对「」内的文字排版')
    ..addFlag(
      'explicit-line-breaks',
      negatable: false,
      help: '换行来自 Hook 文本里的换行符',
    )
    ..addOption(
      'layout-json',
      help: '完整版式 JSON（与 --grid 二选一，格式同 lookup-profile 输出）',
    )
    ..addOption('slot', help: '校准槽：dialogue | narration（缺省共用）')
    ..addFlag(
      'from-screenshot',
      negatable: false,
      help: '按最近一次 game screenshot 的截图坐标系投影',
    )
    ..addFlag(
      'accept-risk',
      negatable: false,
      help: '确认风险：点在内嵌查词层上的左键会被吞掉、不传给游戏（首次校准必需）',
    );
}

CtlRequestSpec _buildLookupCalibrate(CtlCommandContext context) {
  final String? rect = context.option('rect');
  if (rect == null) throw const CtlUsageError('缺少 --rect x,y,w,h');
  final List<String> parts = rect.split(',');
  if (parts.length != 4 ||
      parts.any((String s) => double.tryParse(s.trim()) == null)) {
    throw CtlUsageError('--rect 应为 4 个逗号分隔的数字：$rect');
  }
  final String? grid = context.option('grid');
  final String? layoutJson = context.option('layout-json');
  if ((grid == null) == (layoutJson == null)) {
    throw const CtlUsageError('--grid 与 --layout-json 二选一');
  }
  Object? layout;
  if (layoutJson != null) {
    try {
      layout = jsonDecode(layoutJson);
    } on FormatException catch (e) {
      throw CtlUsageError('--layout-json 不是合法 JSON：${e.message}');
    }
    if (layout is! Map) throw const CtlUsageError('--layout-json 必须是 JSON 对象');
  }
  if (grid != null) {
    final List<String> g = grid.split(',');
    if (g.length != 4 ||
        g.any((String s) => double.tryParse(s.trim()) == null)) {
      throw CtlUsageError('--grid 应为 字距,行距,字高,列数：$grid');
    }
  }
  final String? slot = context.option('slot');
  if (slot != null && slot != 'dialogue' && slot != 'narration') {
    throw CtlUsageError('--slot 只能是 dialogue | narration：$slot');
  }
  return CtlRequestSpec.post(
    '/api/admin/game/lookup-calibrate',
    body: <String, Object?>{
      'rect': rect,
      if (context.flag('px')) 'px': true,
      'grid': ?grid,
      'layout': ?layout,
      if (context.option('indent') case final String v) 'indent': v,
      if (context.option('quoted-indent') case final String v)
        'quotedIndent': v,
      if (context.option('font-size') case final String v) 'fontSize': v,
      if (context.flag('quoted-only')) 'quotedOnly': true,
      if (context.flag('explicit-line-breaks')) 'explicitLineBreaks': true,
      'slot': ?slot,
      if (context.flag('from-screenshot')) 'fromScreenshot': true,
      if (context.flag('accept-risk')) 'acceptRisk': true,
    },
  );
}

String _renderLookupCalibrate(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    data['ok'] == true
        ? '校准已写入并生效（状态 ${data['status']}）'
        : '${data['message']}',
    renderCtlJson(data['variant']),
  ].join('\n');
}
