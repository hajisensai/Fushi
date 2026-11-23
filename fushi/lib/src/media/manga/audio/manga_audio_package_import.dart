/// 有声漫画导出包：导入与撤销（设计稿 §5）。
///
/// - [planMangaAudioPackageImport]：只读包清单（不解包）+ 本机库，逐卷决定怎么处理
///   （用本机已有的同一卷 / 作为新卷导入 / 冲突跳过），列出会替换的演出稿与成品、
///   本机缺的声音。`--dry-run` 与界面的导入预览就是它的结果；
/// - [runMangaAudioPackageImport]：解包到 `<db>/manga_audio/.pkg-<runId>/`（工作
///   isolate，可取消）→ 逐卷核对文件摘要 → 进入落库（之后不可取消）→ 逐卷：新卷走与
///   mokuro 导入同一个落库入口、演出稿经 `MangaAudioScriptStore` 写入、成品目录原子
///   挪到规范位置、走 [checkMangaAudioManifest] + [registerMangaAudio] 登记（与
///   `tts import` 同一套校验与登记）→ 系列在本机重建并合并 → 写撤销日志。某卷失败
///   只回滚这一卷，不影响其它卷；结果按卷列出；
/// - [revertMangaAudioPackageImport]：按撤销日志删掉这次新建的书与成品、放回被替换的
///   演出稿 / 成品目录 / 登记、系列档案放回导入前（导入之后又被改过的不覆盖）。
///
/// 撤销日志与被替换下来的旧文件在 `<db>/manga_audio/_undo/pkg-<runId>/`，只留最近
/// [kMangaPackageUndoKeep] 次。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' show sha1;
import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart'
    show deleteMediaCollectionWithAssets;
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart' show MangaStorage;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_package_export.dart'
    show MangaPackageBusyCheck;
import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart'
    show isLocalMangaVolume;
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';

/// 撤销日志只留最近这么多次导入。
const int kMangaPackageUndoKeep = 5;

/// 一卷打算怎么处理。
enum MangaPackageImportAction {
  /// 用本机已有的同一卷（不重复导入页图与 OCR）。
  useExisting,

  /// 作为新卷导入。
  create,

  /// 跳过（冲突且没选「作为新卷导入」）。
  skip,
}

/// 包里一卷的导入计划。
class MangaPackageImportVolumePlan {
  const MangaPackageImportVolumePlan({
    required this.volume,
    required this.match,
    required this.action,
    this.localTitle,
    this.replacesScript = false,
    this.replacesAudio = false,
    this.busy,
    this.missingVoices = const <String>[],
  });

  final MangaAudioPackageVolume volume;
  final MangaPackageVolumeMatch match;
  final MangaPackageImportAction action;

  /// 匹配上 / 冲突的本机卷的标题。
  final String? localTitle;

  /// 本机这一卷已有演出稿，导入会替换。
  final bool replacesScript;

  /// 本机这一卷已有有声成品（登记或成品目录），导入会替换。
  final bool replacesAudio;

  /// 本机这一卷有标注 / 生成任务在跑（不能导入）；null = 没有。
  final String? busy;

  /// 包里这卷用过、本机没有的声音（只影响之后「继续重配」，不拦导入）。
  final List<String> missingVoices;

  String? get bookKey => match.bookKey;

  bool get replaces => replacesScript || replacesAudio;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': volume.id,
    'title': volume.title,
    'pages': volume.pageCount,
    'action': action.name,
    'match': match.kind.name,
    if (match.conflict != null) 'conflict': match.conflict!.name,
    'bookKey': ?match.bookKey,
    'localTitle': ?localTitle,
    'hasAudio': volume.hasAudio,
    if (volume.activePart case final MangaAudioPackagePart part) ...{
      'lines': part.lines,
      'durationMs': part.durationMs,
    },
    'hasScript': volume.script != null,
    if (volume.scriptStale) 'scriptStale': true,
    if (replacesScript) 'replacesScript': true,
    if (replacesAudio) 'replacesAudio': true,
    'busy': ?busy,
    if (missingVoices.isNotEmpty) 'missingVoices': missingVoices,
    'bytes': volume.files.bytes,
  };
}

/// 整包的导入计划。
class MangaPackageImportPlan {
  const MangaPackageImportPlan({
    required this.packagePath,
    required this.manifest,
    required this.volumes,
  });

  final String packagePath;
  final MangaAudioPackageManifest manifest;
  final List<MangaPackageImportVolumePlan> volumes;

  /// 有会替换本机演出稿 / 成品的卷（要用户确认）。
  bool get needsConfirm => volumes.any(
    (MangaPackageImportVolumePlan v) =>
        v.action == MangaPackageImportAction.useExisting && v.replaces,
  );

  /// 有本机卷正在标注 / 生成。
  List<MangaPackageImportVolumePlan>
  get busyVolumes => <MangaPackageImportVolumePlan>[
    for (final MangaPackageImportVolumePlan v in volumes)
      if (v.action == MangaPackageImportAction.useExisting && v.busy != null) v,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'path': packagePath,
    'app': manifest.app,
    'createdAt': manifest.createdAt,
    'series': <Map<String, Object?>>[
      for (final MangaAudioPackageSeries s in manifest.series)
        <String, Object?>{'id': s.id, 'title': s.title, 'members': s.members},
    ],
    'volumes': <Map<String, Object?>>[
      for (final MangaPackageImportVolumePlan v in volumes) v.toJson(),
    ],
    'needsConfirm': needsConfirm,
  };
}

/// 读包清单（不解包）并逐卷定导入计划。[asNew] = 冲突卷一律作为新卷导入（否则跳过）。
/// [availableVoices] = 本机可选的声音 id（缺声音检查）。包不对抛
/// [MangaAudioPackageException]（`package_invalid` / `package_too_new`）。
Future<MangaPackageImportPlan> planMangaAudioPackageImport(
  AudioProductionHost host,
  String packagePath, {
  bool asNew = false,
  Set<String> availableVoices = const <String>{},
  MangaPackageBusyCheck? busy,
}) async {
  if (!await File(packagePath).exists()) {
    throw MangaAudioPackageException('not_found', '包文件不存在：$packagePath');
  }
  final MangaAudioPackageManifest manifest;
  try {
    manifest = await readMangaAudioPackageManifest(packagePath);
  } on MangaAudioPackageFormatException catch (e) {
    throw MangaAudioPackageException(
      e.code == 'too_new' ? 'package_too_new' : 'package_invalid',
      e.code == 'too_new'
          ? '这个包是更新版本的 Fushi 导出的，先升级再导入'
          : '不是有效的有声漫画包（${e.message}）',
    );
  }
  final List<MangaPackageLocalVolume> local = await _localVolumes(host, <int>{
    for (final MangaAudioPackageVolume v in manifest.volumes) v.pageCount,
  });
  final Map<String, String> titles = <String, String>{
    for (final MangaPackageLocalVolume l in local) l.bookKey: l.title,
  };
  final List<MangaPackageImportVolumePlan> plans =
      <MangaPackageImportVolumePlan>[];
  for (final MangaAudioPackageVolume volume in manifest.volumes) {
    final MangaPackageVolumeMatch match = matchMangaAudioPackageVolume(
      volume,
      local,
    );
    final MangaPackageImportAction action = switch (match.kind) {
      MangaPackageMatchKind.existing => MangaPackageImportAction.useExisting,
      MangaPackageMatchKind.create => MangaPackageImportAction.create,
      MangaPackageMatchKind.conflict =>
        asNew ? MangaPackageImportAction.create : MangaPackageImportAction.skip,
    };
    bool replacesScript = false;
    bool replacesAudio = false;
    String? busyReason;
    final String? existing = match.kind == MangaPackageMatchKind.existing
        ? match.bookKey
        : null;
    if (existing != null) {
      replacesScript =
          volume.script != null &&
          await mangaAudioScriptStoreFor(host).fileFor(existing).exists();
      if (volume.hasAudio) {
        final AudiobookRow? row = await host.database.getAudiobookByBookKey(
          existing,
        );
        replacesAudio =
            (row != null && audiobookRowHasRegistration(row)) ||
            (volume.audio != null &&
                await mangaRenderManifestFile(
                  host,
                  existing,
                ).parent.exists()) ||
            (volume.drama != null &&
                await mangaDramaManifestFile(host, existing).parent.exists());
      }
      busyReason = busy?.call(existing);
    }
    plans.add(
      MangaPackageImportVolumePlan(
        volume: volume,
        match: match,
        action: action,
        localTitle: match.bookKey == null ? null : titles[match.bookKey],
        replacesScript: replacesScript,
        replacesAudio: replacesAudio,
        busy: busyReason,
        missingVoices: <String>[
          for (final String voice in volume.voices)
            if (!availableVoices.contains(voice)) voice,
        ],
      ),
    );
  }
  return MangaPackageImportPlan(
    packagePath: packagePath,
    manifest: manifest,
    volumes: plans,
  );
}

/// 本机本地漫画卷里页数在 [pageCounts] 内的那些（读它们的 `manga.json` 算内容签名）。
Future<List<MangaPackageLocalVolume>> _localVolumes(
  AudioProductionHost host,
  Set<int> pageCounts,
) async {
  final List<MangaPackageLocalVolume> out = <MangaPackageLocalVolume>[];
  for (final EpubBookRow row in await host.database.getAllEpubBooks()) {
    if (!isLocalMangaVolume(row) || !pageCounts.contains(row.chapterCount)) {
      continue;
    }
    final MokuroPayload? payload = await _readPayload(
      File(p.join(row.extractDir, row.epubPath)),
    );
    if (payload == null) continue;
    out.add(
      MangaPackageLocalVolume(
        bookKey: row.bookKey,
        title: row.title,
        pageCount: payload.images.length,
        content: mangaPayloadContentSignature(payload),
      ),
    );
  }
  return out;
}

Future<MokuroPayload?> _readPayload(File mangaJson) async {
  if (!await mangaJson.exists()) return null;
  try {
    final String raw = await mangaJson.readAsString();
    return await Isolate.run(() => parseMangaJson(raw));
  } on Object {
    return null;
  }
}

/// 一卷的导入结局。
class _VolumeOutcome {
  _VolumeOutcome(this.plan);

  final MangaPackageImportVolumePlan plan;
  String status = 'skipped';
  String? code;
  String? reason;
  String? bookKey;
  bool created = false;
  bool scriptWritten = false;
  bool audioWritten = false;
  Map<String, Object?>? journal;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': plan.volume.id,
    'title': plan.volume.title,
    'status': status,
    'bookKey': ?bookKey,
    if (created) 'created': true,
    if (scriptWritten) 'script': true,
    if (audioWritten) ...{
      'lines': plan.volume.activePart?.lines ?? 0,
      'durationMs': plan.volume.activePart?.durationMs ?? 0,
    },
    if (scriptWritten && plan.replacesScript) 'replacedScript': true,
    if (audioWritten && plan.replacesAudio) 'replacedAudio': true,
    if (plan.volume.scriptStale) 'scriptStale': true,
    if (plan.missingVoices.isNotEmpty) 'missingVoices': plan.missingVoices,
    'code': ?code,
    'reason': ?reason,
  };
}

/// 撤销日志与旧文件备份目录。
Directory mangaPackageUndoDir(AudioProductionHost host, String runId) =>
    Directory(p.join(mangaAudioRoot(host).path, '_undo', 'pkg-$runId'));

/// 按 [plan] 导入。[onCommit] 在进入落库阶段时调一次（任务据此拒绝之后的取消）。
/// 解包阶段取消抛 [MangaAudioPackageCancelled]（暂存已删）。返回逐卷结果与 `runId`
/// （撤销用）。
Future<Map<String, Object?>> runMangaAudioPackageImport(
  AudioProductionHost host,
  MangaPackageImportPlan plan, {
  required String runId,
  MangaPackageBusyCheck? busy,
  void Function(String phase, double? progress)? onProgress,
  void Function()? onCommit,
  MangaPackageCancelToken? cancel,
}) async {
  final Directory staging = Directory(
    p.join(mangaAudioRoot(host).path, '.pkg-$runId'),
  );
  try {
    onProgress?.call('extracting', 0);
    final int total = await mangaAudioPackageUncompressedBytes(
      plan.packagePath,
    );
    int extracted = 0;
    await extractMangaAudioPackageZip(
      zipPath: plan.packagePath,
      outputDir: staging.path,
      cancel: cancel,
      onBytes: (int delta) {
        extracted += delta;
        onProgress?.call('extracting', total <= 0 ? null : extracted / total);
      },
    );
    cancel?.throwIfCancelled();

    final List<_VolumeOutcome> outcomes = <_VolumeOutcome>[
      for (final MangaPackageImportVolumePlan v in plan.volumes)
        _VolumeOutcome(v),
    ];
    onProgress?.call('verifying', null);
    for (final _VolumeOutcome o in outcomes) {
      if (o.plan.action == MangaPackageImportAction.skip) {
        o
          ..code = 'conflict'
          ..reason = '本机同名卷的页数 / OCR 不一致';
        continue;
      }
      cancel?.throwIfCancelled();
      final String? problem = await _verifyVolumeFiles(staging, o.plan.volume);
      if (problem != null) {
        o
          ..status = 'failed'
          ..code = 'package_corrupt'
          ..reason = problem;
      }
    }
    cancel?.throwIfCancelled();

    onCommit?.call();
    final Directory undoDir = mangaPackageUndoDir(host, runId);
    await undoDir.create(recursive: true);
    final List<_VolumeOutcome> todo = <_VolumeOutcome>[
      for (final _VolumeOutcome o in outcomes)
        if (o.plan.action != MangaPackageImportAction.skip &&
            o.status != 'failed')
          o,
    ];
    final List<Map<String, Object?>> seriesJournal = <Map<String, Object?>>[];
    final List<Map<String, Object?>> seriesResult = <Map<String, Object?>>[];
    // 落库阶段一旦开始，不论后面哪一步抛出，撤销日志都要落盘：已经落库的卷、已经
    // 改过的系列 / 合集都得能撤（否则任务失败、日志没写，撤销只能报「记录不在」）。
    try {
      for (int i = 0; i < todo.length; i++) {
        onProgress?.call('importing', i / todo.length);
        await _importVolume(host, staging, undoDir, todo[i], busy);
      }
      onProgress?.call('importing', 1);
      for (final MangaAudioPackageSeries series in plan.manifest.series) {
        final Map<String, Object?>? entry = await _importSeries(
          host,
          staging,
          series,
          outcomes,
          seriesJournal,
        );
        if (entry == null) continue;
        seriesResult.add(<String, Object?>{
          'id': series.id,
          'title': series.title,
          'seriesKey': entry['seriesKey'],
        });
      }
    } finally {
      final Map<String, Object?> journal = <String, Object?>{
        'v': 1,
        'runId': runId,
        'package': plan.packagePath,
        'volumes': <Map<String, Object?>>[
          for (final _VolumeOutcome o in outcomes)
            if (o.journal != null) o.journal!,
        ],
        'series': seriesJournal,
      };
      await File(
        p.join(undoDir.path, 'journal.json'),
      ).writeAsString(jsonEncode(journal), flush: true);
    }
    await _pruneUndoRuns(host, keep: runId);
    return <String, Object?>{
      'runId': runId,
      'path': plan.packagePath,
      'volumes': <Map<String, Object?>>[
        for (final _VolumeOutcome o in outcomes) o.toJson(),
      ],
      'series': seriesResult,
      'imported': outcomes
          .where((_VolumeOutcome o) => o.status == 'imported')
          .length,
      'failed': outcomes
          .where((_VolumeOutcome o) => o.status == 'failed')
          .length,
      'skipped': outcomes
          .where((_VolumeOutcome o) => o.status == 'skipped')
          .length,
    };
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

/// 核对一卷解出来的文件：数量、字节与整体摘要都要与包清单一致。不一致返回说明。
Future<String?> _verifyVolumeFiles(
  Directory staging,
  MangaAudioPackageVolume volume,
) async {
  final Directory dir = Directory(p.join(staging.path, 'volumes', volume.id));
  if (!await dir.exists()) return '包里没有这一卷的文件';
  final Map<String, String> digests = <String, String>{};
  int bytes = 0;
  await for (final FileSystemEntity e in dir.list(recursive: true)) {
    if (e is! File) continue;
    final String rel = p.posix.joinAll(
      p.split(p.relative(e.path, from: staging.path)),
    );
    digests[rel] = await ffcSha256File(e.path);
    bytes += await e.length();
  }
  if (digests.length != volume.files.count ||
      bytes != volume.files.bytes ||
      mangaAudioPackageFilesDigest(digests) != volume.files.sha256) {
    return '这一卷的文件与包清单对不上（包损坏或被改过）';
  }
  return null;
}

String _sha1Of(String text) => sha1.convert(utf8.encode(text)).toString();

/// 导入一卷；失败时只回滚这一卷已做的步骤，结局记进 [o]。
Future<void> _importVolume(
  AudioProductionHost host,
  Directory staging,
  Directory undoDir,
  _VolumeOutcome o,
  MangaPackageBusyCheck? busy,
) async {
  final MangaAudioPackageVolume volume = o.plan.volume;
  final FushiDatabase db = host.database;
  final String volumeDir = p.join(staging.path, 'volumes', volume.id);
  final Directory backup = Directory(p.join(undoDir.path, volume.id));
  final List<Future<void> Function()> rollback = <Future<void> Function()>[];
  final Map<String, Object?> journal = <String, Object?>{'id': volume.id};
  try {
    final String bookKey;
    if (o.plan.action == MangaPackageImportAction.useExisting) {
      bookKey = o.plan.bookKey!;
      final String? busyReason = busy?.call(bookKey);
      if (busyReason != null) {
        throw MangaAudioPackageException('busy', busyReason);
      }
    } else {
      bookKey = await MangaImporter.importFromMangaJson(
        db: db,
        mangaJsonPath: p.join(volumeDir, 'manga.json'),
        imageRootPath: p.join(volumeDir, 'pages'),
        title: volume.title.trim().isEmpty ? null : volume.title.trim(),
        pageSource: MangaPageSource.disposable,
      );
      o.created = true;
      rollback.add(() => _deleteCreatedBook(db, bookKey));
      final EpubBookRow? row = await db.getEpubBook(bookKey);
      final MokuroPayload? payload = row == null
          ? null
          : await _readPayload(File(p.join(row.extractDir, row.epubPath)));
      if (payload == null ||
          payload.images.length != volume.pageCount ||
          mangaPayloadContentSignature(payload) != volume.content) {
        throw const MangaAudioPackageException(
          'content_mismatch',
          '导入后的页数 / OCR 与包清单不一致',
        );
      }
    }
    o.bookKey = bookKey;
    journal
      ..['bookKey'] = bookKey
      ..['created'] = o.created;

    // 演出稿：经店写入（同一卷的读写串行、打开着的会话能察觉被别处存过）。
    final String? scriptRel = volume.script;
    if (scriptRel != null) {
      final MangaAudioScriptStore store = mangaAudioScriptStoreFor(host);
      final File target = store.fileFor(bookKey);
      final File? previous = await target.exists() ? target : null;
      if (previous != null) {
        await backup.create(recursive: true);
        await previous.copy(p.join(backup.path, 'script.json'));
      }
      final Object? raw = jsonDecode(
        await File(p.join(staging.path, scriptRel)).readAsString(),
      );
      await store.save(bookKey, MangaAudioScript.fromJson(raw));
      o.scriptWritten = true;
      journal
        ..['script'] = target.path
        ..['scriptBackup'] = previous == null
            ? null
            : p.join(backup.path, 'script.json')
        ..['scriptSha1'] = _sha1Of(await target.readAsString());
      rollback.add(
        () => _restoreScript(
          target,
          previous == null ? null : File(p.join(backup.path, 'script.json')),
        ),
      );
    }

    // 成品：整个目录挪到规范位置（清单内容不改，`f` 本来就相对清单目录）。
    final Map<String, Object?> dirs = <String, Object?>{};
    for (final (String name, MangaAudioPackagePart? part, File manifest)
        in <(String, MangaAudioPackagePart?, File)>[
          ('audio', volume.audio, mangaRenderManifestFile(host, bookKey)),
          ('drama', volume.drama, mangaDramaManifestFile(host, bookKey)),
        ]) {
      if (part == null) continue;
      final Directory target = manifest.parent;
      final Directory source = Directory(p.join(staging.path, part.dir));
      String? moved;
      if (await target.exists()) {
        await backup.create(recursive: true);
        moved = p.join(backup.path, '$name-previous');
        await target.rename(moved);
      }
      await target.parent.create(recursive: true);
      await source.rename(target.path);
      dirs[name] = <String, Object?>{'dir': target.path, 'backup': moved};
      rollback.add(() => _restoreDir(target, moved));
    }
    journal['dirs'] = dirs;

    final MangaAudioPackagePart? active = volume.activePart;
    if (active != null) {
      final File manifestFile = identical(active, volume.drama)
          ? mangaDramaManifestFile(host, bookKey)
          : mangaRenderManifestFile(host, bookKey);
      final Map<String, Object?> before = await captureAudiobookRegistration(
        db,
        bookKey,
      );
      final MangaAudioManifestCheck check = await checkMangaAudioManifest(
        db,
        bookKey: bookKey,
        manifestFile: manifestFile,
      );
      if (!check.ok) {
        throw MangaAudioPackageException(
          'audio_invalid',
          '成品清单校验没过（${check.failure!.name}）',
          details: check.missingFiles,
        );
      }
      await host.audiobookSession.stopIfPlayingAny(<String>[bookKey]);
      await registerMangaAudio(
        db,
        bookKey: bookKey,
        manifestFile: manifestFile,
        manifest: check.manifest!,
      );
      rollback.add(() => restoreAudiobookRegistration(db, bookKey, before));
      o.audioWritten = true;
      journal
        ..['registrationBefore'] = before
        ..['revision'] = await audiobookRegistrationRevision(db, bookKey);
    }
    o.status = 'imported';
    o.journal = journal;
  } on Object catch (e) {
    for (final Future<void> Function() undo in rollback.reversed) {
      try {
        await undo();
      } on Object catch (rollbackError) {
        o.reason = '${o.reason ?? ''}（回滚未完成：$rollbackError）';
      }
    }
    o
      ..status = 'failed'
      ..created = false
      ..scriptWritten = false
      ..audioWritten = false
      ..code = e is MangaAudioPackageException ? e.code : 'internal'
      ..reason = e is MangaAudioPackageException ? e.message : '$e';
  }
}

/// 回滚 / 撤销时删掉这次新建的书（库行 + 书目录）。
Future<void> _deleteCreatedBook(FushiDatabase db, String bookKey) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) return;
  await db.deleteEpubBook(bookKey);
  await MangaStorage.deleteBookDir(row.extractDir);
}

Future<void> _restoreScript(File target, File? backup) async {
  if (backup != null && await backup.exists()) {
    await backup.copy(target.path);
  } else if (await target.exists()) {
    await target.delete();
  }
}

Future<void> _restoreDir(Directory target, String? backup) async {
  if (await target.exists()) await target.delete(recursive: true);
  if (backup != null && await Directory(backup).exists()) {
    await Directory(backup).rename(target.path);
  }
}

/// 系列在本机重建：成员卷里已在本机某系列里的，用那个系列；否则以系列名建（或复用
/// 同名）合集，身份 `collection:<id>`。还不属于任何系列的成员卷进合集（显式关联的
/// 系列写 `series-links.json`），档案按 [mergeImportedSeriesProfile] 合并、成员按包里
/// 顺序并入。返回撤销日志条目；没有导入成功的成员卷返回 null。
Future<Map<String, Object?>?> _importSeries(
  AudioProductionHost host,
  Directory staging,
  MangaAudioPackageSeries series,
  List<_VolumeOutcome> outcomes,
  List<Map<String, Object?>> journal,
) async {
  final List<_VolumeOutcome> members = <_VolumeOutcome>[];
  for (final String id in series.members) {
    for (final _VolumeOutcome o in outcomes) {
      if (o.plan.volume.id == id && o.status == 'imported') members.add(o);
    }
  }
  if (members.isEmpty) return null;
  final File file = File(p.join(staging.path, series.file));
  SeriesCastProfile? incoming;
  if (await file.exists()) {
    try {
      incoming = SeriesCastProfile.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FormatException {
      incoming = null;
    }
  }
  final FushiDatabase db = host.database;
  final SeriesCastStore store = seriesCastStoreFor(host);
  String? seriesKey;
  for (final _VolumeOutcome o in members) {
    if (o.created) continue;
    seriesKey = await resolveSeriesKey(host, o.bookKey!);
    if (seriesKey != null) break;
  }
  final List<Map<String, Object?>> collectionAdds = <Map<String, Object?>>[];
  final List<String> linksAdded = <String>[];
  // 日志条目先登记、再逐步改：中途抛出时已做的那几步（建合集、进合集、关联）照样能撤。
  final Map<String, Object?> entry = <String, Object?>{
    'members': <String>[for (final _VolumeOutcome o in members) o.bookKey!],
    'collectionAdds': collectionAdds,
    'linksAdded': linksAdded,
  };
  journal.add(entry);
  if (seriesKey == null) {
    final String name = series.title.trim().isNotEmpty
        ? series.title.trim()
        : members.first.plan.volume.title.trim();
    final bool existed =
        await db.getMediaCollectionByNaturalKey(name, 'collection') != null;
    final int id = await db.createMediaCollection(name);
    if (!existed) entry['createdCollection'] = id;
    seriesKey = '$kSeriesKeyCollectionPrefix$id';
  }
  entry['seriesKey'] = seriesKey;
  final int? collection = seriesCollectionId(seriesKey);
  for (final _VolumeOutcome o in members) {
    final String bookKey = o.bookKey!;
    if (await resolveSeriesKey(host, bookKey) != null) continue;
    if (collection != null) {
      final EpubBookRow? row = await db.getEpubBook(bookKey);
      if (row == null) continue;
      final String entryKey = row.uid.isNotEmpty ? row.uid : bookKey;
      await db.addToCollection(collection, MediaKind.epub, entryKey);
      collectionAdds.add(<String, Object?>{
        'collection': collection,
        'entryKey': entryKey,
        'bookKey': bookKey,
      });
    } else {
      await store.link(bookKey, seriesKey);
      linksAdded.add(bookKey);
    }
  }
  entry['before'] = (await store.load(seriesKey)).toJson();
  final SeriesCastProfile after = await store.update(seriesKey, (
    SeriesCastProfile profile,
  ) {
    if (incoming != null) mergeImportedSeriesProfile(profile, incoming);
    mergeSeriesMemberOrder(profile.members, <String>[
      for (final _VolumeOutcome o in members) o.bookKey!,
    ]);
  });
  entry['after'] = after.toJson();
  return entry;
}

Future<void> _pruneUndoRuns(
  AudioProductionHost host, {
  required String keep,
}) async {
  final Directory root = Directory(p.join(mangaAudioRoot(host).path, '_undo'));
  if (!await root.exists()) return;
  final List<Directory> runs = <Directory>[
    await for (final FileSystemEntity e in root.list())
      if (e is Directory && p.basename(e.path).startsWith('pkg-')) e,
  ];
  if (runs.length <= kMangaPackageUndoKeep) return;
  final List<(Directory, DateTime)> dated =
      <(Directory, DateTime)>[
        for (final Directory d in runs) (d, (await d.stat()).modified),
      ]..sort(
        ((Directory, DateTime) a, (Directory, DateTime) b) =>
            a.$2.compareTo(b.$2),
      );
  for (int i = 0; i < dated.length - kMangaPackageUndoKeep; i++) {
    final Directory d = dated[i].$1;
    if (p.basename(d.path) == 'pkg-$keep') continue;
    await d.delete(recursive: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// 撤销
// ─────────────────────────────────────────────────────────────────────────

/// 撤销结论：`done` / `partial`（有卷 / 系列在导入之后又被改过，没覆盖）/
/// `superseded`（全都被改过或日志已不在）/ `failed`。
typedef MangaPackageUndoResult = ({String status, String message});

Map<String, Object?> _withoutUpdated(Map<String, Object?> json) =>
    Map<String, Object?>.of(json)..remove('updated');

/// 按 [runId] 的撤销日志撤销一次导入。[busy] 判本机卷是否在标注 / 生成。
Future<MangaPackageUndoResult> revertMangaAudioPackageImport(
  AudioProductionHost host,
  String runId, {
  MangaPackageBusyCheck? busy,
}) async {
  final Directory undoDir = mangaPackageUndoDir(host, runId);
  final File journalFile = File(p.join(undoDir.path, 'journal.json'));
  if (!await journalFile.exists()) {
    return (status: 'superseded', message: '这次导入的撤销记录已不在（已撤销或已清理）');
  }
  final Object? raw = jsonDecode(await journalFile.readAsString());
  if (raw is! Map) {
    return (status: 'failed', message: '撤销记录读不出来');
  }
  final List<Map<String, Object?>> volumes = <Map<String, Object?>>[
    if (raw['volumes'] is List)
      for (final Object? v in raw['volumes']! as List<Object?>)
        if (v is Map) Map<String, Object?>.from(v),
  ];
  for (final Map<String, Object?> v in volumes) {
    final String? reason = busy?.call('${v['bookKey']}');
    if (reason != null) return (status: 'failed', message: reason);
  }
  final FushiDatabase db = host.database;
  final SeriesCastStore store = seriesCastStoreFor(host);
  final List<String> kept = <String>[];
  final Set<String> keptVolumes = <String>{};
  final Set<String> deletedVolumes = <String>{};
  int undone = 0;

  for (final Map<String, Object?> v in volumes.reversed) {
    final String bookKey = '${v['bookKey']}';
    final Object? revision = v['revision'];
    if (revision != null &&
        await audiobookRegistrationRevision(db, bookKey) != revision) {
      kept.add(bookKey);
      keptVolumes.add(bookKey);
      continue;
    }
    final Object? script = v['script'];
    if (script is String &&
        await File(script).exists() &&
        _sha1Of(await File(script).readAsString()) != v['scriptSha1']) {
      kept.add(bookKey);
      keptVolumes.add(bookKey);
      continue;
    }
    await host.audiobookSession.stopIfPlayingAny(<String>[bookKey]);
    final Map<String, Object?> dirs = v['dirs'] is Map
        ? Map<String, Object?>.from(v['dirs']! as Map)
        : const <String, Object?>{};
    if (v['created'] == true) {
      await _deleteCreatedBook(db, bookKey);
      deletedVolumes.add(bookKey);
      for (final Object? d in dirs.values) {
        if (d is! Map) continue;
        final Directory dir = Directory('${d['dir']}');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      if (script is String && await File(script).exists()) {
        await File(script).delete();
      }
    } else {
      if (script is String) {
        final Object? backup = v['scriptBackup'];
        await _restoreScript(
          File(script),
          backup is String ? File(backup) : null,
        );
      }
      for (final Object? d in dirs.values) {
        if (d is! Map) continue;
        await _restoreDir(
          Directory('${d['dir']}'),
          d['backup'] is String ? d['backup']! as String : null,
        );
      }
      final Object? before = v['registrationBefore'];
      if (before is Map) {
        await restoreAudiobookRegistration(
          db,
          bookKey,
          Map<String, Object?>.from(before),
        );
      }
    }
    undone++;
  }

  final List<Map<String, Object?>> series = <Map<String, Object?>>[
    if (raw['series'] is List)
      for (final Object? s in raw['series']! as List<Object?>)
        if (s is Map) Map<String, Object?>.from(s),
  ];
  // 系列在卷之后撤：留下没撤的卷（导入之后又被改过）还要待在原来的系列 / 合集里，
  // 这样的系列档案也不放回导入前（放回会把这些卷从成员里抹掉），只摘掉已撤卷的成员。
  for (final Map<String, Object?> s in series.reversed) {
    final Object? rawKey = s['seriesKey'];
    final String? seriesKey = rawKey is String ? rawKey : null;
    final bool keepsMember = <Object?>[
      ...?(s['members'] as List<Object?>?),
    ].any((Object? k) => keptVolumes.contains('$k'));
    final Object? before = s['before'];
    final Object? after = s['after'];
    if (seriesKey != null && after is Map) {
      final SeriesCastProfile current = await store.load(seriesKey);
      final bool untouched =
          jsonEncode(_withoutUpdated(current.toJson())) ==
          jsonEncode(_withoutUpdated(Map<String, Object?>.from(after)));
      final SeriesCastProfile? previous = SeriesCastProfile.fromJson(before);
      if (untouched && !keepsMember && previous != null) {
        await store.update(seriesKey, (SeriesCastProfile profile) {
          _replaceProfile(profile, previous);
        });
      } else {
        if (!untouched) kept.add(seriesKey);
        if (deletedVolumes.isNotEmpty) {
          await store.update(seriesKey, (SeriesCastProfile profile) {
            profile.members.removeWhere(deletedVolumes.contains);
          });
        }
      }
    }
    for (final Object? add
        in (s['collectionAdds'] as List<Object?>?) ?? const <Object?>[]) {
      if (add is! Map || keptVolumes.contains('${add['bookKey']}')) continue;
      await db.removeFromCollection(
        (add['collection']! as num).toInt(),
        MediaKind.epub,
        '${add['entryKey']}',
      );
    }
    for (final Object? k
        in (s['linksAdded'] as List<Object?>?) ?? const <Object?>[]) {
      if (keptVolumes.contains('$k')) continue;
      await store.link('$k', null);
    }
    final Object? created = s['createdCollection'];
    if (created is num &&
        (await db.getCollectionItems(created.toInt())).isEmpty) {
      await deleteMediaCollectionWithAssets(db, created.toInt());
    }
  }

  await undoDir.delete(recursive: true);
  if (kept.isEmpty) {
    return (status: 'done', message: '已撤销 $undone 卷');
  }
  return (
    status: undone == 0 && volumes.isNotEmpty ? 'superseded' : 'partial',
    message: '导入之后又被改过、没有覆盖：${kept.join('、')}',
  );
}

void _replaceProfile(SeriesCastProfile target, SeriesCastProfile source) {
  target.roster
    ..clear()
    ..addAll(source.roster);
  target.voices
    ..defaultVoice = source.voices.defaultVoice
    ..narrationVoice = source.voices.narrationVoice;
  target.voices.byCharacter
    ..clear()
    ..addAll(source.voices.byCharacter);
  target.voices.byCharacterKind
    ..clear()
    ..addAll(source.voices.byCharacterKind);
  target.voices.retryVoices
    ..clear()
    ..addAll(source.voices.retryVoices);
  target.members
    ..clear()
    ..addAll(source.members);
  target.substitutions
    ..clear()
    ..addAll(source.substitutions);
  target
    ..defaultSeed = source.defaultSeed
    ..title = source.title;
}
