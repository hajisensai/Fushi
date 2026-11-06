/// 纯音频改由音乐库收（用户 2026-11-06 拍板，反馈 QAondMh4M5）：视频侧的入口（视频
/// 来源扫描、视频页拖放、音频 CD 抓轨、旧版「无画面视频」存量迁移）扫到 / 收到纯音频
/// 时一律交到这里，这里**只做装配**——登记音乐来源或「仅此一次」导入，入库本身仍是
/// 音乐模块现有的那条路径（[SourceLibraryScanner] → `MusicLibraryScanner` → Rust
/// `native/fushi_music` 扫描），视频侧不另造一份音乐入库逻辑。
///
/// - 视频来源里的纯音频（[adoptVideoSourceAudio]）：按 `music_audio_roots.dart` 的规则
///   登记**常驻**音乐来源（之后增删由音乐来源自己的重扫对账）；已被音乐来源覆盖的目录
///   不重复登记；与视频同目录的音频（外挂音轨）不收。
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
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// 登记一个常驻音乐来源并扫描（真 app = [addLocalFolderAsSource]）。返回扫描错误摘要。
typedef MusicSourceRegistrar =
    Future<String?> Function({
      required String rootPath,
      required bool recursive,
    });

/// 「仅此一次」把一个音频文件导入曲库（真 app = [importLocalFolderOnceAt]）。返回扫描
/// 错误摘要。
typedef MusicFileImporter = Future<String?> Function(String path);

/// 重扫一个已有的音乐来源（真 app = [SourceLibraryScanner.scan]）。返回扫描错误摘要。
typedef MusicSourceRescanner =
    Future<String?> Function(SourceLibraryRow source);

/// 一次交接的结果。
class MusicAudioIntakeResult {
  const MusicAudioIntakeResult({
    this.registeredRoots = const <PlannedMusicRoot>[],
    this.importedFiles = const <String>[],
    this.rescannedSourceIds = const <int>[],
    this.skippedPaths = const <String>[],
    this.errors = const <String>[],
  });

  /// 新登记的常驻音乐来源。
  final List<PlannedMusicRoot> registeredRoots;

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
    bool Function(String path)? fileExists,
  }) : _registerSource = registerSource,
       _importFile = importFile,
       _rescanSource = rescanSource,
       _fileExists = fileExists ?? ((String path) => File(path).existsSync());

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
  final bool Function(String path) _fileExists;

  Future<String?> _register({
    required String rootPath,
    required bool recursive,
  }) async {
    final MusicSourceRegistrar? injected = _registerSource;
    if (injected != null) {
      return injected(rootPath: rootPath, recursive: recursive);
    }
    final AddLocalFolderResult r = await addLocalFolderAsSource(
      db: _db,
      mediaKind: SourceLibraryKind.music.dbValue,
      path: rootPath,
      recursive: recursive,
    );
    if (r.sourceId == null) return null;
    return (await _db.getMediaSourceById(r.sourceId!))?.lastScanError;
  }

  Future<String?> _import(String path) async {
    final MusicFileImporter? injected = _importFile;
    if (injected != null) return injected(path);
    final SourceScanSummary? summary = await importLocalFolderOnceAt(
      db: _db,
      mediaKind: SourceLibraryKind.music.dbValue,
      path: path,
      recursive: false,
    );
    return summary?.error;
  }

  Future<String?> _rescan(SourceLibraryRow source) async {
    final MusicSourceRescanner? injected = _rescanSource;
    if (injected != null) return injected(source);
    return (await SourceLibraryScanner(_db).scan(source)).error;
  }

  Future<List<SourceLibraryRow>> _localMusicSources() async =>
      <SourceLibraryRow>[
        for (final SourceLibraryRow s in await _db.getMediaSourcesByKind(
          SourceLibraryKind.music.dbValue,
        ))
          if (s.transport == 'local') s,
      ];

  /// 视频来源（本地，根 [videoRoot]）扫描时扫到的纯音频 [audioPaths] 交给音乐库。
  /// [videoMediaDirs] 是本次被视频库认领的媒体所在目录（视频 / 播放列表文件的父目录、
  /// 原盘根），用来判「与视频同目录」与「往上爬的边界」。
  Future<MusicAudioIntakeResult> adoptVideoSourceAudio({
    required String videoRoot,
    required List<String> audioPaths,
    required Iterable<String> videoMediaDirs,
  }) => _serial(
    () => _adopt(
      videoRoot: videoRoot,
      audioPaths: audioPaths,
      videoMediaDirs: videoMediaDirs.toList(),
    ),
  );

  Future<MusicAudioIntakeResult> _adopt({
    required String videoRoot,
    required List<String> audioPaths,
    required List<String> videoMediaDirs,
  }) async {
    final List<String> audio = <String>[
      for (final String a in audioPaths)
        if (isAudioOnlyMediaPath(a)) a,
    ];
    if (audio.isEmpty) return const MusicAudioIntakeResult();
    final MusicAudioRootPlan plan = planMusicRootsForVideoSourceAudio(
      videoRoot: videoRoot,
      audioPaths: audio,
      videoMediaDirs: videoMediaDirs,
      musicSources: <MusicSourceRoot>[
        for (final SourceLibraryRow s in await _localMusicSources())
          (rootPath: s.rootPath, recursive: s.recursive),
      ],
    );
    final List<String> errors = <String>[];
    for (final PlannedMusicRoot root in plan.roots) {
      final String? error = await _register(
        rootPath: root.rootPath,
        recursive: root.recursive,
      );
      if (error != null) errors.add('${root.rootPath}: $error');
    }
    return MusicAudioIntakeResult(
      registeredRoots: plan.roots,
      skippedPaths: plan.besideVideoAudioPaths,
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
