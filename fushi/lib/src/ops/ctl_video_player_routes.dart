import 'dart:async';
import 'dart:io';

import 'package:fushi_anki/fushi_anki.dart' show BaseAnkiRepository;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart' show WebMineQueueRow;
import 'package:fushi_dictionary/fushi_dictionary.dart'
    show DictionarySearchResult;
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/anki_view_model.dart'
    show ankiRepositoryProvider;
import 'package:fushi/src/media/video/video_playback_remote.dart';
import 'package:fushi/src/mining/video_mine_queue.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_dictionary_json.dart' show buildCtlMineFields;
import 'package:fushi/src/ops/ctl_video_player_support.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 视频播放页控制路由（CLI 侧命令见
/// `packages/fushi_cli/lib/src/commands/video_player_commands.dart`）。
///
/// 全部经视频页登记的遥控面（[videoPlaybackRemotes] 栈顶、实现
/// [VideoPlayerRemoteControl]）转调页内已有执行体：音量 / 音轨 / 主副字幕、字幕导入、
/// 图形轨整轨 OCR、语音转录 / 重定时、按内封轨对轴、对当前句制卡、片段导出。长任务
/// 返回任务 id（`/video/jobs/:id` 查进度、`/cancel` 取消），`wait=true` 时等到结束。
/// 暂存制卡队列（看完再制卡）是库里的数据，不要求视频页开着。
List<CtlRoute> buildVideoPlayerCtlRoutes(OpContext context) {
  final _VideoPlayerCtl ctl = _VideoPlayerCtl(context);
  return <CtlRoute>[
    CtlRoute.get('/api/admin/video/player', ctl.status),
    CtlRoute.post('/api/admin/video/player/volume', ctl.volume),
    CtlRoute.get('/api/admin/video/player/audio-tracks', ctl.audioTracks),
    CtlRoute.post('/api/admin/video/player/audio-track', ctl.selectAudioTrack),
    CtlRoute.get('/api/admin/video/player/subtitles', ctl.subtitles),
    CtlRoute.post('/api/admin/video/player/subtitle', ctl.selectSubtitle),
    CtlRoute.post(
      '/api/admin/video/player/subtitle/import',
      ctl.importSubtitle,
    ),
    CtlRoute.post('/api/admin/video/player/subtitle/ocr', ctl.subtitleOcr),
    CtlRoute.post(
      '/api/admin/video/player/subtitle/transcribe',
      ctl.transcribe,
    ),
    CtlRoute.post('/api/admin/video/player/subtitle/align', ctl.align),
    CtlRoute.post('/api/admin/video/player/clip', ctl.clip),
    CtlRoute.post('/api/admin/video/player/mine', ctl.mine),
    CtlRoute.get('/api/admin/video/jobs', ctl.listJobs),
    CtlRoute.get('/api/admin/video/jobs/:id', ctl.getJob),
    CtlRoute.post('/api/admin/video/jobs/:id/cancel', ctl.cancelJob),
    CtlRoute.get('/api/admin/video/mine-queue', ctl.mineQueue),
    CtlRoute.post('/api/admin/video/mine-queue/commit', ctl.commitMineQueue),
    CtlRoute.post(
      '/api/admin/video/mine-queue/:id/discard',
      ctl.discardMineQueue,
    ),
  ];
}

class _VideoPlayerCtl {
  _VideoPlayerCtl(this.context);

  final OpContext context;

  AppModel get appModel => context.appModel;

  void _requireVideoModule() {
    if (!appModel.moduleVisibility.isEnabled(ModuleId.video)) {
      throw const CtlFailure.rejected('「视频」模块已关闭（设置 › 功能模块）');
    }
  }

  /// 栈顶视频页的扩展遥控面；没有视频页 / 还在加载都是 409。
  VideoPlayerRemoteControl _control() {
    _requireVideoModule();
    final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
    if (remote == null) throw const CtlFailure.conflict('没有打开的视频播放页');
    if (remote is! VideoPlayerRemoteControl) {
      throw const CtlFailure.unsupported('当前播放页不支持这项控制');
    }
    if (remote.snapshot() == null) {
      throw const CtlFailure.conflict('视频还在加载，稍后再试');
    }
    return remote as VideoPlayerRemoteControl;
  }

  /// 执行一个遥控动作，[VideoRemoteFailure] 映射成控制通道失败。
  Future<T> _run<T>(FutureOr<T> Function() action) async {
    try {
      return await action();
    } on VideoRemoteFailure catch (e) {
      throw ctlVideoRemoteFailure(e);
    }
  }

  void _requireConfirm(CtlCall call, String what) {
    if (call.optBool('confirm') != true) {
      throw CtlFailure.badRequest('$what 需要 confirm=true');
    }
  }

  /// 新任务：`wait=true` 等结束再回（失败按任务结论报错），否则立刻回任务 id。
  Future<Object?> _jobResponse(CtlCall call, VideoRemoteJob job) async {
    if (call.optBool('wait') != true) return ctlVideoJobJson(job);
    await job.done;
    return _finishedJob(job);
  }

  Object? _finishedJob(VideoRemoteJob job) {
    if (job.status == VideoRemoteJobStatus.succeeded) {
      return ctlVideoJobJson(job);
    }
    throw CtlFailure(
      job.status == VideoRemoteJobStatus.cancelled ? 409 : 422,
      job.errorCode ?? job.status.name,
      '${job.id} ${job.error ?? job.status.name}',
    );
  }

  // ── 音量 / 音轨 / 字幕 ────────────────────────────────────────────────

  /// `video player`：当前视频页的播放状态（含音量、音轨、主副字幕源）。
  Future<Object?> status(CtlCall call) async {
    _requireVideoModule();
    final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
    if (remote == null) return <String, Object?>{'active': false};
    return ctlVideoPlayerStatusJson(remote.snapshot());
  }

  /// `video volume <0-100> | --mute`。
  Future<Object?> volume(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final Object? raw = call.body['volume'] ?? call.query['volume'];
    final bool mute = call.optBool('mute') == true;
    if ((raw == null) == !mute) {
      throw const CtlFailure.badRequest('volume 与 mute 二选一');
    }
    final double value = await _run(
      () => mute
          ? control.toggleMute()
          : control.setVolume(parseCtlVideoVolume(raw)),
    );
    return <String, Object?>{'volume': value};
  }

  Future<Object?> audioTracks(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    return <String, Object?>{
      'tracks': ctlVideoAudioTracksJson(await _run(control.audioTracks)),
    };
  }

  /// `video audio <id>`。
  Future<Object?> selectAudioTrack(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final String id = call.requireString('id');
    await _run(() => control.selectAudioTrack(id));
    return <String, Object?>{
      'tracks': ctlVideoAudioTracksJson(await _run(control.audioTracks)),
    };
  }

  Future<Object?> subtitles(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    return ctlVideoSubtitleStateJson(await _run(control.subtitleState));
  }

  /// `video sub <轨|off>` / `video sub2 <轨|off>`。
  Future<Object?> selectSubtitle(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final bool secondary = call.optBool('secondary') ?? false;
    final bool off = call.optBool('off') ?? false;
    final String? source = call.optString('source');
    if ((source == null) == !off) {
      throw const CtlFailure.badRequest('source 与 off 二选一');
    }
    if (off) {
      await _run(() => control.subtitleOff(secondary: secondary));
    } else {
      final VideoRemoteSubtitleState state = await _run(control.subtitleState);
      final String resolved = resolveCtlVideoSubtitleSource(source!, state);
      await _run(() => control.selectSubtitle(resolved, secondary: secondary));
    }
    return ctlVideoSubtitleStateJson(await _run(control.subtitleState));
  }

  /// `video sub-import <文件>`：导入并选为主字幕。
  Future<Object?> importSubtitle(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final String path = call.requireString('path');
    if (!p.isAbsolute(path)) {
      throw CtlFailure.badRequest('path 必须是绝对路径：$path');
    }
    final bool secondary = call.optBool('secondary') ?? false;
    final String selected = await _run(
      () => control.importSubtitle(path, secondary: secondary),
    );
    return <String, Object?>{'subtitle': selected, 'secondary': secondary};
  }

  /// `video sub-ocr <图形轨> --yes`：图形字幕整轨 OCR（长任务）。
  Future<Object?> subtitleOcr(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final String raw = call.requireString('source');
    _requireConfirm(call, '整轨 OCR（耗时较长，可能调用 OCR 服务 / AI）');
    // 先枚举（与打开字幕分类同一条），再按序号 / 持久化值定位。
    final VideoRemoteSubtitleState state = await _run(control.subtitleState);
    final String source = resolveCtlVideoSubtitleSource(raw, state);
    // 两个一次性同意的无头答案（与 app 同意框写同一份状态）；consentLlm 不给 = 未回答。
    final VideoRemoteJob job = await _run(
      () => control.startSubtitleOcr(
        source,
        consentLlm: call.optBool('consentLlm'),
        consentUpload: call.optBool('consentUpload') ?? false,
      ),
    );
    return _jobResponse(call, job);
  }

  /// `video sub-asr [--language ja] [--retime]`：语音转录生成 / 重定时字幕（长任务）。
  Future<Object?> transcribe(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final VideoRemoteJob job = await _run(
      () => control.startTranscribe(
        language: call.optString('language'),
        retime: call.optBool('retime') ?? false,
      ),
    );
    return _jobResponse(call, job);
  }

  /// `video sub-align [--yes]`：按内封文本轨给当前外挂字幕对轴（长任务）。
  Future<Object?> align(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final VideoRemoteJob job = await _run(
      () =>
          control.startSubtitleAlign(confirm: call.optBool('confirm') ?? false),
    );
    return _jobResponse(call, job);
  }

  /// `video clip <起> <止> [--output]`：片段导出（长任务）。
  Future<Object?> clip(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final ({int startMs, int endMs}) range = parseCtlVideoClipRange(call);
    final String? output = call.optString('output');
    if (output != null && !p.isAbsolute(output)) {
      throw CtlFailure.badRequest('output 必须是绝对路径：$output');
    }
    final VideoRemoteJob job = await _run(
      () => control.startClipExport(
        startMs: range.startMs,
        endMs: range.endMs,
        outputPath: output,
      ),
    );
    return _jobResponse(call, job);
  }

  // ── 制卡 ──────────────────────────────────────────────────────────────

  /// `video mine <词>`：对当前字幕句制卡。字段与 `anki mine` 同一个
  /// [buildCtlMineFields]（显式给的优先，读音 / 释义缺省从查词结果补），落卡走视频页
  /// 弹窗「+」同一条链路（截图、句子音频、统计、制卡历史）。
  Future<Object?> mine(CtlCall call) async {
    final VideoPlayerRemoteControl control = _control();
    final String word = call.requireString('word');
    final String? reading = call.optString('reading');
    final String? glossary = call.optString('glossary');
    DictionarySearchResult? found;
    if ((call.optBool('lookup') ?? true) &&
        (reading == null || glossary == null)) {
      found = await appModel.createRemoteLookupService().searchDictionary(
        term: word,
        wildcards: false,
        maximumTerms: 10,
      );
    }
    final Map<String, String> fields = buildCtlMineFields(
      word: word,
      reading: reading,
      sentence: call.optString('sentence'),
      glossary: glossary,
      extra: _stringMap(call.body['fields']),
      lookup: found,
      allowDuplicate: call.optBool('allowDuplicate') ?? false,
    );
    final VideoRemoteMineResult result = await _run(
      () => control.mineCurrentCue(fields),
    );
    return <String, Object?>{
      ...ctlVideoMineResultJson(result),
      'expression': fields['expression'],
      'reading': fields['reading'],
      'glossaryFilled': (fields['glossary'] ?? '').isNotEmpty,
    };
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw == null) return const <String, String>{};
    if (raw is! Map) throw const CtlFailure.badRequest('fields 必须是对象');
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in raw.entries)
        '${e.key}': e.value == null ? '' : '${e.value}',
    };
  }

  // ── 长任务 ────────────────────────────────────────────────────────────

  Future<Object?> listJobs(CtlCall call) async => <String, Object?>{
    'jobs': <Map<String, Object?>>[
      for (final VideoRemoteJob job in videoRemoteJobs.recent)
        ctlVideoJobJson(job),
    ],
  };

  VideoRemoteJob _job(CtlCall call) {
    final String id = call.params['id']!;
    return videoRemoteJobs[id] ??
        (throw CtlFailure.notFound('没有任务 $id（只保留本次 app 运行内最近的任务）'));
  }

  /// `video job <id> [--wait]`。
  Future<Object?> getJob(CtlCall call) async {
    final VideoRemoteJob job = _job(call);
    if (call.optBool('wait') == true && job.isRunning) {
      await job.done;
      return _finishedJob(job);
    }
    return ctlVideoJobJson(job);
  }

  /// `video job-cancel <id>`：转调页内对应任务的取消入口。
  Future<Object?> cancelJob(CtlCall call) async {
    final VideoRemoteJob job = _job(call);
    if (!job.isRunning) {
      throw CtlFailure.conflict('${job.id} 已结束（${job.status.name}）');
    }
    if (!job.cancel()) {
      throw CtlFailure.conflict('${job.id} 当前阶段不能取消');
    }
    return ctlVideoJobJson(job);
  }

  // ── 暂存制卡队列（看完再制卡） ────────────────────────────────────────

  /// 与视频页角标 / 待制卡列表同一个暂存队列（`<support>/video_mine_queue`）。
  Future<VideoMineQueue> _queue() async {
    final Directory support = await AppPaths.supportRootDirectory();
    return VideoMineQueue(
      db: appModel.database,
      root: Directory(p.join(support.path, VideoMineQueue.dirName)),
    );
  }

  /// `bookUid` 缺省取当前视频页正在播的条目。
  String _queueBook(CtlCall call) {
    final String? explicit = call.optString('bookUid');
    final String bookUid;
    if (explicit != null) {
      bookUid = explicit;
    } else {
      final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
      if (remote is! VideoPlayerRemoteControl) {
        throw const CtlFailure.badRequest('没有打开的视频播放页，请用 bookUid 指定视频');
      }
      bookUid = (remote as VideoPlayerRemoteControl).activeBookUid;
    }
    if (!isCtlVideoMineQueueBook(bookUid)) {
      throw CtlFailure.rejected('$bookUid 不是视频页暂存的制卡（网页播放器的队列在网页里处理）');
    }
    return bookUid;
  }

  /// 外部改了队列后让开着的视频页刷新角标计数。
  Future<void> _refreshPage(String bookUid) async {
    final VideoPlaybackRemote? remote = videoPlaybackRemotes.current.value;
    if (remote is VideoPlayerRemoteControl &&
        (remote as VideoPlayerRemoteControl).activeBookUid == bookUid) {
      await (remote as VideoPlayerRemoteControl).refreshMineQueue();
    }
  }

  /// `video mine-queue [--book]`：待写入与写入失败的暂存卡。
  Future<Object?> mineQueue(CtlCall call) async {
    final String bookUid = _queueBook(call);
    final VideoMineQueue queue = await _queue();
    final List<WebMineQueueRow> rows = <WebMineQueueRow>[
      ...await queue.pending(bookUid),
      ...await queue.failed(bookUid),
    ];
    return <String, Object?>{
      'bookUid': bookUid,
      'items': rows.map(ctlVideoMineQueueRowJson).toList(),
    };
  }

  /// `video mine-send`：全部写入 Anki（待制卡列表「全部写入」同一个 commitAll，
  /// 同一 bookUid 进程内串行）。
  Future<Object?> commitMineQueue(CtlCall call) async {
    final String bookUid = _queueBook(call);
    final VideoMineQueue queue = await _queue();
    final BaseAnkiRepository repo = context.ref.read(ankiRepositoryProvider);
    final VideoMineCommitSummary summary = await queue.commitAll(
      bookUid: bookUid,
      repo: repo,
    );
    await _refreshPage(bookUid);
    return <String, Object?>{
      'bookUid': bookUid,
      'succeeded': summary.succeeded,
      'failed': summary.failed,
      if (summary.firstError != null) 'firstError': summary.firstError,
    };
  }

  /// `video mine-discard <id> --yes`：删掉一张暂存卡（行 + 媒体）。
  Future<Object?> discardMineQueue(CtlCall call) async {
    final int? id = int.tryParse(call.params['id']!);
    if (id == null || id <= 0) {
      throw CtlFailure.badRequest('暂存卡 id 必须是正整数：${call.params['id']}');
    }
    _requireConfirm(call, '丢弃暂存卡');
    final String bookUid = _queueBook(call);
    final VideoMineQueue queue = await _queue();
    final List<WebMineQueueRow> rows = <WebMineQueueRow>[
      ...await queue.pending(bookUid),
      ...await queue.failed(bookUid),
    ];
    if (!rows.any((WebMineQueueRow r) => r.id == id)) {
      throw CtlFailure.notFound('$bookUid 下没有暂存卡 $id（video mine-queue 查看）');
    }
    await queue.discard(id);
    await _refreshPage(bookUid);
    return <String, Object?>{'bookUid': bookUid, 'discarded': id};
  }
}
