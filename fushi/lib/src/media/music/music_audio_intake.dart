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
/// - 网络视频来源（SFTP / WebDAV / AList）里的纯音频（[adoptRemoteVideoSourceAudio]）：同一套
///   规划规则（`p.url` 路径语义，条目与视频行同一命名空间），登记**同一台服务器上的**
///   常驻网络音乐来源（连接参数照抄视频来源、凭据复制一份到新来源名下），之后由音乐来源
///   自己的远程扫描对账。已被同一台服务器上的音乐来源覆盖的目录不重复登记——两个来源
///   重叠时同一首曲目（uid 含路径）会在两次扫描间来回换 `sourceId`、被对方软删。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_extensions.dart'
    show isAudioOnlyMediaPath;
import 'package:fushi_engine/media/music/music_audio_roots.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show Value;

import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/sftp_stream_source.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';

/// 登记一个常驻音乐来源并扫描（真 app = [addLocalFolderAsSource]）。返回扫描错误摘要。
typedef MusicSourceRegistrar =
    Future<String?> Function({
      required String rootPath,
      required bool recursive,
    });

/// 在视频来源 [videoSource] 所在的服务器上登记一个常驻网络音乐来源并扫描（真 app =
/// [MusicAudioIntake] 内部：照抄连接参数、复制凭据）。[rootPath] 是传输原生的来源根
/// （SFTP 远端路径 / WebDAV·AList 地址）。返回扫描错误摘要。
typedef RemoteMusicSourceRegistrar =
    Future<String?> Function({
      required SourceLibraryRow videoSource,
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
    RemoteMusicSourceRegistrar? registerRemoteSource,
    bool Function(String path)? fileExists,
  }) : _registerSource = registerSource,
       _registerRemoteSource = registerRemoteSource,
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
  final RemoteMusicSourceRegistrar? _registerRemoteSource;
  final bool Function(String path) _fileExists;

  Future<String?> _registerRemote({
    required SourceLibraryRow videoSource,
    required String rootPath,
    required bool recursive,
  }) async {
    final RemoteMusicSourceRegistrar? injected = _registerRemoteSource;
    if (injected != null) {
      return injected(
        videoSource: videoSource,
        rootPath: rootPath,
        recursive: recursive,
      );
    }
    final String root = normalizeSourceRootPath(
      rootPath,
      transport: videoSource.transport,
    );
    final List<SourceLibraryRow> existing = await _db.getMediaSourcesByKind(
      SourceLibraryKind.music.dbValue,
    );
    final int sortOrder = existing.isEmpty
        ? 0
        : existing
                  .map((SourceLibraryRow r) => r.sortOrder)
                  .reduce((int a, int b) => a > b ? a : b) +
              1;
    final int id = await _db.insertMediaSource(
      MediaSourcesCompanion(
        label: Value(
          defaultLabelFromRoot(root, transport: videoSource.transport),
        ),
        mediaKind: Value(SourceLibraryKind.music.dbValue),
        transport: Value(videoSource.transport),
        rootPath: Value(root),
        configJson: Value(videoSource.configJson),
        recursive: Value(recursive),
        sortOrder: Value(sortOrder),
        createdAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    // 凭据红线不变：只活在凭据存储里，按新来源 id 另存一份（不进 configJson）。
    final SourceLibraryCredentialStore secrets = SourceLibraryCredentialStore(
      _db,
    );
    final SourceLibrarySecret secret = await secrets.readSecret(videoSource.id);
    await secrets.saveSecret(
      id,
      password: secret.password,
      privateKey: secret.privateKey,
    );
    final SourceLibraryRow? fresh = await _db.getMediaSourceById(id);
    if (fresh == null) return null;
    return (await SourceLibraryScanner(_db).scan(fresh)).error;
  }

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

  /// 网络视频来源 [videoSource] 扫描时扫到的纯音频交给音乐库。[scanRoot] / [audioPaths] /
  /// [videoMediaDirs] 都是库内命名空间的地址（SFTP 为 `sftp://…`，与视频行同一口径）。
  Future<MusicAudioIntakeResult> adoptRemoteVideoSourceAudio({
    required SourceLibraryRow videoSource,
    required String scanRoot,
    required List<String> audioPaths,
    required Iterable<String> videoMediaDirs,
  }) => _serial(
    () => _adoptRemote(
      videoSource: videoSource,
      scanRoot: scanRoot,
      audioPaths: audioPaths,
      videoMediaDirs: videoMediaDirs.toList(),
    ),
  );

  Future<MusicAudioIntakeResult> _adoptRemote({
    required SourceLibraryRow videoSource,
    required String scanRoot,
    required List<String> audioPaths,
    required List<String> videoMediaDirs,
  }) async {
    final List<String> audio = <String>[
      for (final String a in audioPaths)
        if (isAudioOnlyMediaPath(a)) a,
    ];
    if (audio.isEmpty) return const MusicAudioIntakeResult();
    final Map<String, Object?> cfg = decodeSourceConfig(videoSource.configJson);
    final String? sftpRoot = videoSource.transport == 'sftp'
        ? sftpSourceUrlRootForConfig(cfg)
        : null;
    String namespaced(String nativeRoot) =>
        sftpRoot == null ? nativeRoot : sftpSourceUrlOf(nativeRoot, sftpRoot);
    String native(String namespacedRoot) => sftpRoot == null
        ? namespacedRoot
        : (sftpRemotePathOf(namespacedRoot, sftpRoot) ?? namespacedRoot);
    final List<MusicSourceRoot> sameServer = <MusicSourceRoot>[
      for (final SourceLibraryRow s in await _db.getMediaSourcesByKind(
        SourceLibraryKind.music.dbValue,
      ))
        if (s.transport == videoSource.transport &&
            sameRemoteServer(decodeSourceConfig(s.configJson), cfg))
          (rootPath: namespaced(s.rootPath), recursive: s.recursive),
    ];
    final MusicAudioRootPlan plan = planMusicRootsForVideoSourceAudio(
      videoRoot: scanRoot,
      audioPaths: audio,
      videoMediaDirs: videoMediaDirs,
      musicSources: sameServer,
      context: p.url,
    );
    final List<String> errors = <String>[];
    for (final PlannedMusicRoot root in plan.roots) {
      final String? error = await _registerRemote(
        videoSource: videoSource,
        rootPath: native(root.rootPath),
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

/// 两个网络来源的连接参数指向同一台服务器、同一个账号（AList 看站点根，其余看主机 /
/// 端口）：它们的条目地址同一命名空间，目录覆盖判断才有意义。
bool sameRemoteServer(Map<String, Object?> a, Map<String, Object?> b) {
  String str(Map<String, Object?> m, String k) =>
      ((m[k] as String?) ?? '').trim().toLowerCase();
  int? port(Map<String, Object?> m) => (m['port'] as num?)?.toInt();
  return str(a, 'host') == str(b, 'host') &&
      port(a) == port(b) &&
      str(a, 'baseUrl') == str(b, 'baseUrl') &&
      ((a['username'] as String?) ?? '') == ((b['username'] as String?) ?? '');
}
