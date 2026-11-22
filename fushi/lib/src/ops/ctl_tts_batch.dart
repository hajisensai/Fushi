/// 漫画有声的两种按句批量写操作（路由见 `ctl_tts_routes.dart`，描述与撤销见
/// `op_descriptions_tts.dart`）：
///
/// - **按句换上本地音频**（`tts.manga.lines.replace`）：行 ID → 本地音频路径。先逐句
///   预检（这句在演出稿与本机成品清单里、路径是绝对路径、文件在、格式认得），可只预检
///   （`dryRun`）拿结构化结果；正式执行时把音频按内容寻址复制进成品目录的保留区，交给
///   引擎 [MangaAudioRenderer.bindLocalAudio] 整形（与有声书片段同一套整形，整形版本
///   照记）并全有或全无地改清单 / 演出稿（音源记成 [MangaLocalAudio]，之后整卷重跑会
///   沿用、整形版本变了从保留副本重整形，不会被重新合成盖掉）/ 未配音账本，再只把这几句
///   的音频路径与 cue 时长写进库，续听位置由仓库层按旧 / 新 cue 换算到同一句；
/// - **按角色批量重生成**（`tts.manga.character.regenerate`）：列出某角色（可再按台词
///   类型筛）已生成的合成句，给每句换一个新种子，作为一个「补回」任务排进全应用唯一的
///   制作队列（引擎整批预合成，逐句换文件，失败的句子保留旧音频），完成后只更新库里
///   这几句。
///
/// 两者共用一份撤销：执行前把要动的句子在清单 / 演出稿 / 账本里的样子和旧音频（以及
/// 旧的本地音频保留副本）备份进 `<备份目录>/<时间戳>-batch/`（`snapshot.json` + 音频），
/// 撤销时逐句核对「还是这次改出来的样子」才放回，之后又被改过的句子不覆盖。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render_plan.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_renderer.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_render_queue.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/studio/tts_series_cast.dart'
    show ttsVoicingStoreFor;
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show updateMangaAudioLines;
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_tts_support.dart';

/// 认得的本地音频扩展名（ffmpeg 都能解；其它格式先在外部转成 WAV）。
const Set<String> kMangaLocalAudioExtensions = <String>{
  '.wav',
  '.flac',
  '.mp3',
  '.m4a',
  '.aac',
  '.ogg',
  '.opus',
};

/// 一次批量操作最多动多少句（一卷的台词量级；再多多半是映射写错了）。
const int kMangaBatchLineLimit = 2000;

/// 撤销备份子目录里的快照文件名。
const String _kSnapshotFile = 'snapshot.json';

/// 撤销取消批量重生成后，最多等它停下多久。
const Duration _kCancelSettle = Duration(seconds: 30);

// ─────────────────────────────────────────────────────────────────────────
// 按句换上本地音频
// ─────────────────────────────────────────────────────────────────────────

/// 一句的预检结果。
class _ReplaceCheck {
  _ReplaceCheck(this.lineId, this.path);

  final String lineId;
  final String path;
  MangaScriptLine? line;
  MangaRenderedLine? rendered;
  String? code;
  String? message;

  bool get ok => code == null;

  void fail(String c, String m) {
    code ??= c;
    message ??= m;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'line': lineId,
    'file': path,
    'ok': ok,
    if (rendered case final MangaRenderedLine r) ...<String, Object?>{
      'page': r.page + 1,
      'speaker': ttsSpeakerWire(r.speaker),
      'text': r.text,
      'currentDurationMs': r.durationMs,
      if (r.placeholder) 'placeholder': true,
    },
    'code': ?code,
    'message': ?message,
  };
}

/// 读请求里的「行 ID → 本地音频路径」：`files`（对象）或 `mapping`（这样一个 JSON
/// 对象文件的绝对路径；里面的相对路径按映射文件所在目录解析），二选一。
Future<Map<String, String>> mangaReplaceFilesOf(
  Map<String, Object?> body,
) async {
  final Object? files = body['files'];
  final Object? mapping = body['mapping'];
  if ((files == null) == (mapping == null)) {
    throw const CtlFailure.badRequest(
      '给 files（行 ID → 音频绝对路径的对象）或 mapping（这样一个 JSON 文件的绝对路径），二选一',
    );
  }
  Map<Object?, Object?> raw;
  String? base;
  if (files != null) {
    if (files is! Map) {
      throw const CtlFailure.badRequest('files 应为对象：{"行 ID": "音频绝对路径"}');
    }
    raw = files;
  } else {
    final String path = '$mapping'.trim();
    if (!p.isAbsolute(path)) {
      throw CtlFailure.badRequest('mapping 应为映射 JSON 文件的绝对路径，收到「$path」');
    }
    final File f = File(p.normalize(path));
    if (!await f.exists()) {
      throw CtlFailure.badRequest('映射文件不存在：${f.path}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await f.readAsString());
    } on FormatException catch (e) {
      throw CtlFailure.badRequest('映射文件不是合法 JSON：${e.message}');
    }
    if (decoded is! Map) {
      throw const CtlFailure.badRequest('映射文件应为对象：{"行 ID": "音频路径"}');
    }
    raw = decoded;
    base = f.parent.path;
  }
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<Object?, Object?> e in raw.entries) {
    final String id = '${e.key}'.trim();
    final Object? v = e.value;
    if (id.isEmpty || v is! String || v.trim().isEmpty) {
      throw CtlFailure.badRequest('映射里「${e.key}」的值应为音频路径');
    }
    final String path = v.trim();
    out[id] = base != null && !p.isAbsolute(path)
        ? p.normalize(p.join(base, path))
        : path;
  }
  if (out.isEmpty) throw const CtlFailure.badRequest('映射是空的');
  if (out.length > kMangaBatchLineLimit) {
    throw CtlFailure.badRequest(
      '一次最多换 $kMangaBatchLineLimit 句，收到 ${out.length} 句',
    );
  }
  return out;
}

/// 本机成品清单；还没生成过 422。
Future<MangaRenderManifest> _renderedManifest(
  AppModel appModel,
  String bookKey,
) async {
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    mangaRenderManifestFile(appModel, bookKey),
  );
  if (manifest == null) {
    throw const CtlFailure(
      422,
      'manga_not_rendered',
      '这一卷还没生成过有声成品，先整卷生成（tts render）',
    );
  }
  return manifest;
}

MangaRenderedLine? _renderedLine(MangaRenderManifest manifest, String id) {
  for (final MangaRenderedLine l in manifest.lines) {
    if (l.lineId == id) return l;
  }
  return null;
}

Future<List<_ReplaceCheck>> _checkReplace(
  MangaAudioVolume volume,
  MangaRenderManifest manifest,
  Map<String, String> files,
) async {
  final List<_ReplaceCheck> out = <_ReplaceCheck>[];
  for (final MapEntry<String, String> e in files.entries) {
    final _ReplaceCheck c = _ReplaceCheck(e.key, e.value);
    out.add(c);
    c.line = volume.script.lineById(e.key);
    c.rendered = _renderedLine(manifest, e.key);
    if (c.line == null) {
      c.fail('line_missing', '演出稿里没有这一句');
    } else if (c.rendered == null) {
      c.fail('line_not_rendered', '这一句不在成品里（不读的类型或还没生成）');
    }
    if (!p.isAbsolute(e.value)) {
      c.fail('path_not_absolute', '音频路径应为绝对路径');
      continue;
    }
    final String ext = p.extension(e.value).toLowerCase();
    if (!kMangaLocalAudioExtensions.contains(ext)) {
      c.fail(
        'unsupported_format',
        '不认得的音频格式「$ext」（支持 ${kMangaLocalAudioExtensions.join(' ')}）',
      );
    }
    final File f = File(p.normalize(e.value));
    if (!await f.exists()) {
      c.fail('file_missing', '音频文件不存在');
    } else if (await f.length() == 0) {
      c.fail('file_empty', '音频文件是空的');
    }
  }
  return out;
}

String _failureSummary(Iterable<MapEntry<String, String>> failures) {
  final List<MapEntry<String, String>> all = failures.toList();
  return '${all.length} 句没通过：'
      '${all.take(8).map((MapEntry<String, String> e) => '${e.key}（${e.value}）').join('、')}'
      '${all.length > 8 ? ' …' : ''}';
}

/// 按句换上本地音频（路由本体）。见文件头。
Future<Map<String, Object?>> replaceMangaLinesWithLocalAudio(
  TtsCtlDeps deps,
  MangaAudioVolume volume, {
  required Map<String, String> files,
  required bool dryRun,
}) async {
  final AppModel appModel = deps.appModel;
  final String bookKey = volume.bookKey;
  final File manifestFile = mangaRenderManifestFile(appModel, bookKey);
  final MangaRenderManifest manifest = await _renderedManifest(
    appModel,
    bookKey,
  );
  final List<_ReplaceCheck> checks = await _checkReplace(
    volume,
    manifest,
    files,
  );
  final bool allOk = checks.every((_ReplaceCheck c) => c.ok);
  if (dryRun) {
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'dryRun': true,
      'ok': allOk,
      'lines': <Map<String, Object?>>[
        for (final _ReplaceCheck c in checks) c.toJson(),
      ],
    };
  }
  if (!allOk) {
    throw CtlFailure(
      422,
      'manga_audio_replace_invalid',
      '${_failureSummary(<MapEntry<String, String>>[for (final _ReplaceCheck c in checks)
        if (!c.ok) MapEntry<String, String>(c.lineId, c.message!)])}（先带 dryRun=true 预检）',
    );
  }

  final MangaRenderBackend backend;
  try {
    backend = await deps.localAudioBackend();
  } on TtsRenderFailure catch (e) {
    throw CtlFailure(422, e.code, '整形本地音频要用 ffmpeg：${e.code}');
  }

  // 按内容寻址放进保留区（同一段音频只存一份）。
  final Directory dir = manifestFile.parent;
  final Map<String, MangaLocalAudio> bindings = <String, MangaLocalAudio>{};
  final List<File> staged = <File>[];
  for (final _ReplaceCheck c in checks) {
    final File src = File(p.normalize(c.path));
    final List<int> bytes = await src.readAsBytes();
    final MangaLocalAudio audio = MangaLocalAudio(
      sig: sha1.convert(bytes).toString().substring(0, 16),
      ext: p.extension(src.path).toLowerCase(),
      name: p.basename(src.path),
    );
    bindings[c.lineId] = audio;
    final File kept = File(mangaLocalAudioSourcePath(dir.path, audio));
    if (!await kept.exists()) {
      await kept.parent.create(recursive: true);
      final File part = File('${kept.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(kept.path);
      staged.add(kept);
    }
  }

  final _BatchBackup backup = await _BatchBackup.create(appModel, bookKey);
  for (final _ReplaceCheck c in checks) {
    await backup.add(
      dir,
      line: c.rendered!,
      scriptLine: c.line!,
      ledgerEntry: null,
      expectFile: mangaLocalLineFileName(c.lineId, bindings[c.lineId]!),
    );
  }

  await deps.stopPlayback(<String>[bookKey]);
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(bookKey);
  backup.captureLedger(ledger);
  final MangaLocalBindOutcome outcome =
      await MangaAudioRenderer(
        backend: backend,
        manifestFile: manifestFile,
      ).bindLocalAudio(
        script: volume.script,
        manifest: manifest,
        ledger: ledger,
        bindings: bindings,
        cancel: TtsRenderCancelToken(),
      );
  if (!outcome.ok) {
    for (final File f in staged) {
      await deleteMangaFileQuietly(f);
    }
    await backup.discard();
    throw CtlFailure(
      422,
      'manga_audio_replace_failed',
      '${_failureSummary(<MapEntry<String, String>>[for (final MapEntry<String, MangaLineFailure> e in outcome.failures.entries) MapEntry<String, String>(e.key, e.value.code)])}，这次什么都没改',
    );
  }
  await mangaAudioScriptStoreFor(appModel).save(bookKey, volume.script);
  await voicing.save(bookKey, ledger);
  if (outcome.bound.isNotEmpty) {
    await updateMangaAudioLines(
      appModel.database,
      bookKey: bookKey,
      manifestFile: manifestFile,
      manifest: manifest,
      lineIds: outcome.bound.keys,
    );
  }
  final String? backupName = await backup.commit(
    only: outcome.bound.keys.toSet(),
  );
  return <String, Object?>{
    'key': ttsMangaWireKey(bookKey),
    'replaced': outcome.bound.length,
    'unchanged': outcome.unchanged.length,
    'lines': <Map<String, Object?>>[
      for (final _ReplaceCheck c in checks)
        <String, Object?>{
          'line': c.lineId,
          'file': c.path,
          'status': outcome.unchanged.contains(c.lineId)
              ? 'unchanged'
              : 'replaced',
          'durationMs':
              outcome.bound[c.lineId] ??
              _renderedLine(manifest, c.lineId)?.durationMs,
          'previousDurationMs': c.rendered!.durationMs,
        },
    ],
    'backup': ?backupName,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 按角色批量重生成
// ─────────────────────────────────────────────────────────────────────────

/// 按角色批量重生成（路由本体）。见文件头。[name] 是线上名（`narrator` / `unknown` /
/// 角色名），[kind] 只要这一类台词。
Future<Map<String, Object?>> regenerateMangaCharacterLines(
  TtsCtlDeps deps,
  MangaAudioVolume volume, {
  required String name,
  required CastLineKind? kind,
  required bool dryRun,
}) async {
  final AppModel appModel = deps.appModel;
  final String bookKey = volume.bookKey;
  final MangaAudioScript script = volume.script;
  final String speaker = ttsSpeakerFromWire(name);
  final List<MangaScriptLine> ofSpeaker = <MangaScriptLine>[
    for (final MangaScriptLine l in script.lines)
      if (l.speaker == speaker && (kind == null || l.kind == kind)) l,
  ];
  if (ofSpeaker.isEmpty) {
    throw CtlFailure.notFound(
      '这一卷没有「$name」${kind == null ? '' : '的 ${kind.wire} '}台词',
    );
  }
  final MangaRenderManifest manifest = await _renderedManifest(
    appModel,
    bookKey,
  );
  final List<(MangaScriptLine, MangaRenderedLine)> targets =
      <(MangaScriptLine, MangaRenderedLine)>[];
  final List<Map<String, Object?>> skipped = <Map<String, Object?>>[];
  for (final MangaScriptLine l in ofSpeaker) {
    final MangaRenderedLine? r = _renderedLine(manifest, l.lineId);
    final String? reason = r == null
        ? 'not_rendered'
        : switch (script.audioPlanFor(l)) {
            MangaLineAudioPlan.synthesize => null,
            MangaLineAudioPlan.audiobookClip => 'audiobook_clip',
            MangaLineAudioPlan.localAudio => 'local_audio',
            MangaLineAudioPlan.silent => 'not_read',
          };
    if (reason != null || r == null) {
      skipped.add(<String, Object?>{'line': l.lineId, 'reason': reason});
    } else {
      targets.add((l, r));
    }
  }
  List<Map<String, Object?>> linesJson() => <Map<String, Object?>>[
    for (final (MangaScriptLine l, MangaRenderedLine r) in targets)
      <String, Object?>{
        'line': l.lineId,
        'page': l.page + 1,
        'kind': l.kind.wire,
        'text': r.text,
        'durationMs': r.durationMs,
        if (r.seed != null) 'seed': r.seed,
        if (r.placeholder) 'placeholder': true,
      },
  ];
  if (dryRun) {
    return <String, Object?>{
      'key': ttsMangaWireKey(bookKey),
      'name': ttsSpeakerWire(speaker),
      'dryRun': true,
      'lines': linesJson(),
      'skipped': skipped,
    };
  }
  if (targets.isEmpty) {
    throw const CtlFailure(
      422,
      'manga_nothing_to_regenerate',
      '这个角色没有可重生成的合成句（有声书片段 / 本地音频 / 没生成的句子不重生成）',
    );
  }
  final String? voice = deps.defaultVoiceFor(bookKey);
  if (voice == null) {
    throw const CtlFailure.rejected('没有可用的声音（先在朗读设置里选一个声音）');
  }

  final math.Random random = math.Random();
  final Map<String, int> seeds = <String, int>{};
  for (final (MangaScriptLine l, MangaRenderedLine _) in targets) {
    final int current = l.effectiveSeed(script.defaultSeed);
    int seed;
    do {
      seed = random.nextInt(MangaScriptLimits.maxSeed);
    } while (seed == current);
    seeds[l.lineId] = seed;
  }

  final File manifestFile = mangaRenderManifestFile(appModel, bookKey);
  final CastVoicingLedger ledger = await ttsVoicingStoreFor(
    appModel,
  ).load(bookKey);
  final _BatchBackup backup = await _BatchBackup.create(appModel, bookKey);
  for (final (MangaScriptLine l, MangaRenderedLine r) in targets) {
    await backup.add(
      manifestFile.parent,
      line: r,
      scriptLine: l,
      ledgerEntry: ledger.entries[l.lineId],
      expectSeed: seeds[l.lineId],
    );
  }
  final TtsRenderJob job = await deps.renderQueue().enqueue(
    bookKey: bookKey,
    title: volume.row.title.isEmpty ? bookKey : volume.row.title,
    presetId: voice,
    kind: TtsRenderJobKind.manga,
    lineRequests: <TtsRenderLineRequest>[
      for (final MapEntry<String, int> e in seeds.entries)
        TtsRenderLineRequest(lineId: e.key, seed: e.value),
    ],
  );
  final String? backupName = await backup.commit(jobId: job.id);
  return <String, Object?>{
    'taskId': ttsMangaWireKey(bookKey),
    'key': ttsMangaWireKey(bookKey),
    'name': ttsSpeakerWire(speaker),
    'lines': linesJson(),
    'skipped': skipped,
    'render': ttsRenderJobJson(job),
    'backup': ?backupName,
  };
}

// ─────────────────────────────────────────────────────────────────────────
// 撤销备份
// ─────────────────────────────────────────────────────────────────────────

/// 一次批量操作的撤销备份：`<备份目录>/<时间戳>-batch/`。
class _BatchBackup {
  _BatchBackup._(this.dir);

  static Future<_BatchBackup> create(AppModel appModel, String bookKey) async {
    final Directory root = mangaCtlBackupDir(appModel, bookKey);
    final Directory dir = Directory(
      p.join(root.path, '${DateTime.now().microsecondsSinceEpoch}-batch'),
    );
    await dir.create(recursive: true);
    return _BatchBackup._(dir);
  }

  final Directory dir;
  final List<Map<String, Object?>> _lines = <Map<String, Object?>>[];

  /// 备份一句：旧音频文件（在的话）、旧的本地音频保留副本（这句原本就是本地音频时），
  /// 以及清单 / 演出稿 / 账本里的样子。[expectFile] / [expectSeed] 是这次操作要把这句
  /// 改成的样子（撤销据此认出「还是这次改出来的」）。
  Future<void> add(
    Directory audioDir, {
    required MangaRenderedLine line,
    required MangaScriptLine scriptLine,
    required CastVoicingEntry? ledgerEntry,
    String? expectFile,
    int? expectSeed,
  }) async {
    final int i = _lines.length;
    String? backupName;
    final File old = File(p.join(audioDir.path, line.file));
    if (await old.exists()) {
      backupName = '$i-${p.basename(line.file)}';
      await old.copy(p.join(dir.path, backupName));
    }
    String? localName;
    if (scriptLine.audio case final MangaLocalAudio audio) {
      final File kept = File(mangaLocalAudioSourcePath(audioDir.path, audio));
      if (await kept.exists()) {
        localName = '$i-local${audio.ext}';
        await kept.copy(p.join(dir.path, localName));
      }
    }
    _lines.add(<String, Object?>{
      'id': line.lineId,
      'oldLine': line.toJson(),
      'oldScriptLine': scriptLine.toJson(),
      'ledgerEntry': ?ledgerEntry?.toJson(),
      'backup': ?backupName,
      'localBackup': ?localName,
      'expectFile': ?expectFile,
      'expectSeed': ?expectSeed,
    });
  }

  /// 换本地音频时账本是在备份之后才读的：把这几句当时的账本条目补进快照。
  void captureLedger(CastVoicingLedger ledger) {
    for (final Map<String, Object?> l in _lines) {
      final CastVoicingEntry? entry = ledger.entries[l['id']];
      if (entry != null) l['ledgerEntry'] = entry.toJson();
    }
  }

  /// 写快照；[only] 给了就只留这些句子。一句都没留时删掉整个备份、返回 null，否则返回
  /// 备份名（撤销载荷里存它）。
  Future<String?> commit({Set<String>? only, String? jobId}) async {
    final List<Map<String, Object?>> kept = <Map<String, Object?>>[
      for (final Map<String, Object?> l in _lines)
        if (only == null || only.contains(l['id'])) l,
    ];
    if (kept.isEmpty) {
      await discard();
      return null;
    }
    await File(p.join(dir.path, _kSnapshotFile)).writeAsString(
      jsonEncode(<String, Object?>{'job': ?jobId, 'lines': kept}),
      flush: true,
    );
    await pruneMangaCtlBackups(dir.parent);
    return p.basename(dir.path);
  }

  Future<void> discard() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // 被占用（Windows）：留给下次修剪。
    }
  }
}

/// 撤销一次批量操作（换本地音频 / 按角色重生成），载荷 = `{bookKey, backup}`。逐句
/// 核对清单里这句还是这次改出来的样子（文件名 / 种子）才放回旧音频、清单行、演出稿行
/// 与账本条目；之后又被改过的句子不覆盖。批量重生成还在排队 / 在跑时先取消它、等它
/// 停下再恢复（取消时还没落盘的句子本来就没改）。
Future<OpUndoOutcome> revertMangaLineBatch(
  TtsCtlDeps deps,
  Map<String, Object?> payload,
) async {
  final AppModel appModel = deps.appModel;
  final String bookKey = '${payload['bookKey']}';
  final Object? backupName = payload['backup'];
  if (backupName is! String || backupName.isEmpty) {
    return const OpUndoOutcome.done('这次操作没有改动任何句子');
  }
  final Directory dir = Directory(
    p.join(mangaCtlBackupDir(appModel, bookKey).path, backupName),
  );
  final File snapshotFile = File(p.join(dir.path, _kSnapshotFile));
  if (!await snapshotFile.exists()) {
    return const OpUndoOutcome.failed('旧音频备份已清理，恢复不了');
  }
  final Object? snapshot = jsonDecode(await snapshotFile.readAsString());
  if (snapshot is! Map || snapshot['lines'] is! List) {
    return const OpUndoOutcome.failed('撤销备份读不出来');
  }
  if (snapshot['reverted'] == true) {
    return const OpUndoOutcome.superseded('这次操作已经撤销过');
  }

  final TtsRenderQueue queue = deps.renderQueue();
  final TtsRenderJob? job = queue.latestFor(bookKey);
  if (job != null && !job.isTerminal) {
    if (job.id != snapshot['job']) {
      return const OpUndoOutcome.failed('这一卷正在生成，结束后再撤销');
    }
    await queue.cancel(job.id);
    if (!await _settled(queue, bookKey)) {
      return const OpUndoOutcome.failed('已取消批量重生成，等它停下后再撤销一次');
    }
  }

  final File manifestFile = mangaRenderManifestFile(appModel, bookKey);
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  if (manifest == null) {
    return const OpUndoOutcome.superseded('这一卷的成品清单已经不在了，没有覆盖');
  }
  final MangaAudioScriptStore scripts = mangaAudioScriptStoreFor(appModel);
  final MangaAudioScript script = await scripts.load(bookKey);
  final CastVoicingStore voicing = ttsVoicingStoreFor(appModel);
  final CastVoicingLedger ledger = await voicing.load(bookKey);
  final String audioDir = manifestFile.parent.path;

  final List<String> restored = <String>[];
  int superseded = 0;
  int lost = 0;
  bool stopped = false;
  for (final Object? raw in snapshot['lines']! as List) {
    if (raw is! Map) continue;
    final String id = '${raw['id']}';
    final MangaRenderedLine? old = MangaRenderedLine.fromJson(raw['oldLine']);
    final MangaRenderedLine? current = _renderedLine(manifest, id);
    if (old == null || current == null) {
      superseded++;
      continue;
    }
    final Object? expectFile = raw['expectFile'];
    final Object? expectSeed = raw['expectSeed'];
    final bool applied = expectFile is String
        ? current.file == expectFile
        : expectSeed is int &&
              current.seed == expectSeed &&
              current.file == mangaCandidateFileName(id, expectSeed);
    if (!applied) {
      // 这次没改到它（重生成失败保留了旧音频 / 取消时还没轮到）：不算被改过。
      if (current.file != old.file || current.seed != old.seed) superseded++;
      continue;
    }
    final Object? backup = raw['backup'];
    final File? backupFile = backup is String
        ? File(p.join(dir.path, backup))
        : null;
    if (backupFile == null || !await backupFile.exists()) {
      lost++;
      continue;
    }
    if (!stopped) {
      await deps.stopPlayback(<String>[bookKey]);
      stopped = true;
    }
    await backupFile.copy(p.join(audioDir, old.file));
    final MangaScriptLine? oldScript = MangaScriptLine.fromJson(
      raw['oldScriptLine'],
    );
    if (oldScript?.audio case final MangaLocalAudio audio) {
      final Object? local = raw['localBackup'];
      final File target = File(mangaLocalAudioSourcePath(audioDir, audio));
      if (local is String && !await target.exists()) {
        await target.parent.create(recursive: true);
        await File(p.join(dir.path, local)).copy(target.path);
      }
    }
    manifest.replaceLine(id, (MangaRenderedLine _) => old);
    final MangaScriptLine? now = script.lineById(id);
    final bool scriptApplied =
        now != null &&
        (expectFile is String
            ? now.audio is MangaLocalAudio &&
                  mangaLocalLineFileName(id, now.audio as MangaLocalAudio) ==
                      expectFile
            : now.seed == expectSeed);
    if (oldScript != null && scriptApplied) {
      script.replaceLine(id, (MangaScriptLine _) => oldScript);
    }
    final CastVoicingEntry? entry = CastVoicingEntry.fromJson(
      raw['ledgerEntry'],
    );
    if (entry != null) ledger.entries[id] = entry;
    restored.add(id);
  }

  if (restored.isNotEmpty) {
    await manifest.save(manifestFile);
    await scripts.save(bookKey, script);
    await voicing.save(bookKey, ledger);
    await updateMangaAudioLines(
      appModel.database,
      bookKey: bookKey,
      manifestFile: manifestFile,
      manifest: manifest,
      lineIds: restored,
    );
    await MangaAudioRenderer(
      backend: const TtsCtlNoSynthesis(),
      manifestFile: manifestFile,
    ).sweepUnreferenced(manifest);
  }
  // 音频备份用完就删；快照留下并记上「已撤销」（再撤一次报 superseded，不误报备份
  // 被清理），整个目录由修剪按份数清掉。
  for (final FileSystemEntity e in dir.listSync()) {
    if (e is File && p.basename(e.path) != _kSnapshotFile) {
      await deleteMangaFileQuietly(e);
    }
  }
  await snapshotFile.writeAsString(
    jsonEncode(<Object?, Object?>{...snapshot, 'reverted': true}),
    flush: true,
  );

  if (restored.isEmpty) {
    if (lost > 0) return const OpUndoOutcome.failed('旧音频备份已清理，恢复不了');
    if (superseded > 0) {
      return const OpUndoOutcome.superseded('这些句子之后又被改过，没有覆盖');
    }
    return const OpUndoOutcome.done('这次操作没有改动任何句子');
  }
  if (superseded > 0 || lost > 0) {
    return OpUndoOutcome.partial(
      '恢复了 ${restored.length} 句；${superseded + lost} 句之后又被改过或备份已清理，没有覆盖',
    );
  }
  return const OpUndoOutcome.done();
}

/// 等 [bookKey] 的任务结束（取消后正在合成的那一句要先停下），最多 [_kCancelSettle]。
Future<bool> _settled(TtsRenderQueue queue, String bookKey) async {
  bool done() => queue.latestFor(bookKey)?.isTerminal ?? true;
  if (done()) return true;
  final Completer<void> finished = Completer<void>();
  void listener() {
    if (done() && !finished.isCompleted) finished.complete();
  }

  queue.addListener(listener);
  try {
    await finished.future.timeout(_kCancelSettle, onTimeout: () {});
  } finally {
    queue.removeListener(listener);
  }
  return done();
}
