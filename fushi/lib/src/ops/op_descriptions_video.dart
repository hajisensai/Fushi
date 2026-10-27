import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_task_status.dart';
import 'package:fushi/src/ops/op_descriptions_library.dart'
    show OpUndoScope, opCustomUndo, opScopedSnapshotUndo, opUndoDisplay;

/// 视频库、播放器遥控、字幕的操作描述（spec `docs/specs/2026-10-26-ai-operations-agent-design.md` §4）。
///
/// 覆盖 `buildVideoCtlRoutes` 返回的全部路由。撤销形态：
/// - 在线字幕下载（`video.subtitle.fetch` / `video.subtitle.download`）= 删掉这次
///   新写的那份 sidecar（路由不覆盖已有同名字幕；`alreadyHasSubtitle` 什么都没写，撤销
///   不动任何文件；文件早于本次执行或之后被改过都报 superseded）；
/// - 播放器音量 / 音轨 / 主副字幕（都会持久化）= 执行前快照，撤销写回；
/// - 资源入队 = 取消那个下载任务；专名表整表替换 = 写回旧表。
/// 刮削认领 / 指定身份没有「解除身份、退回待确认」的路由，标 irreversible（见回报）。
List<OpDescription> describeVideoOps(OpDescribeKit kit) {
  final OpAvailability Function() video = kit.whenModule(ModuleId.video);
  final OpAvailability Function() discovery = kit.all(
    <OpAvailability Function()>[
      video,
      kit.whenStoreAllows(StoreRestrictedCapability.externalDiscovery),
    ],
  );
  final OpAvailability Function() downloads = kit
      .all(<OpAvailability Function()>[
        discovery,
        kit.whenStoreAllows(StoreRestrictedCapability.downloads),
        kit.whenModule(ModuleId.browse),
      ]);
  return <OpDescription>[
    ..._describeScrapeOps(kit, video),
    ..._describeDiscoveryOps(kit, discovery, downloads),
    ..._describePlayerOps(kit, video),
    ..._describeSubtitleOps(kit, video),
  ];
}

Map<String, Object?> _map(Object? raw) => raw is Map
    ? <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      }
    : const <String, Object?>{};

const String _video = '/api/admin/video';
const String _player = '$_video/player';
const String _jobs = '$_video/jobs';

const List<String> _providers = <String>['anidb', 'mal', 'tmdb'];

const OpParam _workIdParam = OpParam.string(
  'id',
  description:
      'Work id (book:<bookUid> or collection:<id>) from video.work.list.',
  required: true,
  inPath: true,
);

const OpParam _waitParam = OpParam.boolean(
  'wait',
  description: 'Wait until it finishes before returning.',
);

// ─────────────────────────────────────────────────────────────────────────
// 刮削
// ─────────────────────────────────────────────────────────────────────────

List<OpDescription> _describeScrapeOps(
  OpDescribeKit kit,
  OpAvailability Function() video,
) => <OpDescription>[
  OpDescription(
    id: 'video.work.list',
    method: 'GET',
    pattern: '$_video/works',
    summary:
        'List video works of local video sources with their scraped identity '
        '(provider:id), or with pending=true the works waiting for confirmation '
        'and why.',
    availability: video,
    params: const <OpParam>[
      OpParam.boolean(
        'pending',
        description: 'Only works waiting for manual confirmation.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.work.candidates',
    method: 'GET',
    pattern: '$_video/works/:id/candidates',
    summary:
        'Search metadata candidates (AniDB / MAL / TMDB) for a work, like the '
        '"re-scrape" search box. Read-only.',
    availability: video,
    params: const <OpParam>[
      _workIdParam,
      OpParam.string(
        'q',
        description:
            'Search text or explicit id (anidb:123); default: work title.',
      ),
      OpParam.string(
        'provider',
        description: 'Only this provider.',
        enumValues: _providers,
      ),
      OpParam.string(
        'type',
        description: 'Media form: tv or movie.',
        enumValues: <String>['tv', 'movie'],
      ),
    ],
  ),
  OpDescription(
    id: 'video.work.identify',
    method: 'POST',
    pattern: '$_video/works/:id/identify',
    summary:
        'Set a work\'s metadata identity (provider + external id) and re-scrape '
        'it (overwrites title, artwork and episode metadata).',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      _workIdParam,
      OpParam.string(
        'provider',
        description: 'anidb, mal or tmdb.',
        required: true,
        enumValues: _providers,
      ),
      OpParam.string(
        'externalId',
        description:
            'Numeric id at that provider (from video.work.candidates).',
        required: true,
      ),
      OpParam.string(
        'type',
        description: 'tv or movie (TMDB).',
        enumValues: <String>['tv', 'movie'],
      ),
      OpParam.boolean(
        'wait',
        description:
            'false = return immediately after queuing (default waits).',
      ),
    ],
  ),
  OpDescription(
    id: 'video.scrape.status',
    method: 'GET',
    pattern: '$_video/scrape',
    summary:
        'Scrape status: running batch progress, pending confirmation, manual '
        'queue and recent scrape runs.',
    availability: video,
    params: const <OpParam>[
      OpParam.integer('limit', description: 'Recent runs to list (1-50).'),
    ],
  ),
  OpDescription(
    id: 'video.scrape.start',
    method: 'POST',
    pattern: '$_video/scrape',
    summary:
        'Scrape a whole video source (numeric source id) or re-scrape one work '
        '(work id); overwrites scraped metadata. Progress via video.scrape.status.',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'target',
        description:
            'Source id (library.source.list) or work id (video.work.list).',
        required: true,
      ),
      _waitParam,
      OpParam.boolean(
        'interactive',
        description:
            'Source scrape pauses on ambiguous works for video.scrape.confirm.',
      ),
      OpParam.boolean(
        'allowOverwrite',
        description: 'Also overwrite protected external NFO / image files.',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed overwriting external NFO / images.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.scrape.cancel',
    method: 'POST',
    pattern: '$_video/scrape/cancel',
    summary: 'Cancel the running scrape batch (stops at the next boundary).',
    risk: OpRisk.irreversible,
    availability: video,
  ),
  OpDescription(
    id: 'video.scrape.confirmation',
    method: 'GET',
    pattern: '$_video/scrape/confirmation',
    summary:
        'The work currently waiting for confirmation in an interactive scrape '
        'and its numbered candidates (AI suggestion included).',
    availability: video,
    params: const <OpParam>[
      OpParam.boolean(
        'wait',
        description: 'Wait until a confirmation appears or the batch ends.',
      ),
      OpParam.integer(
        'timeout',
        description: 'Wait timeout in seconds (1-600, default 60).',
      ),
    ],
  ),
  OpDescription(
    id: 'video.scrape.confirm',
    method: 'POST',
    pattern: '$_video/scrape/confirmation',
    summary:
        'Answer the pending scrape confirmation: pick a candidate, give an '
        'explicit identity, or skip (work goes to the pending list). Writes the '
        'chosen identity and metadata.',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'action',
        description: 'pick, identity or skip.',
        required: true,
        enumValues: <String>['pick', 'identity', 'skip'],
      ),
      OpParam.integer('index', description: 'pick: 1-based candidate number.'),
      OpParam.string(
        'provider',
        description: 'identity: anidb, mal or tmdb.',
        enumValues: _providers,
      ),
      OpParam.string(
        'externalId',
        description: 'identity: numeric id at the provider.',
      ),
      OpParam.string(
        'type',
        description: 'identity: tv or movie.',
        enumValues: <String>['tv', 'movie'],
      ),
      OpParam.string(
        'id',
        description:
            'Confirmation id from video.scrape.confirmation (guards against '
            'answering a different item).',
      ),
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 发现 / 资源 / 入队
// ─────────────────────────────────────────────────────────────────────────

List<OpDescription> _describeDiscoveryOps(
  OpDescribeKit kit,
  OpAvailability Function() discovery,
  OpAvailability Function() downloads,
) => <OpDescription>[
  OpDescription(
    id: 'video.discovery.search',
    method: 'GET',
    pattern: '$_video/discovery/search',
    summary:
        'Search anime / TV / movie works in the discovery sources. Returns '
        'short ids (vw1…) valid during this app run.',
    availability: discovery,
    params: const <OpParam>[
      OpParam.string('q', description: 'Search text.', required: true),
      OpParam.string(
        'category',
        description: 'anime, tv, movie or all.',
        enumValues: <String>['anime', 'tv', 'movie', 'all'],
      ),
      OpParam.integer('page', description: 'Result page (1-based).'),
    ],
  ),
  OpDescription(
    id: 'video.discovery.resources',
    method: 'GET',
    pattern: '$_video/discovery/works/:id/resources',
    summary:
        'Search downloadable resources (torrents) for a discovered work. '
        'Returns short ids (vr1…) for video.discovery.acquire.',
    availability: downloads,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Work short id (vw…) from video.discovery.search.',
        required: true,
        inPath: true,
      ),
      OpParam.string('q', description: 'Override the search text.'),
    ],
  ),
  OpDescription(
    id: 'video.discovery.acquire',
    method: 'POST',
    pattern: '$_video/discovery/acquire',
    summary:
        'Queue a resource for download into a managed video source. Returns the '
        'download job id (track with the downloads ops). Undo cancels the job.',
    risk: OpRisk.write,
    longRunning: true,
    taskStatus: (String id) => opDownloadJobTaskStatus(kit, id),
    availability: downloads,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Resource short id (vr…) from video.discovery.resources.',
        required: true,
      ),
      OpParam.integer(
        'sourceId',
        description: 'Target video source id (default: preferred source).',
      ),
      OpParam.string(
        'subtitles',
        description: 'Subtitle policy: none, bestEffort (default) or required.',
        enumValues: <String>['none', 'bestEffort', 'required'],
      ),
    ],
    undo: kit.inverseRouteUndo(
      payloadOf: (CtlCall call, Object? result) => <String, Object?>{
        'jobId': '${_map(result)['jobId']}',
        'title': _map(result)['title'],
      },
      inverse: (Map<String, Object?> payload) => kit.callRoute(
        'POST',
        '/api/admin/downloads/:id/cancel',
        params: <String, String>{'id': '${payload['jobId']}'},
      ),
      describe: (Map<String, Object?> p) => 'download ${p['jobId']}',
    ),
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 播放页遥控
// ─────────────────────────────────────────────────────────────────────────

const String _needsPlayer = 'Needs a video playing in the app window.';

/// 当前选中的音轨 id（音轨列表里 selected 的那条）。
String? _selectedTrack(Object? response) {
  final Object? tracks = _map(response)['tracks'];
  if (tracks is! List) return null;
  for (final Object? t in tracks) {
    final Map<String, Object?> track = _map(t);
    if (track['selected'] == true) return '${track['id']}';
  }
  return null;
}

/// 主 / 副字幕选择的快照撤销（选轨、导入都会持久化选择）。
OpUndo _subtitleSelectionUndo(
  OpDescribeKit kit,
  Object? Function(CtlCall call, Object? result) newValue,
) => opScopedSnapshotUndo(
  bodyKeys: const <String>['secondary'],
  read: (OpUndoScope scope) async {
    final Map<String, Object?> state = _map(
      await kit.callRoute('GET', '$_player/subtitles'),
    );
    return state[scope.body['secondary'] == true ? 'secondary' : 'primary'];
  },
  write: (OpUndoScope scope, Object? old) async {
    final bool secondary = scope.body['secondary'] == true;
    final String? source = old?.toString();
    await kit.callRoute(
      'POST',
      '$_player/subtitle',
      body: source == null || source.isEmpty || source.startsWith('off:')
          ? <String, Object?>{'off': true, 'secondary': secondary}
          : <String, Object?>{'source': source, 'secondary': secondary},
    );
  },
  newValue: newValue,
);

const OpParam _secondaryParam = OpParam.boolean(
  'secondary',
  description: 'Secondary subtitle instead of primary.',
);

List<OpDescription> _describePlayerOps(
  OpDescribeKit kit,
  OpAvailability Function() video,
) => <OpDescription>[
  OpDescription(
    id: 'video.player.status',
    method: 'GET',
    pattern: _player,
    summary:
        'State of the open video player: item, position, playing, speed, '
        'volume, audio track, subtitles, current cue. active=false if none.',
    availability: video,
  ),
  OpDescription(
    id: 'video.player.volume',
    method: 'POST',
    pattern: '$_player/volume',
    summary:
        'Set player volume 0-100 or toggle mute (persisted). $_needsPlayer',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.number('volume', description: 'Volume 0-100.'),
      OpParam.boolean('mute', description: 'Toggle mute instead.'),
    ],
    undo: opScopedSnapshotUndo(
      read: (OpUndoScope scope) async =>
          _map(await kit.callRoute('GET', _player))['volume'],
      write: (OpUndoScope scope, Object? old) async {
        if (old is! num) return;
        await kit.callRoute(
          'POST',
          '$_player/volume',
          body: <String, Object?>{'volume': old},
        );
      },
      newValue: (CtlCall call, Object? result) => _map(result)['volume'],
      compareBy: (Object? v) => v is num ? (v * 10).round() : v,
    ),
  ),
  OpDescription(
    id: 'video.player.audio.list',
    method: 'GET',
    pattern: '$_player/audio-tracks',
    summary: 'Audio tracks of the playing video. $_needsPlayer',
    availability: video,
  ),
  OpDescription(
    id: 'video.player.audio.select',
    method: 'POST',
    pattern: '$_player/audio-track',
    summary:
        'Switch audio track (persisted per series / episode). $_needsPlayer',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Track id from video.player.audio.list.',
        required: true,
      ),
    ],
    undo: opScopedSnapshotUndo(
      read: (OpUndoScope scope) async =>
          _selectedTrack(await kit.callRoute('GET', '$_player/audio-tracks')),
      write: (OpUndoScope scope, Object? old) async {
        if (old == null) return;
        await kit.callRoute(
          'POST',
          '$_player/audio-track',
          body: <String, Object?>{'id': '$old'},
        );
      },
      newValue: (CtlCall call, Object? result) =>
          _selectedTrack(result) ?? call.body['id'],
    ),
  ),
  OpDescription(
    id: 'video.player.subtitle.list',
    method: 'GET',
    pattern: '$_player/subtitles',
    summary:
        'Subtitle tracks of the playing video (numbered), current primary / '
        'secondary source, and whether ASR / align / clip are available. '
        '$_needsPlayer',
    availability: video,
  ),
  OpDescription(
    id: 'video.player.subtitle.select',
    method: 'POST',
    pattern: '$_player/subtitle',
    summary:
        'Select the primary or secondary subtitle track, or turn it off '
        '(persisted). Give source or off. $_needsPlayer',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'source',
        description:
            'Track number or source value from video.player.subtitle.list.',
      ),
      OpParam.boolean('off', description: 'Turn the subtitle off.'),
      _secondaryParam,
    ],
    undo: _subtitleSelectionUndo(
      kit,
      (CtlCall call, Object? result) => _map(
        result,
      )[call.body['secondary'] == true ? 'secondary' : 'primary'],
    ),
  ),
  OpDescription(
    id: 'video.player.subtitle.import',
    method: 'POST',
    pattern: '$_player/subtitle/import',
    summary:
        'Load an external subtitle file into the playing video and select it. '
        'Undo restores the previous selection (the file stays in the track '
        'list). $_needsPlayer',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'path',
        description: 'Absolute subtitle file path.',
        required: true,
      ),
      _secondaryParam,
    ],
    undo: _subtitleSelectionUndo(
      kit,
      (CtlCall call, Object? result) => _map(result)['subtitle'],
    ),
  ),
  OpDescription(
    id: 'video.player.subtitle.ocr',
    method: 'POST',
    pattern: '$_player/subtitle/ocr',
    summary:
        'OCR a whole graphic subtitle track (PGS / VobSub) into text subtitles. '
        'May upload images to Google Lens and send low-confidence lines to the '
        'LLM. Returns a job id. $_needsPlayer',
    risk: OpRisk.irreversible,
    longRunning: true,
    taskIdOf: opTaskIdFromId,
    taskStatus: (String id) => opVideoJobTaskStatus(kit, id),
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'source',
        description:
            'Graphic track number / source from video.player.subtitle.list.',
        required: true,
      ),
      _waitParam,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed the long OCR run.',
      ),
      OpParam.userGate(
        'consentLlm',
        description: 'User agreed to send low-confidence lines to the LLM.',
      ),
      OpParam.userGate(
        'consentUpload',
        description: 'User agreed to upload subtitle images to Google Lens.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.player.subtitle.transcribe',
    method: 'POST',
    pattern: '$_player/subtitle/transcribe',
    summary:
        'Generate subtitles from the audio with the on-device speech model, or '
        'retime the current subtitle (retime=true). Writes subtitle files. '
        'Returns a job id. $_needsPlayer',
    risk: OpRisk.irreversible,
    longRunning: true,
    taskIdOf: opTaskIdFromId,
    taskStatus: (String id) => opVideoJobTaskStatus(kit, id),
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'language',
        description: 'ASR language tag (ja, en…); default: last used.',
      ),
      OpParam.boolean(
        'retime',
        description: 'Retime the current subtitle instead of generating.',
      ),
      _waitParam,
    ],
  ),
  OpDescription(
    id: 'video.player.subtitle.align',
    method: 'POST',
    pattern: '$_player/subtitle/align',
    summary:
        'Align the current external subtitle\'s timing to an embedded text track '
        '(rewrites its timing). Returns a job id. $_needsPlayer',
    risk: OpRisk.irreversible,
    longRunning: true,
    taskIdOf: opTaskIdFromId,
    taskStatus: (String id) => opVideoJobTaskStatus(kit, id),
    availability: video,
    params: const <OpParam>[
      _waitParam,
      OpParam.userGate(
        'confirm',
        description: 'User confirmed aligning despite weak evidence.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.player.clip',
    method: 'POST',
    pattern: '$_player/clip',
    summary:
        'Export a clip [startMs, endMs] of the playing video (burns in the '
        'current subtitle) to a file. Returns a job id. $_needsPlayer',
    risk: OpRisk.irreversible,
    longRunning: true,
    taskIdOf: opTaskIdFromId,
    taskStatus: (String id) => opVideoJobTaskStatus(kit, id),
    availability: video,
    params: const <OpParam>[
      OpParam.integer(
        'startMs',
        description: 'Clip start in ms.',
        required: true,
      ),
      OpParam.integer('endMs', description: 'Clip end in ms.', required: true),
      OpParam.string(
        'output',
        description: 'Absolute output path (default: app video_clips folder).',
      ),
      _waitParam,
    ],
  ),
  OpDescription(
    id: 'video.player.mine',
    method: 'POST',
    pattern: '$_player/mine',
    summary:
        'Create an Anki card for a word in the current subtitle sentence '
        '(screenshot, sentence audio). Writes to Anki. $_needsPlayer',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string('word', description: 'Headword.', required: true),
      OpParam.string('reading', description: 'Reading (default: dictionary).'),
      OpParam.string(
        'glossary',
        description: 'Definition (default: dictionary).',
      ),
      OpParam.string(
        'sentence',
        description: 'Sentence (default: current cue).',
      ),
      OpParam.object('fields', description: 'Extra card fields {name: value}.'),
      OpParam.boolean(
        'lookup',
        description:
            'Fill reading / definition from dictionaries (default true).',
      ),
      OpParam.boolean(
        'allowDuplicate',
        description: 'Add even if a duplicate card exists.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.job.list',
    method: 'GET',
    pattern: _jobs,
    summary:
        'Recent video jobs (subtitle OCR / transcribe / align / clip / '
        'subtitle generation) of this app run.',
    availability: video,
  ),
  OpDescription(
    id: 'video.job.get',
    method: 'GET',
    pattern: '$_jobs/:id',
    summary: 'One video job (wait=true waits until it ends).',
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Job id from video.job.list.',
        required: true,
        inPath: true,
      ),
      _waitParam,
    ],
  ),
  OpDescription(
    id: 'video.job.cancel',
    method: 'POST',
    pattern: '$_jobs/:id/cancel',
    summary: 'Cancel a running video job.',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Job id from video.job.list.',
        required: true,
        inPath: true,
      ),
    ],
  ),
  OpDescription(
    id: 'video.mine-queue.list',
    method: 'GET',
    pattern: '$_video/mine-queue',
    summary:
        'Cards queued while watching ("mine later") for a video, pending or failed.',
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'bookUid',
        description: 'Video bookUid (default: the playing video).',
      ),
    ],
  ),
  OpDescription(
    id: 'video.mine-queue.commit',
    method: 'POST',
    pattern: '$_video/mine-queue/commit',
    summary: 'Write all queued cards of a video to Anki.',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'bookUid',
        description: 'Video bookUid (default: the playing video).',
      ),
    ],
  ),
  OpDescription(
    id: 'video.mine-queue.discard',
    method: 'POST',
    pattern: '$_video/mine-queue/:id/discard',
    summary: 'Discard one queued card (row and its media).',
    risk: OpRisk.irreversible,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Queued card id from video.mine-queue.list.',
        required: true,
        inPath: true,
      ),
      OpParam.string(
        'bookUid',
        description: 'Video bookUid (default: the playing video).',
      ),
      OpParam.userGate(
        'confirm',
        description: 'User confirmed discarding the card.',
      ),
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────
// 字幕：生成 / 专名表 / 在线字幕
// ─────────────────────────────────────────────────────────────────────────

const OpParam _bookUidParam = OpParam.string(
  'bookUid',
  description:
      'Video bookUid (library item key without "video:"); or give collectionId.',
);

const OpParam _collectionIdParam = OpParam.integer(
  'collectionId',
  description: 'Collection id (whole season); or give bookUid.',
);

/// 文件状态指纹（撤销时判断「之后被改过」）。
Map<String, Object?>? _fileStamp(String path) {
  try {
    final FileStat stat = File(path).statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return <String, Object?>{
      'size': stat.size,
      'modified': stat.modified.millisecondsSinceEpoch,
    };
  } on FileSystemException {
    return null;
  }
}

/// 文件系统时间戳粒度的宽限（FAT 2 秒、部分网络盘更粗）。
const int _mtimeSlackMs = 2000;

/// 在线字幕下载的撤销：删掉这次**新写**的那份 sidecar。
///
/// 路由不覆盖已有同名字幕（同名已存在时回 `alreadyHasSubtitle`，什么都没写）。
/// 文件不在 / 修改时刻早于本次执行（不是这次写的）/ 执行后被改过，都报 superseded、
/// 不删。
OpUndo _subtitleFileUndo() => opCustomUndo(
  capture: (CtlCall call) async => <String, Object?>{
    'startedAt': DateTime.now().millisecondsSinceEpoch,
  },
  payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<String, Object?> r = _map(result);
    final String? path = r['outcome'] == 'installed'
        ? r['installedPath']?.toString()
        : null;
    return <String, Object?>{
      ...before,
      'path': path,
      if (path != null) 'stamp': _fileStamp(path),
    };
  },
  describe: (Map<String, Object?> p) =>
      p['path'] == null ? 'no subtitle written' : opUndoDisplay(p['path']),
  revert: (Map<String, Object?> payload) async {
    final String? path = payload['path']?.toString();
    if (path == null) return const OpUndoOutcome.done();
    final Map<String, Object?>? now = _fileStamp(path);
    if (now == null) {
      return const OpUndoOutcome.superseded(
        'the subtitle file is already gone',
      );
    }
    final int startedAt = (payload['startedAt'] as num?)?.toInt() ?? 0;
    if ((now['modified']! as int) < startedAt - _mtimeSlackMs) {
      return const OpUndoOutcome.superseded(
        'the subtitle file predates this download; left untouched',
      );
    }
    if (!OpDescribeKit.sameJson(now, payload['stamp'])) {
      return const OpUndoOutcome.superseded(
        'the subtitle file was modified after the download',
      );
    }
    await File(path).delete();
    return const OpUndoOutcome.done();
  },
);

List<OpDescription> _describeSubtitleOps(
  OpDescribeKit kit,
  OpAvailability Function() video,
) => <OpDescription>[
  OpDescription(
    id: 'video.subtitle.generate',
    method: 'POST',
    pattern: '$_video/subtitle-gen',
    summary:
        'Generate Japanese subtitles for a video or a whole collection with '
        'on-device ASR, optionally proofread by the LLM assigned to subtitle '
        'proofreading (sends ASR text, billed by the provider). Writes .ja.srt '
        'files. Returns a job id (video.job.get).',
    risk: OpRisk.irreversible,
    longRunning: true,
    taskIdOf: opTaskIdFromId,
    taskStatus: (String id) => opVideoJobTaskStatus(kit, id),
    availability: video,
    params: const <OpParam>[
      _bookUidParam,
      _collectionIdParam,
      OpParam.boolean(
        'proofread',
        description: 'AI proofreading (default true; false = ASR only).',
      ),
      OpParam.string(
        'segmenter',
        description: 'Segmenter: auto, moss or window (default: setting).',
        enumValues: <String>['auto', 'moss', 'window'],
      ),
      OpParam.string(
        'mossBackend',
        description: 'MOSS backend: auto, cuda, vulkan or cpu.',
        enumValues: <String>['auto', 'cuda', 'vulkan', 'cpu'],
      ),
      OpParam.boolean(
        'regenerateGlossary',
        description: 'Rebuild the work\'s name glossary first.',
      ),
      _waitParam,
      OpParam.userGate(
        'consentAi',
        description: 'User agreed to send ASR text to the AI provider.',
      ),
    ],
  ),
  OpDescription(
    id: 'video.subtitle.glossary.get',
    method: 'GET',
    pattern: '$_video/subtitle-glossary',
    summary:
        'Read the name glossary (proper nouns, readings, misrecognitions) used '
        'by subtitle generation for a video / collection.',
    availability: video,
    params: const <OpParam>[_bookUidParam, _collectionIdParam],
  ),
  OpDescription(
    id: 'video.subtitle.glossary.set',
    method: 'PUT',
    pattern: '$_video/subtitle-glossary',
    summary:
        'Replace the whole name glossary of a video / collection. Undo writes '
        'the previous table back.',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      _bookUidParam,
      _collectionIdParam,
      OpParam.object(
        'glossary',
        description:
            'Object {"entries": [{"ja": "...", "reading": "...", "kind": "...", '
            '"misrecognitions": ["..."], "note": "..."}]} (the full new table).',
        required: true,
        spread: true,
      ),
    ],
    undo: opScopedSnapshotUndo(
      bodyKeys: const <String>['bookUid', 'collectionId'],
      read: (OpUndoScope scope) async => _map(
        await kit.callRoute(
          'GET',
          '$_video/subtitle-glossary',
          body: scope.body,
        ),
      )['entries'],
      write: (OpUndoScope scope, Object? old) async {
        await kit.callRoute(
          'PUT',
          '$_video/subtitle-glossary',
          body: <String, Object?>{
            ...scope.body,
            'entries': old is List ? old : const <Object?>[],
          },
        );
      },
      newValue: (CtlCall call, Object? result) => _map(result)['entries'],
      // 写回时改过的条目会被标 userEdited：比较只看内容。
      compareBy: (Object? v) => <Object?>[
        if (v is List)
          for (final Object? e in v)
            <String, Object?>{..._map(e)}..remove('userEdited'),
      ],
    ),
  ),
  OpDescription(
    id: 'video.subtitle.fetch',
    method: 'POST',
    pattern: '$_video/subtitle-fetch',
    summary:
        'Fetch an online subtitle (Jimaku / OpenSubtitles / SubDL) for a scraped '
        'video, same as the automatic post-scrape fill: search, verify, download '
        'and save next to the video. Never overwrites an existing subtitle. '
        'Undo deletes the downloaded file.',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'bookUid',
        description: 'Video bookUid (library item key without "video:").',
        required: true,
      ),
      OpParam.string(
        'language',
        description:
            'Subtitle language code (default: series / global setting).',
      ),
    ],
    undo: _subtitleFileUndo(),
  ),
  OpDescription(
    id: 'video.subtitle.search',
    method: 'POST',
    pattern: '$_video/subtitle-search',
    summary:
        'Search online subtitle candidates for a scraped video without '
        'downloading. Returns short ids (vs1…) for video.subtitle.download; '
        'a candidate with "mismatch" is for a different work (e.g. a TV episode '
        'for a movie) and should not be offered.',
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'bookUid',
        description: 'Video bookUid (library item key without "video:").',
        required: true,
      ),
      OpParam.string('language', description: 'Subtitle language code.'),
      OpParam.string('query', description: 'Override the search text.'),
      OpParam.integer('episode', description: 'Episode number.'),
    ],
  ),
  OpDescription(
    id: 'video.subtitle.download',
    method: 'POST',
    pattern: '$_video/subtitle-get',
    summary:
        'Download one subtitle candidate and save it next to the video (never '
        'overwrites an existing same-name subtitle). Undo deletes the file.',
    risk: OpRisk.write,
    availability: video,
    params: const <OpParam>[
      OpParam.string(
        'id',
        description: 'Candidate short id (vs…) from video.subtitle.search.',
        required: true,
      ),
    ],
    undo: _subtitleFileUndo(),
  ),
];
