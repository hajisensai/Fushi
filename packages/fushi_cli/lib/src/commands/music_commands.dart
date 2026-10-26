import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli music …`：音乐库：列表 / 刮削 / 指定录音 / 歌单 / 播放（app 侧路由见 `fushi/lib/src/ops/ctl_music_routes.dart`）。
///
/// 音乐扫描根也在这里（`sources` / `source-add` / `source-rm` / `scan`）：`library`
/// 组的来源命令刻意不认 music。歌单只读（app 没有歌单编辑）。
const List<CtlCommandGroup> musicCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'music',
    summary: '音乐库：曲库 / 识别 / 歌单 / 扫描根 / 播放遥控',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'albums',
        summary: '列出 / 搜索专辑',
        usage: '[关键词...]',
        configure: _configureLimit,
        build: _buildAlbums,
        render: _renderAlbums,
      ),
      CtlCommandSpec(
        name: 'album',
        summary: '专辑详情（按碟号 / 轨号列曲目）',
        usage: '<albumUid>',
        build: _buildAlbum,
        render: _renderAlbum,
      ),
      CtlCommandSpec(
        name: 'artists',
        summary: '列出 / 搜索艺人',
        usage: '[关键词...]',
        configure: _configureLimit,
        build: _buildArtists,
        render: _renderArtists,
      ),
      CtlCommandSpec(
        name: 'tracks',
        summary: '列出 / 搜索曲目（--album / --artist 只看一张专辑 / 一位艺人）',
        usage: '[关键词...]',
        configure: _configureTracks,
        build: _buildTracks,
        render: _renderTracks,
      ),
      CtlCommandSpec(
        name: 'track',
        summary: '曲目详情：识别结论与可选的候选录音',
        usage: '<trackUid>',
        build: _buildTrack,
        render: renderMusicTrack,
      ),
      CtlCommandSpec(
        name: 'playlists',
        summary: '列出歌单（只读）',
        build: _buildPlaylists,
        render: _renderPlaylists,
      ),
      CtlCommandSpec(
        name: 'scrape',
        summary: '联网识别一首（--recording 指定 MusicBrainz 录音 id）',
        usage: '<trackUid>',
        configure: _configureScrape,
        build: _buildScrape,
        render: renderMusicTrack,
      ),
      CtlCommandSpec(
        name: 'scrape-all',
        summary: '后台识别整个曲库里还没识别的曲目（进度见 scrape-status）',
        build: _buildScrapeAll,
        render: renderMusicScrapeJob,
      ),
      CtlCommandSpec(
        name: 'scrape-status',
        summary: '整库识别的进度 / 结果',
        build: _buildScrapeStatus,
        render: renderMusicScrapeJob,
      ),
      CtlCommandSpec(
        name: 'scrape-cancel',
        summary: '停止正在跑的整库识别（已识别的保留）',
        build: _buildScrapeCancel,
        render: renderMusicScrapeJob,
      ),
      CtlCommandSpec(
        name: 'sources',
        summary: '列出音乐扫描根（文件夹）',
        build: _buildSources,
        render: _renderSources,
      ),
      CtlCommandSpec(
        name: 'source-add',
        summary: '添加音乐文件夹并扫描（与曲库页「添加文件夹」同一路径）',
        usage: '<path>',
        build: _buildSourceAdd,
        render: _renderSourceAdd,
      ),
      CtlCommandSpec(
        name: 'source-rm',
        summary: '移除音乐文件夹（曲目移出曲库，磁盘文件不动；需 --yes）',
        usage: '<id>',
        configure: _configureYes,
        build: _buildSourceRm,
      ),
      CtlCommandSpec(
        name: 'scan',
        summary: '重新扫描音乐文件夹（--source 只扫一个）',
        configure: _configureScan,
        build: _buildScan,
        render: _renderScan,
      ),
      CtlCommandSpec(
        name: 'now',
        summary: '正在播放：当前曲目、播放 / 暂停、位置、队列',
        build: _buildNow,
        render: renderMusicPlayer,
      ),
      CtlCommandSpec(
        name: 'play',
        summary: '播放：不带参数 = 续播；--album 放整张专辑；--track 依次给曲目',
        configure: _configurePlay,
        build: _buildPlay,
        render: renderMusicPlayer,
      ),
      CtlCommandSpec(
        name: 'pause',
        summary: '暂停',
        build: _buildPause,
        render: renderMusicPlayer,
      ),
      CtlCommandSpec(
        name: 'next',
        summary: '下一首',
        build: _buildNext,
        render: renderMusicPlayer,
      ),
      CtlCommandSpec(
        name: 'prev',
        summary: '上一首（放过开头几秒则回到本曲开头）',
        build: _buildPrevious,
        render: renderMusicPlayer,
      ),
      CtlCommandSpec(
        name: 'jump',
        summary: '跳到队列第 N 首（从 0 数）',
        usage: '<index>',
        build: _buildJump,
        render: renderMusicPlayer,
      ),
    ],
  ),
];

const String _root = '/api/admin/music';
const String _player = '/api/admin/music/player';

String _enc(String raw) => Uri.encodeComponent(raw.trim());

String? _search(CtlCommandContext c) {
  final String text = c.rest.join(' ').trim();
  return text.isEmpty ? null : text;
}

void _configureLimit(ArgParser parser) {
  parser.addOption('limit', help: '最多列几条');
}

Map<String, String> _listQuery(CtlCommandContext c) {
  final int? limit = c.intOption('limit');
  if (limit != null && limit <= 0) throw const CtlUsageError('--limit 必须是正整数');
  return <String, String>{
    if (_search(c) != null) 'search': _search(c)!,
    if (limit != null) 'limit': '$limit',
  };
}

CtlRequestSpec _buildAlbums(CtlCommandContext c) =>
    CtlRequestSpec.get('$_root/albums', query: _listQuery(c));

CtlRequestSpec _buildAlbum(CtlCommandContext c) =>
    CtlRequestSpec.get('$_root/albums/${_enc(c.positional(0, 'albumUid'))}');

CtlRequestSpec _buildArtists(CtlCommandContext c) =>
    CtlRequestSpec.get('$_root/artists', query: _listQuery(c));

void _configureTracks(ArgParser parser) {
  parser
    ..addOption('album', help: '只看这张专辑（albumUid）')
    ..addOption('artist', help: '只看这位艺人（artistUid）')
    ..addOption('limit', help: '最多列几条');
}

CtlRequestSpec _buildTracks(CtlCommandContext c) => CtlRequestSpec.get(
  '$_root/tracks',
  query: <String, String>{
    ..._listQuery(c),
    if (c.option('album') != null) 'album': c.option('album')!,
    if (c.option('artist') != null) 'artist': c.option('artist')!,
  },
);

CtlRequestSpec _buildTrack(CtlCommandContext c) =>
    CtlRequestSpec.get('$_root/tracks/${_enc(c.positional(0, 'trackUid'))}');

CtlRequestSpec _buildPlaylists(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/playlists');

final RegExp _mbid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void _configureScrape(ArgParser parser) {
  parser.addOption(
    'recording',
    help: '手动指定 MusicBrainz 录音 id（track 列出的候选，或自己查到的）',
  );
}

CtlRequestSpec _buildScrape(CtlCommandContext c) {
  final String uid = c.positional(0, 'trackUid');
  final String? recording = c.option('recording')?.toLowerCase();
  if (recording != null && !_mbid.hasMatch(recording)) {
    throw CtlUsageError('--recording 不是 MusicBrainz 录音 id：$recording');
  }
  return CtlRequestSpec.post(
    '$_root/tracks/${_enc(uid)}/scrape',
    body: <String, Object?>{'recordingId': ?recording},
  );
}

CtlRequestSpec _buildScrapeAll(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_root/scrape');

CtlRequestSpec _buildScrapeStatus(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/scrape');

CtlRequestSpec _buildScrapeCancel(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_root/scrape/cancel');

CtlRequestSpec _buildSources(CtlCommandContext c) =>
    const CtlRequestSpec.get('$_root/sources');

CtlRequestSpec _buildSourceAdd(CtlCommandContext c) => CtlRequestSpec.post(
  '$_root/sources',
  body: <String, Object?>{'path': ctlAbsolutePath(c.positional(0, 'path'))},
);

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认移除（必需）');
}

CtlRequestSpec _buildSourceRm(CtlCommandContext c) {
  final String raw = c.positional(0, 'id');
  if (!RegExp(r'^[1-9]\d*$').hasMatch(raw)) {
    throw CtlUsageError('扫描根 id 必须是正整数：$raw');
  }
  if (!c.flag('yes')) throw const CtlUsageError('移除音乐文件夹请加 --yes');
  return CtlRequestSpec(
    'DELETE',
    '$_root/sources/$raw',
    body: const <String, Object?>{'confirm': true},
  );
}

void _configureScan(ArgParser parser) {
  parser.addOption('source', help: '只扫这个扫描根 id');
}

CtlRequestSpec _buildScan(CtlCommandContext c) {
  final int? source = c.intOption('source');
  return CtlRequestSpec.post(
    '$_root/scan',
    body: <String, Object?>{'source': ?source},
  );
}

CtlRequestSpec _buildNow(CtlCommandContext c) =>
    const CtlRequestSpec.get(_player);

void _configurePlay(ArgParser parser) {
  parser
    ..addOption('album', help: '放这张专辑（albumUid）')
    ..addMultiOption('track', help: '依次放这些曲目（trackUid，可重复）')
    ..addOption('index', help: '从第几首开始（从 0 数）')
    ..addFlag('shuffle', negatable: false, help: '随机播放');
}

CtlRequestSpec _buildPlay(CtlCommandContext c) {
  final String? album = c.option('album');
  final List<String> tracks = <String>[
    for (final String t in c.multiOption('track'))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (album != null && tracks.isNotEmpty) {
    throw const CtlUsageError('--album 与 --track 只能给一个');
  }
  final int? index = c.intOption('index');
  if (index != null && index < 0) throw const CtlUsageError('--index 不能为负');
  final bool target = album != null || tracks.isNotEmpty;
  if (!target && (index != null || c.flag('shuffle'))) {
    throw const CtlUsageError('--index / --shuffle 要配 --album 或 --track');
  }
  return CtlRequestSpec.post(
    '$_player/play',
    body: <String, Object?>{
      'album': ?album,
      if (tracks.isNotEmpty) 'tracks': tracks,
      'index': ?index,
      if (c.flag('shuffle')) 'shuffle': true,
    },
  );
}

CtlRequestSpec _buildPause(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_player/pause');

CtlRequestSpec _buildNext(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_player/next');

CtlRequestSpec _buildPrevious(CtlCommandContext c) =>
    const CtlRequestSpec.post('$_player/previous');

CtlRequestSpec _buildJump(CtlCommandContext c) {
  final String raw = c.positional(0, 'index');
  final int? index = int.tryParse(raw);
  if (index == null || index < 0) {
    throw CtlUsageError('<index> 必须是非负整数：$raw');
  }
  return CtlRequestSpec.post(
    '$_player/jump',
    body: <String, Object?>{'index': index},
  );
}

// ── render ──────────────────────────────────────────────────────────────

String _durationText(Object? ms) {
  if (ms is! num) return '';
  final int s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _withTotal(Object? data, String table, String key) {
  if (data is! Map) return table;
  final Object? total = data['total'];
  final Object? rows = data[key];
  if (total is int && rows is List && rows.length < total) {
    return '$table\n（共 $total 条，只列出前 ${rows.length} 条）';
  }
  return table;
}

String _renderAlbums(Object? data) => _withTotal(
  data,
  renderCtlTable(
    data,
    const <(String, String)>[
      ('uid', 'uid'),
      ('专辑', 'title'),
      ('艺人', 'artist'),
      ('曲目', 'tracks'),
    ],
    listKey: 'albums',
    empty: '没有专辑',
  ),
  'albums',
);

String _renderAlbum(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? tracks = data['tracks'];
  return '${data['title']}'
      '${data['artist'] != null ? ' · ${data['artist']}' : ''}'
      '${data['date'] != null ? ' · ${data['date']}' : ''}\n'
      '${_trackTable(tracks)}';
}

String _trackTable(Object? tracks) => renderCtlTable(
  <Map<String, Object?>>[
    if (tracks is List)
      for (final Object? t in tracks)
        if (t is Map)
          <String, Object?>{
            'no': t['disc'] != null ? '${t['disc']}-${t['no'] ?? ''}' : t['no'],
            'uid': t['uid'],
            'title': t['title'],
            'artist': t['artist'],
            'album': t['album'],
            'length': _durationText(t['durationMs']),
          },
  ],
  const <(String, String)>[
    ('#', 'no'),
    ('uid', 'uid'),
    ('曲目', 'title'),
    ('艺人', 'artist'),
    ('专辑', 'album'),
    ('时长', 'length'),
  ],
  empty: '没有曲目',
);

String _renderArtists(Object? data) => _withTotal(
  data,
  renderCtlTable(
    data,
    const <(String, String)>[('uid', 'uid'), ('艺人', 'name')],
    listKey: 'artists',
    empty: '没有艺人',
  ),
  'artists',
);

String _renderTracks(Object? data) => _withTotal(
  data,
  _trackTable(data is Map ? data['tracks'] : null),
  'tracks',
);

/// 识别结论状态 → 一句话。
String describeMusicIdentification(Object? status) => switch (status) {
  'matched' => '已识别',
  'unmatched' => '没找到匹配',
  'error' => '识别失败（资料源连不上）',
  'none' => '还没识别',
  _ => '$status',
};

/// `track` / `scrape` 的输出：曲目 + 识别结论 + 候选录音。
String renderMusicTrack(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer();
  if (data['title'] != null) {
    out.writeln(
      '${data['title']}'
      '${data['artist'] != null ? ' · ${data['artist']}' : ''}'
      '${data['album'] != null ? ' · ${data['album']}' : ''}',
    );
  } else {
    out.writeln('${data['uid']}');
  }
  final Object? id = data['identification'];
  if (id is Map) {
    out.write('识别：${describeMusicIdentification(id['status'])}');
    if (id['recordingId'] != null) out.write('（录音 ${id['recordingId']}）');
    if (id['method'] != null) out.write(' · 方式 ${id['method']}');
    if (id['confidence'] is num) {
      out.write(' · 置信度 ${((id['confidence'] as num) * 100).round()}%');
    }
    out.writeln();
    if (id['title'] != null) {
      out.writeln(
        '  → ${id['title']}'
        '${id['artist'] != null ? ' · ${id['artist']}' : ''}'
        '${id['album'] != null ? ' · ${id['album']}' : ''}',
      );
    }
    final Object? candidates = id['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      out
        ..writeln('候选（music scrape <uid> --recording <录音 id> 手动指定）：')
        ..writeln(
          renderCtlTable(candidates, const <(String, String)>[
            ('录音 id', 'recordingId'),
            ('标题', 'title'),
            ('艺人', 'artist'),
            ('发行', 'release'),
            ('日期', 'date'),
          ]),
        );
    }
  }
  if (data['error'] != null) out.writeln('错误：${data['error']}');
  return out.toString().trimRight();
}

String _renderPlaylists(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[('uid', 'uid'), ('歌单', 'name'), ('智能', 'smart')],
  listKey: 'playlists',
  empty: '没有歌单',
);

/// 整库识别任务 → 一句话。
String renderMusicScrapeJob(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['id'] == null) return '还没有跑过整库识别';
  final String status = switch (data['status']) {
    'running' => data['cancelRequested'] == true ? '正在停止' : '识别中',
    'done' => '已完成',
    'cancelled' => '已取消',
    'failed' => '失败',
    _ => '${data['status']}',
  };
  final StringBuffer out = StringBuffer(
    '整库识别 ${data['id']} · $status · ${data['done']}/${data['total']}',
  );
  final Object? report = data['report'];
  if (report is Map) {
    out.write(
      '\n识别 ${report['matched']} · 没找到 ${report['unmatched']} · '
      '失败 ${report['failed']}（共 ${report['total']}）',
    );
  }
  if (data['error'] != null) out.write('\n错误：${data['error']}');
  return out.toString();
}

String _renderSources(Object? data) => renderCtlTable(
  data,
  const <(String, String)>[
    ('id', 'id'),
    ('名称', 'label'),
    ('路径', 'path'),
    ('扫描错误', 'lastScanError'),
  ],
  listKey: 'sources',
  empty: '还没有音乐文件夹（music source-add <path>）',
);

String _renderSourceAdd(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['added'] != true) return '这个文件夹已经在曲库里：${data['path']}';
  return '已添加音乐文件夹 #${data['id']}：${data['path']}（曲库现有 ${data['tracks']} 首）';
}

String _renderScan(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String table = renderCtlTable(
    data,
    const <(String, String)>[
      ('id', 'id'),
      ('路径', 'path'),
      ('成功', 'ok'),
      ('错误', 'error'),
    ],
    listKey: 'results',
    empty: '没有音乐文件夹',
  );
  return '$table\n曲库现有 ${data['tracks']} 首';
}

/// 播放器状态 → 人话。
String renderMusicPlayer(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  if (data['active'] != true) return '没有在放音乐';
  final Object? track = data['track'];
  final String title = track is Map
      ? '${track['title']}'
            '${track['artist'] != null ? ' · ${track['artist']}' : ''}'
      : '';
  final Object? queue = data['queue'];
  final int count = queue is List ? queue.length : 0;
  final Object? index = data['index'];
  final String position = _durationText(data['positionMs']);
  final String duration = _durationText(data['durationMs']);
  return '${data['playing'] == true ? '▶ 播放中' : '⏸ 已暂停'}：$title\n'
      '${position.isEmpty ? '' : '$position${duration.isEmpty ? '' : ' / $duration'} · '}'
      '队列 ${index is int ? index + 1 : '?'}/$count';
}
