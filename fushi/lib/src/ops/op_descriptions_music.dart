import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show opCustomUndo, opUndoStrings;

/// 音乐库：列表、刮削、手动指定录音、歌单、扫描根、播放遥控的操作描述（spec §4）。
///
/// 撤销只拼现有路由：
/// - 播放遥控（续播 / 暂停 / 上一首 / 下一首 / 跳到第 N 首 / 换队列播放）= 执行前记下
///   队列、位置与播放状态，撤销时还原（换回原队列、跳回原曲、恢复播放 / 暂停）；之后
///   队列 / 曲目 / 播放状态被手动改过 = superseded；
/// - 加扫描根 = 移除刚加的那个根（连同它扫进来的曲目，磁盘文件不动）。
///
/// irreversible：
/// - 识别单曲 / 整库：覆盖识别结论，专辑身份与封面只补空、补上的值与原值无从区分，
///   还会把音频声纹发给 AcoustID（已指派 LLM 以外的第三方）；
/// - 取消整库识别：已识别的不回滚，停下的进度也恢复不了原状；
/// - 移除扫描根：曲目软删、来源行删除（与 library 域移除来源同一形态）；
/// - 重新扫描：按磁盘现状增删曲目，没有前态可写回。
List<OpDescription> describeMusicOps(OpDescribeKit kit) {
  final OpAvailability Function() music = kit.whenModule(ModuleId.music);
  return <OpDescription>[
    ..._describeLibraryOps(music),
    ..._describeScrapeOps(kit, music),
    ..._describeSourceOps(kit, music),
    ..._describePlayerOps(kit, music),
  ];
}

const String _root = '/api/admin/music';
const String _player = '$_root/player';

const OpParam _searchParam = OpParam.string(
  'search',
  description: 'Keyword (title, artist, album; width / kana insensitive).',
);
const OpParam _limitParam = OpParam.integer(
  'limit',
  description: 'Max rows to return.',
);
const OpParam _trackUidParam = OpParam.string(
  'uid',
  description: 'Track uid from music.track.list.',
  required: true,
  inPath: true,
);

List<OpDescription> _describeLibraryOps(
  OpAvailability Function() music,
) => <OpDescription>[
  OpDescription(
    id: 'music.album.list',
    method: 'GET',
    pattern: '$_root/albums',
    summary: 'List / search albums in the music library.',
    availability: music,
    params: const <OpParam>[_searchParam, _limitParam],
  ),
  OpDescription(
    id: 'music.album.get',
    method: 'GET',
    pattern: '$_root/albums/:uid',
    summary: 'One album with its tracks in disc / track order.',
    availability: music,
    params: const <OpParam>[
      OpParam.string(
        'uid',
        description: 'Album uid from music.album.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  OpDescription(
    id: 'music.artist.list',
    method: 'GET',
    pattern: '$_root/artists',
    summary: 'List / search artists credited on library tracks.',
    availability: music,
    params: const <OpParam>[_searchParam, _limitParam],
  ),
  OpDescription(
    id: 'music.track.list',
    method: 'GET',
    pattern: '$_root/tracks',
    summary: 'List / search tracks, optionally only one album or one artist.',
    availability: music,
    params: const <OpParam>[
      _searchParam,
      OpParam.string('album', description: 'Album uid filter.'),
      OpParam.string('artist', description: 'Artist uid filter.'),
      _limitParam,
    ],
  ),
  OpDescription(
    id: 'music.track.get',
    method: 'GET',
    pattern: '$_root/tracks/:uid',
    summary:
        'One track with its identification (MusicBrainz match, method, '
        'confidence) and the candidate recordings to pick from.',
    availability: music,
    params: const <OpParam>[_trackUidParam],
  ),
  OpDescription(
    id: 'music.playlist.list',
    method: 'GET',
    pattern: '$_root/playlists',
    summary: 'List playlists (read-only; the app has no playlist editing).',
    availability: music,
  ),
];

List<OpDescription> _describeScrapeOps(
  OpDescribeKit kit,
  OpAvailability Function() music,
) => <OpDescription>[
  OpDescription(
    id: 'music.track.scrape',
    method: 'POST',
    pattern: '$_root/tracks/:uid/scrape',
    summary:
        'Identify one track online (MusicBrainz; audio fingerprint goes to '
        'AcoustID) and overwrite its identification. Give recordingId to pin '
        'a specific recording (e.g. a candidate from music.track.get).',
    risk: OpRisk.irreversible,
    availability: music,
    params: const <OpParam>[
      _trackUidParam,
      OpParam.string(
        'recordingId',
        description: 'MusicBrainz recording MBID to use instead of matching.',
      ),
    ],
  ),
  OpDescription(
    id: 'music.scrape.status',
    method: 'GET',
    pattern: '$_root/scrape',
    summary: 'Progress / result of the latest whole-library identification.',
    availability: music,
  ),
  OpDescription(
    id: 'music.scrape.start',
    method: 'POST',
    pattern: '$_root/scrape',
    summary:
        'Identify every track without a current identification, in the '
        'background (MusicBrainz 1 req/s; fingerprints go to AcoustID). '
        'Returns taskId; progress via music.scrape.status.',
    risk: OpRisk.irreversible,
    longRunning: true,
    availability: music,
    taskStatus: (String taskId) => _scrapeTaskStatus(kit, taskId),
  ),
  OpDescription(
    id: 'music.scrape.cancel',
    method: 'POST',
    pattern: '$_root/scrape/cancel',
    summary:
        'Stop the running whole-library identification after the current '
        'track (already identified tracks stay identified).',
    risk: OpRisk.irreversible,
    availability: music,
  ),
];

Future<OpTaskStatus> _scrapeTaskStatus(OpDescribeKit kit, String taskId) async {
  final Object? raw = await kit.callRoute('GET', '$_root/scrape');
  final Map<Object?, Object?> job = raw is Map
      ? raw
      : const <Object?, Object?>{};
  if (job['id'] != taskId) {
    return OpTaskStatus(
      terminal: true,
      summary: 'task $taskId is no longer tracked',
      data: raw,
    );
  }
  final String status = '${job['status']}';
  final Object? report = job['report'];
  return OpTaskStatus(
    terminal: status != 'running',
    succeeded: status == 'done',
    summary: report is Map
        ? '$status: ${report['matched']}/${report['total']} matched'
        : '$status: ${job['done']}/${job['total']}',
    data: raw,
  );
}

List<OpDescription> _describeSourceOps(
  OpDescribeKit kit,
  OpAvailability Function() music,
) => <OpDescription>[
  OpDescription(
    id: 'music.source.list',
    method: 'GET',
    pattern: '$_root/sources',
    summary: 'List music library folders (scan roots).',
    availability: music,
  ),
  OpDescription(
    id: 'music.source.add',
    method: 'POST',
    pattern: '$_root/sources',
    summary:
        'Add a local folder to the music library and scan it (like "Add '
        'folder" on the music page). Undo removes the folder and its tracks '
        '(files on disk are kept).',
    risk: OpRisk.write,
    availability: music,
    params: const <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute folder path.',
        required: true,
      ),
    ],
    undo: opCustomUndo(
      payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
          <String, Object?>{
            'added': result is Map && result['added'] == true,
            'id': result is Map ? result['id'] : null,
          },
      describe: (Map<String, Object?> p) => 'music source ${p['id']}',
      revert: (Map<String, Object?> payload) async {
        final Object? id = payload['id'];
        if (payload['added'] != true || id == null) {
          return const OpUndoOutcome.done();
        }
        await kit.callRoute(
          'DELETE',
          '$_root/sources/:id',
          params: <String, String>{'id': '$id'},
          body: const <String, Object?>{'confirm': true},
        );
        return const OpUndoOutcome.done();
      },
    ),
  ),
  OpDescription(
    id: 'music.source.remove',
    method: 'DELETE',
    pattern: '$_root/sources/:id',
    summary:
        'Remove a music library folder: its tracks leave the library (files '
        'on disk are kept).',
    risk: OpRisk.irreversible,
    availability: music,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Folder id from music.source.list.',
        required: true,
        inPath: true,
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed removing the folder.',
      ),
    ],
  ),
  OpDescription(
    id: 'music.scan',
    method: 'POST',
    pattern: '$_root/scan',
    summary:
        'Rescan music folders for new / changed / missing files (like '
        '"Rescan" on the music page).',
    risk: OpRisk.irreversible,
    availability: music,
    params: const <OpParam>[
      OpParam.integer(
        'source',
        description: 'Only this folder id (music.source.list).',
      ),
    ],
  ),
];

/// 播放器状态的比较投影：队列、当前曲、位置下标、是否在放。
Map<String, Object?> _playerState(Object? raw) {
  final Map<Object?, Object?> s = raw is Map ? raw : const <Object?, Object?>{};
  final Object? track = s['track'];
  return <String, Object?>{
    'queue': opUndoStrings(s['queue']),
    'track': track is Map ? track['uid'] : null,
    'index': s['index'],
    'playing': s['playing'] == true,
  };
}

/// 撤销载荷里已投影过的状态（JSON 往返后类型会松）→ 与 [_playerState] 同形。
Map<String, Object?> _storedState(Object? raw) {
  final Map<Object?, Object?> s = raw is Map ? raw : const <Object?, Object?>{};
  final Object? index = s['index'];
  return <String, Object?>{
    'queue': opUndoStrings(s['queue']),
    'track': s['track'],
    'index': index is num ? index.toInt() : null,
    'playing': s['playing'] == true,
  };
}

/// 播放遥控的通用撤销：执行前后各记一份 [_playerState]。撤销时当前状态不等于执行后
/// （之后手动换过歌 / 暂停过）= superseded；否则换回原队列（原来没有队列就暂停）、
/// 跳回原曲、恢复原播放状态。
OpUndo _playerUndo(OpDescribeKit kit) => opCustomUndo(
  capture: (CtlCall call) async => <String, Object?>{
    'before': _playerState(await kit.callRoute('GET', _player)),
  },
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
      <String, Object?>{
        'before': before['before'],
        'after': _playerState(result),
      },
  describe: (Map<String, Object?> p) {
    final Object? after = p['after'];
    return after is Map ? 'track ${after['track']}' : null;
  },
  revert: (Map<String, Object?> payload) async {
    final Map<String, Object?> before = _storedState(payload['before']);
    final Map<String, Object?> after = _storedState(payload['after']);
    if (!OpDescribeKit.sameJson(
      _playerState(await kit.callRoute('GET', _player)),
      after,
    )) {
      return const OpUndoOutcome.superseded();
    }
    final List<String> oldQueue = opUndoStrings(before['queue']);
    final bool sameQueue = OpDescribeKit.sameJson(oldQueue, after['queue']);
    if (oldQueue.isEmpty) {
      // 原来什么都没放：引擎没有「清空队列」，停在暂停态就是原状。
      if (after['playing'] == true) {
        await kit.callRoute('POST', '$_player/pause');
      }
      return const OpUndoOutcome.done();
    }
    if (!sameQueue) {
      await kit.callRoute(
        'POST',
        '$_player/play',
        body: <String, Object?>{
          'tracks': oldQueue,
          if (before['index'] is int) 'index': before['index'],
        },
      );
    } else if (before['index'] is int && before['index'] != after['index']) {
      await kit.callRoute(
        'POST',
        '$_player/jump',
        body: <String, Object?>{'index': before['index']},
      );
    }
    final bool playingNow =
        _playerState(await kit.callRoute('GET', _player))['playing'] == true;
    if (before['playing'] == true && !playingNow) {
      await kit.callRoute('POST', '$_player/play');
    } else if (before['playing'] != true && playingNow) {
      await kit.callRoute('POST', '$_player/pause');
    }
    return const OpUndoOutcome.done();
  },
);

List<OpDescription> _describePlayerOps(
  OpDescribeKit kit,
  OpAvailability Function() music,
) {
  const String needsQueue = 'Needs something queued (music.player.status).';
  return <OpDescription>[
    OpDescription(
      id: 'music.player.status',
      method: 'GET',
      pattern: _player,
      summary:
          'Now playing: current track, playing / paused, position, queue '
          '(track uids). active=false when nothing is queued.',
      availability: music,
    ),
    OpDescription(
      id: 'music.player.play',
      method: 'POST',
      pattern: '$_player/play',
      summary:
          'Play music. Without album / tracks: resume the current queue. With '
          'album: play the whole album; with tracks: play that list starting '
          'at index. Undo restores the previous queue and play state.',
      risk: OpRisk.write,
      availability: music,
      params: const <OpParam>[
        OpParam.string('album', description: 'Album uid to play.'),
        OpParam.stringList(
          'tracks',
          description: 'Track uids to play as the queue, in order.',
        ),
        OpParam.integer(
          'index',
          description: 'Start position in the album / tracks (0-based).',
        ),
        OpParam.boolean('shuffle', description: 'Shuffle the new queue.'),
      ],
      undo: _playerUndo(kit),
    ),
    OpDescription(
      id: 'music.player.pause',
      method: 'POST',
      pattern: '$_player/pause',
      summary: 'Pause music playback. $needsQueue',
      risk: OpRisk.write,
      availability: music,
      undo: _playerUndo(kit),
    ),
    OpDescription(
      id: 'music.player.next',
      method: 'POST',
      pattern: '$_player/next',
      summary: 'Skip to the next track in the queue. $needsQueue',
      risk: OpRisk.write,
      availability: music,
      undo: _playerUndo(kit),
    ),
    OpDescription(
      id: 'music.player.previous',
      method: 'POST',
      pattern: '$_player/previous',
      summary:
          'Previous track (or restart the current one if past the first '
          'seconds). $needsQueue',
      risk: OpRisk.write,
      availability: music,
      undo: _playerUndo(kit),
    ),
    OpDescription(
      id: 'music.player.jump',
      method: 'POST',
      pattern: '$_player/jump',
      summary: 'Jump to queue position index (0-based) and play it.',
      risk: OpRisk.write,
      availability: music,
      params: const <OpParam>[
        OpParam.integer(
          'index',
          description: 'Queue position (0-based).',
          required: true,
        ),
      ],
      undo: _playerUndo(kit),
    ),
  ];
}
