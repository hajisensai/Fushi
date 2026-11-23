import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli music …` 里「把东西搬进 / 搬出曲库」的子命令：导入音频文件、光盘、插件、
/// 歌词导出、音频 CD 抓轨（app 侧路由见 `fushi/lib/src/ops/ctl_music_import_routes.dart`）。
/// 并进 `music` 组（`music_commands.dart`），不另立一组。
const List<CtlCommandSpec> musicImportCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'import',
    summary: '导入音频 / MV 文件进曲库（与曲库页「添加音频文件」同一口径）',
    usage: '<文件...>',
    build: _buildImport,
    render: _renderImport,
  ),
  CtlCommandSpec(
    name: 'discs',
    summary: '列出曲库里的光盘（DVD / 蓝光）',
    build: _buildDiscs,
    render: _renderDiscs,
  ),
  CtlCommandSpec(
    name: 'disc-add',
    summary: '登记光盘：盘目录 / 光驱根 / .iso，或含盘的目录（章节另用 disc-chapters 导入）',
    usage: '<路径>',
    build: _buildDiscAdd,
    render: _renderDiscAdd,
  ),
  CtlCommandSpec(
    name: 'disc-rm',
    summary: '从曲库移除一张光盘（盘上文件不动；需 --yes）',
    usage: '<discUid>',
    configure: _configureYes,
    build: _buildDiscRm,
  ),
  CtlCommandSpec(
    name: 'disc-titles',
    summary: '读盘：列出 title（时长、章节数、正片、已导入）',
    usage: '<discUid>',
    build: _buildDiscTitles,
    render: _renderDiscTitles,
  ),
  CtlCommandSpec(
    name: 'disc-chapters',
    summary: '把选中 title 的章节导入为曲目（--title 可重复；不给 = 上次的选择 / 正片）',
    usage: '<discUid>',
    configure: _configureDiscChapters,
    build: _buildDiscChapters,
    render: _renderDiscChapters,
  ),
  CtlCommandSpec(
    name: 'plugins',
    summary: '列出本机已装的音乐插件',
    build: _buildPlugins,
    render: _renderPlugins,
  ),
  CtlCommandSpec(
    name: 'plugin-inspect',
    summary: '校验插件包（.fushiplug / .zip）：清单、权限、联网域名、签名，不安装',
    usage: '<插件包>',
    build: _buildPluginInspect,
    render: _renderPluginInspect,
  ),
  CtlCommandSpec(
    name: 'plugin-install',
    summary: '安装 / 升级音乐插件（会执行插件代码：先 plugin-inspect 看清单，再加 --yes）',
    usage: '<插件包>',
    configure: _configurePluginInstall,
    build: _buildPluginInstall,
    render: _renderPluginInspect,
  ),
  CtlCommandSpec(
    name: 'plugin-enable',
    summary: '启用插件',
    usage: '<pluginId>',
    build: _buildPluginEnable,
  ),
  CtlCommandSpec(
    name: 'plugin-disable',
    summary: '停用插件',
    usage: '<pluginId>',
    build: _buildPluginDisable,
  ),
  CtlCommandSpec(
    name: 'plugin-rm',
    summary: '卸载插件（删包、插件存储与登录凭据；需 --yes）',
    usage: '<pluginId>',
    configure: _configureYes,
    build: _buildPluginRm,
  ),
  CtlCommandSpec(
    name: 'lyrics-export',
    summary: '把一首当前生效的歌词导出到音频文件旁（ttml / lrc；已存在要 --overwrite）',
    usage: '<trackUid>',
    configure: _configureLyricsExport,
    build: _buildLyricsExport,
    render: _renderLyricsExport,
  ),
  CtlCommandSpec(
    name: 'audio-cd',
    summary: '抓音频 CD 成 FLAC 并导入曲库（后台跑，进度见 audio-cd-status）',
    usage: '<光驱 / 挂载点>',
    build: _buildAudioCd,
    render: _renderAudioCd,
  ),
  CtlCommandSpec(
    name: 'audio-cd-status',
    summary: '音频 CD 抓轨的进度 / 结果',
    build: _buildAudioCdStatus,
    render: _renderAudioCd,
  ),
  CtlCommandSpec(
    name: 'audio-cd-cancel',
    summary: '停止正在跑的抓轨（已抓的轨保留，下次复用）',
    build: _buildAudioCdCancel,
    render: _renderAudioCd,
  ),
];

const String _root = '/api/admin/music';

String _enc(String raw) => Uri.encodeComponent(raw.trim());

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认（必需）');
}

CtlRequestSpec _buildImport(CtlCommandContext c) {
  if (c.rest.isEmpty) throw const CtlUsageError('缺少参数 <文件...>');
  return CtlRequestSpec.post(
    '$_root/import',
    body: <String, Object?>{
      'paths': <String>[
        for (final String path in c.rest) ctlAbsolutePath(path),
      ],
    },
  );
}

CtlRequestSpec _buildDiscs(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/discs');

CtlRequestSpec _buildDiscAdd(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/discs',
  body: <String, Object?>{'path': ctlAbsolutePath(c.positional(0, '路径'))},
);

CtlRequestSpec _buildDiscRm(CtlCommandContext c) {
  final String uid = c.positional(0, 'discUid');
  if (!c.flag('yes')) throw const CtlUsageError('从曲库移除光盘请加 --yes');
  return CtlRequestSpec(
    'DELETE',
    '$_root/discs/${_enc(uid)}',
    body: const <String, Object?>{'confirm': true},
  );
}

CtlRequestSpec _buildDiscTitles(CtlCommandContext c) => CtlRequestSpec.get(
  '$_root/discs/${_enc(c.positional(0, 'discUid'))}/titles',
);

void _configureDiscChapters(ArgParser parser) {
  parser.addMultiOption('title', help: '要导入的 title 号（disc-titles 列出的），可重复');
}

CtlRequestSpec _buildDiscChapters(CtlCommandContext c) {
  final String uid = c.positional(0, 'discUid');
  final List<String> titles = c.multiOption('title');
  for (final String title in titles) {
    if (!RegExp(r'^\d+$').hasMatch(title.trim())) {
      throw CtlUsageError('--title 必须是 title 号：$title');
    }
  }
  return CtlRequestSpec.post(
    '$_root/discs/${_enc(uid)}/chapters',
    body: <String, Object?>{
      if (titles.isNotEmpty)
        'titles': <String>[for (final String t in titles) t.trim()],
    },
  );
}

CtlRequestSpec _buildPlugins(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/plugins');

CtlRequestSpec _buildPluginInspect(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/plugins/inspect',
  body: <String, Object?>{'path': ctlAbsolutePath(c.positional(0, '插件包'))},
);

void _configurePluginInstall(ArgParser parser) {
  parser
    ..addFlag('yes', abbr: 'y', negatable: false, help: '看过清单、确认安装（必需）')
    ..addOption('digest', help: 'plugin-inspect 给出的摘要：文件在确认之后变了就拒装');
}

CtlRequestSpec _buildPluginInstall(CtlCommandContext c) {
  final String path = ctlAbsolutePath(c.positional(0, '插件包'));
  if (!c.flag('yes')) {
    throw const CtlUsageError('安装插件会执行插件代码：先 plugin-inspect 看清单，确认后加 --yes');
  }
  return CtlRequestSpec.post(
    '$_root/plugins/install',
    body: <String, Object?>{
      'path': path,
      'confirm': true,
      'digest': ?c.option('digest'),
    },
  );
}

CtlRequestSpec _buildPluginEnable(CtlCommandContext c) => CtlRequestSpec.put(
  '$_root/plugins/${_enc(c.positional(0, 'pluginId'))}/enabled',
  body: const <String, Object?>{'enabled': true},
);

CtlRequestSpec _buildPluginDisable(CtlCommandContext c) => CtlRequestSpec.put(
  '$_root/plugins/${_enc(c.positional(0, 'pluginId'))}/enabled',
  body: const <String, Object?>{'enabled': false},
);

CtlRequestSpec _buildPluginRm(CtlCommandContext c) {
  final String id = c.positional(0, 'pluginId');
  if (!c.flag('yes')) throw const CtlUsageError('卸载插件请加 --yes');
  return CtlRequestSpec(
    'DELETE',
    '$_root/plugins/${_enc(id)}',
    body: const <String, Object?>{'confirm': true},
  );
}

void _configureLyricsExport(ArgParser parser) {
  parser
    ..addOption(
      'format',
      allowed: <String>['ttml', 'lrc'],
      defaultsTo: 'ttml',
      help: 'ttml 无损；lrc 丢声部 / 和声 / 注音',
    )
    ..addFlag('overwrite', negatable: false, help: '已有同名歌词文件时覆盖');
}

CtlRequestSpec _buildLyricsExport(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/tracks/${_enc(c.positional(0, 'trackUid'))}/lyrics/export',
  body: <String, Object?>{
    'format': c.option('format') ?? 'ttml',
    if (c.flag('overwrite')) 'overwrite': true,
  },
);

CtlRequestSpec _buildAudioCd(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/audio-cd',
  body: <String, Object?>{'dir': ctlAbsolutePath(c.positional(0, '光驱 / 挂载点'))},
);

CtlRequestSpec _buildAudioCdStatus(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/audio-cd');

CtlRequestSpec _buildAudioCdCancel(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_root/audio-cd/cancel');

// ── render ──────────────────────────────────────────────────────────────

List<Object?> _list(Object? data, String key) =>
    data is Map && data[key] is List ? data[key] as List<Object?> : <Object?>[];

String _renderImport(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> imported = _list(data, 'imported');
  final List<Object?> skipped = _list(data, 'skipped');
  final List<Object?> errors = _list(data, 'errors');
  final List<Object?> rescanned = _list(data, 'rescannedSources');
  return <String>[
    '已导入 ${imported.length} 个文件'
        '${rescanned.isEmpty ? '' : '，重扫音乐文件夹 ${rescanned.join('、')}'}'
        '；曲库共 ${data['tracks']} 首',
    for (final Object? s in skipped) '  跳过：$s',
    for (final Object? e in errors) '  失败：$e',
  ].join('\n');
}

String _renderDiscs(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('uid', 'uid'),
    ('专辑', 'title'),
    ('类型', 'kind'),
    ('已导入 title', 'importedTitles'),
    ('路径', 'path'),
  ],
  listKey: 'discs',
  empty: '（曲库里没有光盘）',
);

String _renderDiscAdd(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Object?> albums = _list(data, 'albums');
  final List<Object?> failed = _list(data, 'failed');
  return <String>[
    '登记了 ${albums.length} 张（新加 ${_list(data, 'added').length} 张）',
    for (final Object? f in failed)
      if (f is Map) '  读不出：${f['path']}（${f['error']}）',
  ].join('\n');
}

String _renderDiscTitles(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '${data['name']}（${data['kind']}）\n'
      '${renderCtlTable(data, const <(String, String)>[('title', 'number'), ('名称', 'label'), ('时长 ms', 'durationMs'), ('章节', 'chapters'), ('正片', 'main'), ('已导入', 'imported')], listKey: 'titles')}';
}

String _renderDiscChapters(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已导入 ${data['tracks']} 首（title ${_list(data, 'titles').join('、')}）';
}

String _renderPlugins(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('名称', 'name'),
    ('版本', 'version'),
    ('启用', 'enabled'),
    ('签名', 'signer'),
    ('错误', 'error'),
  ],
  listKey: 'plugins',
  empty: '（没装插件）',
);

String _renderPluginInspect(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return <String>[
    '${data['installed'] == true ? '已安装' : '插件'}：${data['name']} '
        '${data['version']}（${data['id']}）',
    if (data['author'] != null) '作者：${data['author']}',
    '能力：${_list(data, 'capabilities').join('、')}',
    '权限：${_list(data, 'permissions').join('、')}',
    '联网域名：${_list(data, 'networkDomains').join('、')}',
    '签名：${data['signer'] ?? '（无签名）'}'
        '${data['trustedSigner'] == true ? '（可信）' : ''}',
    if (data['signerChanged'] == true) '注意：签名者与已装版本不同，安装会清掉旧插件的登录与存储',
    '摘要：${data['digest']}',
  ].join('\n');
}

String _renderLyricsExport(Object? data) =>
    data is Map ? '已导出：${data['path']}' : renderCtlJson(data);

String _renderAudioCd(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['active'] == false && data['id'] == null) return '没有抓轨任务';
  final String status = '${data['status']}';
  return switch (status) {
    'running' =>
      '抓轨中（${data['id']}）：第 ${data['track']}/${data['trackCount']} 轨'
          '${data['cancelRequested'] == true ? '，正在取消' : ''}',
    'done' => '已完成：导入 ${data['imported']} 首（${data['directory']}）',
    'cancelled' => '已取消',
    _ => '失败：${data['error']}',
  };
}
