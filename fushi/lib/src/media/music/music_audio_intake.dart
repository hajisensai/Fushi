/// 纯音频改由音乐库收（用户 2026-11-06 拍板，反馈 QAondMh4M5）：视频侧的入口（视频
/// 来源扫描、视频页拖放、音频 CD 抓轨、旧版「无画面视频」存量迁移）扫到 / 收到纯音频
/// 时一律交到这里，这里**只做装配**——登记音乐来源或「仅此一次」导入，入库本身仍是
/// 音乐模块现有的那条路径（[SourceLibraryScanner] → `MusicLibraryScanner` → Rust
/// `native/fushi_music` 扫描），视频侧不另造一份音乐入库逻辑。
///
/// - 视频来源里的纯音频（[adoptVideoSourceAudio]）：按 `music_audio_roots.dart` 的规则
///   登记**常驻**音乐来源（之后增删由音乐来源自己的重扫对账）；已被音乐来源覆盖的目录
///   不重复登记；与视频同目录的音频（外挂音轨）不收。登记的来源记下归属（v145
///   `auto_owner_source_id`）：视频来源扫描完整成功后按正面证据撤掉不再成立的自动来源
///   （[ownedMusicRootsToRetire]），删视频来源时连带移除（`removeSourceLibrary`），用户
///   单独删掉的不再登记回来（`music_auto_source_dismissals`）。
/// - 指名的几个文件（[importAudioFiles]）：已被音乐来源覆盖的，重扫那个来源；其余逐个
///   「仅此一次」导入（Rust 扫描器接受单文件根，只收这一个文件），不登记常驻来源。
///
/// 只收本地文件：音乐来源只支持本地目录（`_scanMusicSource`），网络视频来源里的纯音频
/// 不进视频库、也进不了音乐库。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_removal.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// 登记一个常驻音乐来源并扫描（真 app = [addLocalFolderAsSource]，记下 owner 视频来源
/// [ownerSourceId]）。返回扫描错误摘要。
typedef MusicSourceRegistrar =
    Future<String?> Function({
      required String rootPath,
      required bool recursive,
      required int ownerSourceId,
    });

/// 「仅此一次」把一个音频文件 / 目录导入曲库（真 app = [importLocalFolderOnceAt]）。
/// 返回扫描错误摘要。
typedef MusicFileImporter =
    Future<String?> Function(String path, {bool recursive});

/// 重扫一个已有的音乐来源（真 app = [SourceLibraryScanner.scan]）。返回扫描错误摘要。
typedef MusicSourceRescanner =
    Future<String?> Function(SourceLibraryRow source);

/// 撤掉一组自动登记的音乐来源（真 app = [retireMusicSources]）。
typedef MusicSourceRetirer = Future<void> Function(Set<int> sourceIds);

/// 一次交接的结果。
class MusicAudioIntakeResult {
  const MusicAudioIntakeResult({
    this.registeredRoots = const <PlannedMusicRoot>[],
    this.retiredSourceIds = const <int, OwnedMusicRootRetireReason>{},
    this.updatedSourceIds = const <int>[],
    this.importedFiles = const <String>[],
    this.rescannedSourceIds = const <int>[],
    this.skippedPaths = const <String>[],
    this.errors = const <String>[],
  });

  /// 新登记的常驻音乐来源（「仅此一次」交接时是一次性导入的目录）。
  final List<PlannedMusicRoot> registeredRoots;

  /// 对账时撤掉的自动来源（id → 原因）。
  final Map<int, OwnedMusicRootRetireReason> retiredSourceIds;

  /// 对账时改了「含子文件夹」并重扫的自动来源。
  final List<int> updatedSourceIds;

  /// 逐个「仅此一次」导入的文件。
  final List<String> importedFiles;

  /// 因为覆盖了交来的文件而重扫的音乐来源。
  final List<int> rescannedSourceIds;

  /// 没收的（不是本地纯音频、与视频同目录）。
  final List<String> skippedPaths;

  /// 扫描错误摘要（每个来源 / 文件一条）。
  final List<String> errors;

  /// 交来的文件里有多少被送进了音乐库的扫描。
  bool get handedOver =>
      registeredRoots.isNotEmpty ||
      importedFiles.isNotEmpty ||
      rescannedSourceIds.isNotEmpty;
}

class MusicAudioIntake {
  MusicAudioIntake(
    this._db, {
    MusicSourceRegistrar? registerSource,
    MusicFileImporter? importFile,
    MusicSourceRescanner? rescanSource,
    MusicSourceRetirer? retireSources,
    bool Function(String path)? fileExists,
    bool Function(String path)? dirExists,
  }) : _registerSource = registerSource,
       _importFile = importFile,
       _rescanSource = rescanSource,
       _retireSources = retireSources,
       _fileExists = fileExists ?? ((String path) => File(path).existsSync()),
       _dirExists =
           dirExists ?? ((String path) => Directory(path).existsSync());

  /// 所有交接串行执行：视频来源扫描与启动时的存量迁移可能同时想登记同一个目录，
  /// 「查重 → 插入」不串行就会插出两条一样的音乐来源。
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() body) {
    final Future<T> run = _tail.then((_) => body());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  final FushiDatabase _db;
  final MusicSourceRegistrar? _registerSource;
  final MusicFileImporter? _importFile;
  final MusicSourceRescanner? _rescanSource;
  final MusicSourceRetirer? _retireSources;
  final bool Function(String path) _fileExists;
  final bool Function(String path) _dirExists;

  Future<String?> _register({
    required String rootPath,
    required bool recursive,
    required int ownerSourceId,
  }) async {
    final MusicSourceRegistrar? injected = _registerSource;
    if (injected != null) {
      return injected(
        rootPath: rootPath,
        recursive: recursive,
        ownerSourceId: ownerSourceId,
      );
    }
    final AddLocalFolderResult r = await addLocalFolderAsSource(
      db: _db,
      mediaKind: SourceLibraryKind.music.dbValue,
      path: rootPath,
      recursive: recursive,
      autoOwnerSourceId: ownerSourceId,
    );
    if (r.outcome != AddLocalFolderOutcome.added || r.sourceId == null) {
      return null;
    }
    return (await _db.getMediaSourceById(r.sourceId!))?.lastScanError;
  }

  Future<String?> _import(String path, {bool recursive = false}) async {
    final MusicFileImporter? injected = _importFile;
    if (injected != null) return injected(path, recursive: recursive);
    final SourceScanSummary? summary = await importLocalFolderOnceAt(
      db: _db,
      mediaKind: SourceLibraryKind.music.dbValue,
      path: path,
      recursive: recursive,
    );
    return summary?.error;
  }

  Future<String?> _rescan(SourceLibraryRow source) async {
    final MusicSourceRescanner? injected = _rescanSource;
    if (injected != null) return injected(source);
    return (await SourceLibraryScanner(_db).scan(source)).error;
  }

  Future<void> _retire(Set<int> ids) async {
    if (ids.isEmpty) return;
    final MusicSourceRetirer? injected = _retireSources;
    if (injected != null) return injected(ids);
    await retireMusicSources(database: _db, sourceIds: ids);
  }

  Future<List<SourceLibraryRow>> _localMusicSources() async =>
      <SourceLibraryRow>[
        for (final SourceLibraryRow s in await _db.getMediaSourcesByKind(
          SourceLibraryKind.music.dbValue,
        ))
          if (s.transport == 'local') s,
      ];

  /// 视频来源 [owner]（本地）扫描时扫到的纯音频 [audioPaths] 交给音乐库。
  /// [videoMediaDirs] 是本次被视频库认领的媒体所在目录（视频 / 播放列表文件的父目录、
  /// 原盘根），用来判「与视频同目录」与「往上爬的边界」；[videoFilePaths] 是其中的视频
  /// 文件本身，用来认子目录里的外挂音轨（`Show/Audio/ep01.jpn.mka`，见
  /// `music_audio_roots.dart` 规则 2b）。
  ///
  /// - 规划（[planMusicRootsForVideoSourceAudio]）：别的音乐来源（手动、别的视频来源
  ///   登记的）算覆盖；本视频来源自己登记过的不算（否则规划永远是空，也就没法对账）；
  ///   用户删掉过的（「不再登记」清单）按递归来源算覆盖。
  /// - 规划出、还没登记的根：登记并记下 owner；已登记但「含子文件夹」变了的：改了重扫。
  /// - [reconcile]：调用方保证这次是**完整成功**的扫描（[audioPaths] / [videoMediaDirs]
  ///   是视频根下的全貌，哪怕一个纯音频都没有）时才撤掉不再成立的自动来源
  ///   （[ownedMusicRootsToRetire]，只凭正面证据）。存量迁移只交来几个文件，不对账。
  /// - [oneShot]：owner 是「导入文件夹（仅此一次）」的临时行，扫完就删：规划出的根改为
  ///   「仅此一次」导入，不登记常驻来源（否则留下 owner 已不存在的孤儿来源）。
  Future<MusicAudioIntakeResult> adoptVideoSourceAudio({
    required SourceLibraryRow owner,
    required List<String> audioPaths,
    required Iterable<String> videoMediaDirs,
    Iterable<String> videoFilePaths = const <String>[],
    bool reconcile = false,
    bool oneShot = false,
  }) => _serial(
    () => _adopt(
      owner: owner,
      audioPaths: audioPaths,
      videoMediaDirs: videoMediaDirs.toList(),
      videoFilePaths: videoFilePaths.toList(),
      reconcile: reconcile && !oneShot,
      oneShot: oneShot,
    ),
  );

  Future<MusicAudioIntakeResult> _adopt({
    required SourceLibraryRow owner,
    required List<String> audioPaths,
    required List<String> videoMediaDirs,
    required List<String> videoFilePaths,
    required bool reconcile,
    required bool oneShot,
  }) async {
    final List<String> audio = <String>[
      for (final String a in audioPaths)
        if (isAudioOnlyMediaPath(a)) a,
    ];
    if (audio.isEmpty && !reconcile) return const MusicAudioIntakeResult();
    final List<SourceLibraryRow> music = await _localMusicSources();
    final Map<String, SourceLibraryRow> ownedByKey = <String, SourceLibraryRow>{
      for (final SourceLibraryRow s in music)
        if (s.autoOwnerSourceId == owner.id) musicTrackPathKey(s.rootPath): s,
    };
    final List<String> dismissed = oneShot
        ? const <String>[]
        : await _db.musicAutoSourceDismissalsOf(owner.id);
    final MusicAudioRootPlan plan = planMusicRootsForVideoSourceAudio(
      videoRoot: owner.rootPath,
      audioPaths: audio,
      videoMediaDirs: videoMediaDirs,
      videoFilePaths: videoFilePaths,
      musicSources: <MusicSourceRoot>[
        for (final SourceLibraryRow s in music)
          if (s.autoOwnerSourceId != owner.id)
            (rootPath: s.rootPath, recursive: s.recursive),
        for (final String d in dismissed) (rootPath: d, recursive: true),
      ],
    );
    final List<String> errors = <String>[];
    final List<PlannedMusicRoot> registered = <PlannedMusicRoot>[];
    final List<int> updated = <int>[];
    for (final PlannedMusicRoot root in plan.roots) {
      final SourceLibraryRow? mine =
          ownedByKey[musicTrackPathKey(root.rootPath)];
      if (mine != null) {
        if (mine.recursive != root.recursive) {
          await _db.updateMediaSourceRecursive(mine.id, root.recursive);
          final SourceLibraryRow? fresh = await _db.getMediaSourceById(mine.id);
          if (fresh != null) {
            final String? error = await _rescan(fresh);
            if (error != null) errors.add('${root.rootPath}: $error');
          }
          updated.add(mine.id);
        }
        continue;
      }
      final String? error = oneShot
          ? await _import(root.rootPath, recursive: root.recursive)
          : await _register(
              rootPath: root.rootPath,
              recursive: root.recursive,
              ownerSourceId: owner.id,
            );
      registered.add(root);
      if (error != null) errors.add('${root.rootPath}: $error');
    }
    Map<int, OwnedMusicRootRetireReason> retired =
        const <int, OwnedMusicRootRetireReason>{};
    if (reconcile) {
      // 新登记的来源也算进来：它可能覆盖了以前登记的下层来源。
      final List<SourceLibraryRow> now = await _localMusicSources();
      retired = ownedMusicRootsToRetire(
        videoRoot: owner.rootPath,
        owned: <OwnedMusicRoot>[
          for (final SourceLibraryRow s in now)
            if (s.autoOwnerSourceId == owner.id)
              (id: s.id, rootPath: s.rootPath, recursive: s.recursive),
        ],
        others: <MusicSourceRoot>[
          for (final SourceLibraryRow s in now)
            if (s.autoOwnerSourceId != owner.id)
              (rootPath: s.rootPath, recursive: s.recursive),
        ],
        videoMediaDirs: videoMediaDirs,
        dirExists: _dirExists,
      );
      await _retire(retired.keys.toSet());
    }
    return MusicAudioIntakeResult(
      registeredRoots: registered,
      retiredSourceIds: retired,
      updatedSourceIds: updated,
      skippedPaths: <String>[
        ...plan.besideVideoAudioPaths,
        ...plan.videoTrackAudioPaths,
      ],
      errors: errors,
    );
  }

  /// 指名的几个纯音频文件（视频页拖入、旧版存量迁移）收进曲库。
  ///
  /// 已被本地音乐来源覆盖（根 = 所在目录，或递归来源包含它）的，重扫覆盖它的来源——
  /// 文件可能是来源上次扫描之后才放进去的；同一个来源只扫一次。其余逐个「仅此一次」
  /// 导入。不是本地纯音频 / 文件不存在的，原样放进 [MusicAudioIntakeResult.skippedPaths]。
  Future<MusicAudioIntakeResult> importAudioFiles(Iterable<String> paths) =>
      _serial(() => _importFiles(paths.toList()));

  Future<MusicAudioIntakeResult> _importFiles(List<String> paths) async {
    final List<SourceLibraryRow> sources = await _localMusicSources();
    final Map<int, SourceLibraryRow> toRescan = <int, SourceLibraryRow>{};
    final List<String> toImport = <String>[];
    final List<String> skipped = <String>[];
    for (final String path in paths) {
      if (!isAudioOnlyMediaPath(path) ||
          !p.isAbsolute(path) ||
          !_fileExists(path)) {
        skipped.add(path);
        continue;
      }
      final String dir = p.dirname(path);
      SourceLibraryRow? cover;
      for (final SourceLibraryRow s in sources) {
        if (p.equals(s.rootPath, dir) ||
            (s.recursive && p.isWithin(s.rootPath, dir))) {
          cover = s;
          break;
        }
      }
      if (cover != null) {
        toRescan[cover.id] = cover;
      } else {
        toImport.add(path);
      }
    }
    final List<String> errors = <String>[];
    for (final SourceLibraryRow s in toRescan.values) {
      final String? error = await _rescan(s);
      if (error != null) errors.add('${s.rootPath}: $error');
    }
    for (final String path in toImport) {
      final String? error = await _import(path);
      if (error != null) errors.add('$path: $error');
    }
    return MusicAudioIntakeResult(
      importedFiles: toImport,
      rescannedSourceIds: toRescan.keys.toList(),
      skippedPaths: skipped,
      errors: errors,
    );
  }
}
